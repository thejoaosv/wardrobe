import { execFile, spawn } from "node:child_process";
import { mkdtemp, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";

const SNAPSHOT = /-\d{4}-\d{2}-\d{2}$/;

// Smallest tier that handles each task well (luna < terra < sol < astra); the big tiers only burn plan usage here.
export const TASK_TIERS = { vision: "terra", planner: "terra", imageAgent: "luna" };

function version(id, prefix) {
  const match = id.slice(prefix.length).match(/^(\d+)(?:\.(\d+))?/);
  return match ? Number(match[1]) * 1000 + Number(match[2] || 0) : -1;
}

const newest = (ids, prefix, penalty = () => 0) => ids
  .map((id) => ({ id, score: version(id, prefix) * 10 - penalty(id) }))
  .sort((a, b) => b.score - a.score)[0]?.id || null;

// Picks the newest version of each task's tier from a model id list, e.g. gpt-6.1-terra over gpt-5.6-terra.
export function pickModels(ids) {
  const stable = ids.filter((id) => !SNAPSHOT.test(id));
  const tier = (name) => newest(stable.filter((id) => new RegExp(`^gpt-\\d+(\\.\\d+)?-${name}$`).test(id)), "gpt-");
  const legacyMini = newest(stable.filter((id) => /^gpt-\d+(\.\d+)?-mini$/.test(id)), "gpt-");
  return {
    // Image fidelity is the product, so the newest quality variant wins over fast variants.
    image: newest(stable.filter((id) => /^gpt-image-\d/.test(id)), "gpt-image-", (id) => (/mini|flare|fast/.test(id) ? 1 : 0)),
    vision: tier(TASK_TIERS.vision) || legacyMini,
    planner: tier(TASK_TIERS.planner) || legacyMini,
    imageAgent: tier(TASK_TIERS.imageAgent),
  };
}

export function createAIProvider(setting) {
  const baseUrl = () => setting("OPENAI_API_BASE_URL", "https://api.openai.com/v1").replace(/\/$/, "");
  const apiKey = () => setting("OPENAI_API_KEY").trim();
  let codexReady;
  let apiModels;
  let codexModels;

  async function hasCodex() {
    if (codexReady !== undefined) return codexReady;
    try {
      const { stdout, stderr } = await promisify(execFile)(setting("CODEX_BIN", "codex"), ["login", "status"], { timeout: 15000 });
      codexReady = /chatgpt/i.test(`${stdout}${stderr}`);
    } catch {
      codexReady = false;
    }
    return codexReady;
  }

  async function provider() {
    const choice = setting("WARDROBE_AI_PROVIDER", "auto");
    if (choice === "api") return apiKey() ? "api" : null;
    if (choice === "codex") return (await hasCodex()) ? "codex" : null;
    if (await hasCodex()) return "codex";
    return apiKey() ? "api" : null;
  }

  async function model(kind) {
    const pinned = { image: "OPENAI_IMAGE_MODEL", vision: "OPENAI_VISION_MODEL", planner: "OPENAI_PLANNER_MODEL" }[kind];
    if (setting(pinned)) return setting(pinned);
    apiModels ||= fetch(`${baseUrl()}/models`, { headers: { Authorization: `Bearer ${apiKey()}` } })
      .then((response) => (response.ok ? response.json() : { data: [] }))
      .then((result) => pickModels((result.data || []).map((item) => item.id)))
      .catch(() => ({}));
    const fallback = { image: "gpt-image-2", vision: "gpt-5.4-mini", planner: "gpt-5.4-mini" }[kind];
    return (await apiModels)[kind] || fallback;
  }

  // Codex lists the models the signed-in plan can use; undefined falls back to the CLI default.
  async function codexModel(kind) {
    if (setting("CODEX_MODEL")) return setting("CODEX_MODEL");
    codexModels ||= readFile(path.join(setting("CODEX_HOME", path.join(homedir(), ".codex")), "models_cache.json"), "utf8")
      .then((text) => { const cache = JSON.parse(text); return pickModels((cache.models || cache).map((item) => item.slug || item.id).filter(Boolean)); })
      .catch(() => ({}));
    return (await codexModels)[kind] || undefined;
  }

  // Runs one non-interactive Codex turn on the user's ChatGPT plan inside a throwaway directory.
  async function codex({ prompt, images = [], schema, model, sandbox = "read-only", timeout = 5 * 60 * 1000 }) {
    const dir = await mkdtemp(path.join(tmpdir(), "wardrobe-codex-"));
    try {
      const imageArgs = [];
      for (const [index, image] of images.entries()) {
        const file = path.join(dir, `image-${index + 1}.png`);
        await writeFile(file, image);
        imageArgs.push(`--image=${file}`);
      }
      const args = ["exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "-s", sandbox, "-C", dir,
        "-c", `model_reasoning_effort="${setting("CODEX_REASONING_EFFORT", "low")}"`, "-o", path.join(dir, "last.txt"), ...imageArgs];
      if (model) args.push("-m", model);
      if (schema) {
        await writeFile(path.join(dir, "schema.json"), JSON.stringify(schema));
        args.push("--output-schema", path.join(dir, "schema.json"));
      }
      let threadId = null;
      await new Promise((resolve, reject) => {
        const child = spawn(setting("CODEX_BIN", "codex"), args, { stdio: ["pipe", "pipe", "pipe"] });
        let stderr = "";
        let events = "";
        // The first JSON event names the thread; its generated images live in a folder of that name.
        child.stdout.on("data", (chunk) => {
          if (threadId) return;
          events += chunk;
          threadId = events.match(/"thread_id"\s*:\s*"([\w-]+)"/)?.[1] || null;
        });
        const timer = setTimeout(() => child.kill("SIGTERM"), timeout);
        child.stderr.on("data", (chunk) => { stderr = `${stderr}${chunk}`.slice(-4000); });
        child.on("error", reject);
        child.on("close", (code) => {
          clearTimeout(timer);
          code === 0 ? resolve() : reject(new Error(`Codex failed (${code}): ${stderr.trim().split("\n").at(-1) || "no output"}`));
        });
        child.stdin.end(prompt);
      });
      return { dir, threadId, last: await readFile(path.join(dir, "last.txt"), "utf8").catch(() => "") };
    } catch (error) {
      await rm(dir, { recursive: true, force: true });
      throw error;
    }
  }

  // Fallback when the agent fails to copy its result: the image tool saves under $CODEX_HOME/generated_images/<thread>.
  async function newestGeneratedImage(threadId) {
    if (!threadId) return null;
    const folder = path.join(setting("CODEX_HOME", path.join(homedir(), ".codex")), "generated_images", threadId);
    const files = (await readdir(folder).catch(() => [])).filter((name) => name.endsWith(".png"));
    if (!files.length) return null;
    const dated = await Promise.all(files.map(async (name) => ({ name, time: (await stat(path.join(folder, name))).mtimeMs })));
    return readFile(path.join(folder, dated.sort((a, b) => b.time - a.time)[0].name));
  }

  async function codexJSON(options) {
    const { dir, last } = await codex(options);
    await rm(dir, { recursive: true, force: true });
    const match = last.match(/\{[\s\S]*\}/);
    if (!match) throw new Error("Codex returned no JSON result");
    return JSON.parse(match[0]);
  }

  async function apiJSON({ prompt, images = [], schema, kind }) {
    const response = await fetch(`${baseUrl()}/responses`, {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey()}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model: await model(kind),
        input: [{ role: "user", content: [
          { type: "input_text", text: prompt },
          ...images.map((image) => ({ type: "input_image", image_url: `data:image/png;base64,${image.toString("base64")}` })),
        ] }],
        text: { format: { type: "json_schema", name: "result", strict: true, schema } },
      }),
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(result.error?.message || `OpenAI request failed (${response.status})`);
    const outputText = result.output_text || result.output?.flatMap((item) => item.content || []).find((item) => item.type === "output_text")?.text;
    if (!outputText) throw new Error("OpenAI returned no structured result");
    return JSON.parse(outputText);
  }

  return {
    async status() {
      const active = await provider();
      return { provider: active, hasCodex: await hasCodex(), hasApiKey: Boolean(apiKey()) };
    },

    // Structured JSON from text plus optional PNG images. kind picks the API model ("vision" or "planner").
    async json({ prompt, images, schema, kind = "planner" }) {
      const active = await provider();
      if (!active) throw new Error("No AI provider: sign in with `codex login` or set OPENAI_API_KEY");
      return active === "codex" ? codexJSON({ prompt, images, schema, model: await codexModel(kind) }) : apiJSON({ prompt, images, schema, kind });
    },

    // Image edit from labelled PNG inputs: images is [{ data, role }], in the order the prompt calls Image 1, Image 2, ...
    // transparent asks Codex for a real alpha channel; the API path relies on the prompt's chroma-key backdrop instead.
    async editImage({ prompt, images, size, quality, background, transparent = false, model: pinnedModel }) {
      const active = await provider();
      if (!active) throw new Error("No AI provider: sign in with `codex login` or set OPENAI_API_KEY");
      if (active === "codex") {
        const shape = { "1536x1024": "landscape 3:2", "1024x1536": "portrait 2:3" }[size] || "square 1:1";
        const inputs = images.map((image, index) => `- Image ${index + 1} (./image-${index + 1}.png): ${image.role}`).join("\n");
        const { dir, last, threadId } = await codex({
          sandbox: "workspace-write",
          model: await codexModel("imageAgent"),
          images: images.map((image) => image.data),
          prompt: `${images.length ? `Call your built-in image_gen tool exactly once, in edit mode, with ALL of the input images below passed to it as input images. They are attached to this message; if any is not visible to you, load it from its path with view_image first. Never generate from the text alone: the result must reproduce the real garments in these photos.

Input images:
${inputs}` : "Call your built-in image_gen tool exactly once to generate a new image."}

Output: exactly one ${shape} PNG${transparent ? " with a genuinely transparent background. Ask image_gen for transparency and keep its alpha channel" : ""}.

Brief:
${prompt}

Then copy the generated PNG to ./output.png in the current directory. Do nothing else. Reply only with "done".`,
        });
        try {
          return await readFile(path.join(dir, "output.png"))
            .catch(() => newestGeneratedImage(threadId))
            .then((bytes) => bytes || Promise.reject());
        } catch {
          throw new Error(`Codex did not produce an image${last.trim() ? `: ${last.trim().slice(0, 300)}` : ""}`);
        } finally {
          await rm(dir, { recursive: true, force: true });
        }
      }
      const form = new FormData();
      form.set("model", pinnedModel || await model("image"));
      form.set("prompt", prompt);
      form.set("size", size);
      form.set("quality", quality || "high");
      form.set("output_format", "png");
      if (background) form.set("background", background);
      images.forEach((image, index) => form.append("image[]", new Blob([image.data], { type: "image/png" }), `image-${index + 1}.png`));
      const response = await fetch(`${baseUrl()}/images/edits`, { method: "POST", headers: { Authorization: `Bearer ${apiKey()}` }, body: form });
      const result = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(result.error?.message || `OpenAI image request failed (${response.status})`);
      const encoded = result.data?.[0]?.b64_json;
      if (!encoded) throw new Error("OpenAI response did not contain image data");
      return Buffer.from(encoded, "base64");
    },
  };
}
