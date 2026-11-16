import assert from "node:assert/strict";
import test from "node:test";
import sharp from "sharp";
import { buildTryOnPrompt, hasTransparentBackground, tryOnReferences } from "./import-job-api.mjs";
import { pickModels } from "./openai-provider.mjs";
import { duplicateCombos, historyFor, planIssues, repeatedGarments, validatePlan } from "./outfit-planner.mjs";

const items = [
  { id: "tee", part: "upperbody" },
  { id: "shirt", part: "upperbody" },
  { id: "jeans", part: "lowerbody" },
  { id: "chinos", part: "lowerbody" },
];
const plan = (date, garmentIds) => ({ date, garmentIds });

test("validatePlan drops unknown ids, duplicate parts, and fails skipped dates", () => {
  const days = [{ date: "2026-11-16", style: "casual" }];
  const [day] = validatePlan({ outfits: [{ date: "2026-11-16", name: "A", garmentIds: ["tee", "shirt", "ghost", "jeans"], reason: "" }] }, { items, days });
  assert.deepEqual(day.garmentIds, ["tee", "jeans"]);
  assert.equal(day.style, "casual");
  assert.throws(() => validatePlan({ outfits: [] }, { items, days }), /no usable outfit/);
});

test("historyFor excludes target dates and far-away plans", () => {
  const plans = { "2026-11-01": plan("2026-11-01", ["tee"]), "2026-11-16": plan("2026-11-16", ["shirt"]), "2025-01-01": plan("2025-01-01", ["jeans"]) };
  assert.deepEqual(historyFor(plans, ["2026-11-16"]).map((p) => p.date), ["2026-11-01"]);
});

test("repeats and duplicate combos are detected", () => {
  const plans = { "2026-11-16": plan("2026-11-16", ["tee", "jeans"]), "2026-11-18": plan("2026-11-18", ["jeans", "tee"]), "2026-11-30": plan("2026-11-30", ["tee", "chinos"]) };
  assert.deepEqual(repeatedGarments(plans, "2026-11-18").sort(), ["jeans", "tee"]);
  assert.deepEqual(repeatedGarments(plans, "2026-11-30"), []);
  assert.deepEqual(duplicateCombos(plans).sort(), ["2026-11-16", "2026-11-18"]);
});

test("planIssues only flags avoidable repeats", () => {
  const plans = { "2026-11-16": plan("2026-11-16", ["tee", "jeans"]) };
  const issues = planIssues(plans, [plan("2026-11-17", ["tee", "chinos"])], items);
  assert.equal(issues.length, 1);
  assert.match(issues[0], /reuses tee/);
  // With a single top, reusing it is unavoidable.
  assert.deepEqual(planIssues(plans, [plan("2026-11-17", ["tee", "chinos"])], items.filter((item) => item.id !== "shirt")), []);
  // A one-top, one-bottom wardrobe can only repeat itself.
  const tiny = items.filter((item) => ["tee", "jeans"].includes(item.id));
  assert.deepEqual(planIssues(plans, [plan("2026-11-18", ["tee", "jeans"])], tiny), []);
  assert.match(planIssues(plans, [plan("2026-11-30", ["jeans", "tee"])], items).join(), /repeats an earlier outfit/);
});

test("pickModels takes the newest version of each task tier, not the biggest model", () => {
  const ids = ["gpt-6.1-sol", "gpt-6-astra", "gpt-6.1-terra", "gpt-5.6-terra", "gpt-6-luna", "gpt-5.6-luna", "gpt-image-2", "gpt-image-2.6-flare", "gpt-image-2.6-sunburst", "gpt-6.1-terra-2026-10-01"];
  assert.deepEqual(pickModels(ids), { image: "gpt-image-2.6-sunburst", vision: "gpt-6.1-terra", planner: "gpt-6.1-terra", imageAgent: "gpt-6-luna" });
  // Accounts without tiered models fall back to the newest mini.
  assert.equal(pickModels(["gpt-5.4", "gpt-5.4-mini", "gpt-5-mini"]).planner, "gpt-5.4-mini");
});

test("hasTransparentBackground tells real alpha from a chroma backdrop", async () => {
  const garment = await sharp({ create: { width: 40, height: 40, channels: 4, background: { r: 20, g: 30, b: 90, alpha: 1 } } }).png().toBuffer();
  const cutout = await sharp({ create: { width: 100, height: 100, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } }).composite([{ input: garment, left: 30, top: 30 }]).png().toBuffer();
  const keyed = await sharp({ create: { width: 100, height: 100, channels: 4, background: { r: 0, g: 255, b: 0, alpha: 1 } } }).composite([{ input: garment, left: 30, top: 30 }]).png().toBuffer();
  assert.equal(await hasTransparentBackground(cutout), true);
  assert.equal(await hasTransparentBackground(keyed), false);
});

test("try-on references back cutouts and turns the pose when a piece has one", () => {
  const plan = { name: "Rugby Street", style: "Streetwear" };
  const front = [{ name: "Rugby shirt", part: "upperbody", image: "/a.png" }, { name: "Jeans", part: "lowerbody", image: "/b.png" }];
  assert.match(buildTryOnPrompt(plan, front), /mostly front-facing/);
  const withBack = [{ ...front[0], backImage: "/a-back.png" }, front[1]];
  assert.deepEqual(tryOnReferences(withBack).map((ref) => `${ref.item.name}:${ref.side}`), ["Rugby shirt:front", "Rugby shirt:back", "Jeans:front"]);
  const prompt = buildTryOnPrompt(plan, withBack);
  assert.match(prompt, /Image 3: exact top reference \(Rugby shirt\), back view/);
  assert.match(prompt, /three-quarter back view.*back of Rugby shirt/);
});
