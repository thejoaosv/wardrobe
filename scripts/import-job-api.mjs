import { randomUUID } from "node:crypto";
import { copyFile, mkdir, readFile, readdir, rename, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import sharp from "sharp";
import { createAIProvider } from "./openai-provider.mjs";
import { DATE, WEATHERS, buildPlanPrompt, historyFor, layerIssues, planIssues, planSchema, repeatedGarments, swapIssues, validatePlan } from "./outfit-planner.mjs";

const API_ROOT = "/api/import/jobs";
const ASSET_ROOT = "/api/import/assets";
const LIBRARY_ASSET_ROOT = "/api/import/library";
const STAGES = new Set(["crop", "garment", "modeled"]);
const DECISIONS = new Set(["approve", "reject"]);
const PARTS = new Set(["upperbody", "midlayer", "wholebody_up", "lowerbody", "accessories_up", "shoes"]);
const HEX_COLOR = /^#[0-9a-f]{6}$/i;

function json(res, status, value) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.setHeader("Cache-Control", "no-store");
  res.end(JSON.stringify(value));
}

async function body(req, limit = 25 * 1024 * 1024) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > limit) throw Object.assign(new Error("Request body too large"), { status: 413 });
    chunks.push(chunk);
  }
  if (!chunks.length) return {};
  try { return JSON.parse(Buffer.concat(chunks).toString("utf8")); }
  catch { throw Object.assign(new Error("Expected a JSON request body"), { status: 400 }); }
}

function publicJob(job) {
  const copy = structuredClone(job);
  delete copy.internal;
  return copy;
}

function extension(mime = "image/png") {
  return ({ "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp" })[mime] || "png";
}

function decodeImage(input) {
  const raw = input.imageDataUrl || input.imageBase64;
  if (!raw || typeof raw !== "string") throw Object.assign(new Error("imageDataUrl or imageBase64 is required"), { status: 400 });
  const match = raw.match(/^data:([^;]+);base64,(.+)$/s);
  const mime = match?.[1] || input.mimeType || "image/png";
  const data = Buffer.from(match?.[2] || raw, "base64");
  if (!data.length) throw Object.assign(new Error("Image payload is empty"), { status: 400 });
  return { data, mime };
}

function normalizeMetadata(value = {}) {
  const metadata = value && typeof value === "object" && !Array.isArray(value) ? value : {};
  const color = typeof metadata.color === "string" && HEX_COLOR.test(metadata.color) ? metadata.color.toLowerCase() : "#d8d0c2";
  const secondaryColor = typeof metadata.secondaryColor === "string" && HEX_COLOR.test(metadata.secondaryColor) ? metadata.secondaryColor.toLowerCase() : null;
  return {
    name: typeof metadata.name === "string" ? metadata.name.trim().slice(0, 120) || "New piece" : "New piece",
    part: PARTS.has(metadata.part) ? metadata.part : "upperbody",
    color,
    secondaryColor,
    description: typeof metadata.description === "string" ? metadata.description.trim().slice(0, 400) : "",
    text: typeof metadata.text === "string" ? metadata.text.trim().slice(0, 200) : "",
    tags: Array.isArray(metadata.tags) ? metadata.tags.filter((tag) => typeof tag === "string").map((tag) => tag.trim().toLowerCase().slice(0, 40)).filter(Boolean).slice(0, 12) : [],
    boundingBox: normalizeBoundingBox(metadata.boundingBox),
  };
}

function normalizeBoundingBox(value = {}) {
  const box = value && typeof value === "object" && !Array.isArray(value) ? value : {};
  const number = (key, fallback) => Number.isFinite(Number(box[key])) ? Math.round(Number(box[key])) : fallback;
  const x = Math.max(0, Math.min(999, number("x", 0)));
  const y = Math.max(0, Math.min(999, number("y", 0)));
  const width = Math.max(1, Math.min(1000 - x, number("width", 1000 - x)));
  const height = Math.max(1, Math.min(1000 - y, number("height", 1000 - y)));
  return { x, y, width, height };
}

async function normalizeImage(bytes) {
  return sharp(bytes).rotate().toColorspace("srgb").png().toBuffer();
}

async function cropDetectedItem(bytes, boundingBox) {
  const normalized = await normalizeImage(bytes);
  const { width, height } = await sharp(normalized).metadata();
  const box = normalizeBoundingBox(boundingBox);
  const rawLeft = (box.x / 1000) * width;
  const rawTop = (box.y / 1000) * height;
  const rawWidth = (box.width / 1000) * width;
  const rawHeight = (box.height / 1000) * height;
  const padding = Math.max(12, Math.round(Math.max(rawWidth, rawHeight) * 0.08));
  const left = Math.max(0, Math.floor(rawLeft - padding));
  const top = Math.max(0, Math.floor(rawTop - padding));
  const right = Math.min(width, Math.ceil(rawLeft + rawWidth + padding));
  const bottom = Math.min(height, Math.ceil(rawTop + rawHeight + padding));
  return sharp(normalized).extract({ left, top, width: Math.max(1, right - left), height: Math.max(1, bottom - top) }).png().toBuffer();
}

function chooseChromaKey(primary = "#808080") {
  const value = HEX_COLOR.test(primary) ? primary : "#808080";
  const source = [1, 3, 5].map((offset) => Number.parseInt(value.slice(offset, offset + 2), 16));
  const candidates = [[0, 255, 0], [255, 0, 255], [0, 255, 255]];
  const selected = candidates.sort((a, b) => {
    const distance = (color) => color.reduce((total, channel, index) => total + ((channel - source[index]) ** 2), 0);
    return distance(b) - distance(a);
  })[0];
  return `#${selected.map((channel) => channel.toString(16).padStart(2, "0")).join("")}`;
}

export function buildGarmentPrompt(metadata = {}, chromaKey = "#00ff00", { transparent = false } = {}) {
  const name = metadata.name || "clothing item";
  const category = metadata.part || "wardrobe item";
  const primary = metadata.color || "the exact visible color";
  const secondary = metadata.secondaryColor ? ` with distinct secondary color ${metadata.secondaryColor}` : "";
  const details = Array.isArray(metadata.tags) && metadata.tags.length
    ? metadata.tags.join(", ")
    : "all visible construction and design details";
  const lettering = metadata.text
    ? `\n\nText on the garment: ${metadata.text}. Reproduce every word letter for letter with the same font style, size and placement. Never substitute a different or more familiar word.`
    : "";
  const description = metadata.description ? `\nDescription: ${metadata.description}` : "";

  return `Use case: background-extraction
Asset type: ecommerce catalog product cutout source

Input images: Image 1 is the photo the user selected, cropped to this garment, either by itself or worn by a person. Image 2, when present, is the full selected photo for context on true color, texture and how the garment sits. Reconstruct exactly this real garment from them; do not design a new one.

Primary request: Reconstruct ONLY the complete empty ${name} (${category}) as a clean, front-facing ecommerce catalog product photograph. If a wearer is present, remove them. Remove every other garment, object, and background element. Show the complete item naturally arranged and symmetrical, with no person, body, mannequin, or hanger visible.

Garment fidelity: Preserve the reference garment's exact primary color ${primary}${secondary}, material and texture, silhouette, neckline, sleeves, fastenings, pattern, and distinctive details (${details}).${description} Preserve any clearly legible existing graphic or logo exactly, but do not invent or reinterpret uncertain logos, text, pockets, seams, hardware, colors, or decoration.${lettering}

Composition: Centered straight-on product view. Keep the entire garment inside the frame with generous, even padding on every side. No cropping or truncation.

Background: ${transparent
    ? `Fully transparent background with a real alpha channel: only the garment is opaque. No backdrop, floor, shadow, or reflection. Only if true transparency is impossible, use a perfectly flat uniform solid ${chromaKey} instead.`
    : `Perfectly flat, absolutely uniform solid ${chromaKey} chroma-key color, edge-to-edge. No shadows, gradient, texture, vignette, floor, horizon, reflection, or lighting variation.`}

Lighting: Neutral diffuse product lighting contained on the garment only.

Avoid: person, body, skin, hair, mannequin, hanger, props, other garments, retail tags, cast shadow, contact shadow, reflection, watermark, caption, border, background variation, or chroma spill.

Critical: Use no ${chromaKey} anywhere in the garment. Produce exactly one complete garment with a crisp, separable outer silhouette.`;
}

function cleanupTolerance(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? Math.max(18, Math.min(110, Math.round(parsed))) : 46;
}

function removeKeyedSpill(data, index, keyedChannels, neutralLevel) {
  let remaining = Math.ceil(keyedChannels.reduce((total, channel) => total + data[index + channel], 0) - (neutralLevel * keyedChannels.length));
  let active = keyedChannels.filter((channel) => data[index + channel] > 0);
  while (remaining > 0 && active.length) {
    const share = Math.ceil(remaining / active.length);
    const next = [];
    for (const channel of active) {
      const reduction = Math.min(data[index + channel], share, remaining);
      data[index + channel] -= reduction;
      remaining -= reduction;
      if (data[index + channel] > 0) next.push(channel);
    }
    active = next;
  }
}

export async function processChromaBackground(bytes, key, options = {}) {
  const tolerance = cleanupTolerance(options.tolerance);
  const feather = 80;
  const target = [1, 3, 5].map((offset) => Number.parseInt(key.slice(offset, offset + 2), 16));
  const keyedChannels = target.map((channel, index) => channel > 200 ? index : null).filter((index) => index !== null);
  const neutralChannels = target.map((channel, index) => channel < 55 ? index : null).filter((index) => index !== null);
  const { data, info } = await sharp(bytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  for (let index = 0; index < data.length; index += 4) {
    const distance = Math.sqrt(
      ((data[index] - target[0]) ** 2)
      + ((data[index + 1] - target[1]) ** 2)
      + ((data[index + 2] - target[2]) ** 2),
    );
    if (distance <= tolerance) {
      data[index] = 0;
      data[index + 1] = 0;
      data[index + 2] = 0;
      data[index + 3] = 0;
    } else {
      if (distance < tolerance + feather) data[index + 3] = Math.round(data[index + 3] * ((distance - tolerance) / feather));
      const keyedLevel = keyedChannels.reduce((total, channel) => total + data[index + channel], 0) / keyedChannels.length;
      const neutralLevel = neutralChannels.reduce((total, channel) => total + data[index + channel], 0) / neutralChannels.length;
      const spill = Math.max(0, keyedLevel - neutralLevel);
      if (spill > 0) {
        const spillAlpha = Math.max(0, 1 - (Math.max(0, spill - 4) / 150));
        data[index + 3] = Math.round(data[index + 3] * spillAlpha);
        removeKeyedSpill(data, index, keyedChannels, neutralLevel);
      }
      if (data[index + 3] <= 8) {
        data[index] = 0;
        data[index + 1] = 0;
        data[index + 2] = 0;
        data[index + 3] = 0;
      }
    }
  }
  for (let index = 0; index < data.length; index += 4) {
    if (data[index + 3] === 0) continue;
    const keyedLevel = keyedChannels.reduce((total, channel) => total + data[index + channel], 0) / keyedChannels.length;
    const neutralLevel = neutralChannels.reduce((total, channel) => total + data[index + channel], 0) / neutralChannels.length;
    const residualSpill = Math.max(0, keyedLevel - neutralLevel);
    if (residualSpill > 0) {
      removeKeyedSpill(data, index, keyedChannels, neutralLevel);
    }
  }
  const keyedOutput = await sharp(data, { raw: info }).png().toBuffer();
  const framedOutput = await frameTransparentGarment(keyedOutput);
  const { data: framedData, info: framedInfo } = await sharp(framedOutput).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  for (let index = 0; index < framedData.length; index += 4) {
    if (framedData[index + 3] === 0) continue;
    const keyedLevel = keyedChannels.reduce((total, channel) => total + framedData[index + channel], 0) / keyedChannels.length;
    const neutralLevel = neutralChannels.reduce((total, channel) => total + framedData[index + channel], 0) / neutralChannels.length;
    const residualSpill = Math.max(0, keyedLevel - neutralLevel);
    if (residualSpill <= 0) continue;
    removeKeyedSpill(framedData, index, keyedChannels, neutralLevel);
  }
  const output = await sharp(framedData, { raw: framedInfo }).png().toBuffer();
  const verification = await verifyNoChromaSpill(output, key);
  return { bytes: output, verification, tolerance };
}

export async function removeChromaBackground(bytes, key, options = {}) {
  const result = await processChromaBackground(bytes, key, options);
  if (options.strict !== false && result.verification.contaminatedPixels > 1) {
    throw new Error(`Background cleanup left ${result.verification.contaminatedPixels} chroma-contaminated pixels`);
  }
  return result.bytes;
}

export async function frameTransparentGarment(bytes, canvasSize = 1024, occupancy = 0.88) {
  const { data, info } = await sharp(bytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  let minX = info.width;
  let minY = info.height;
  let maxX = -1;
  let maxY = -1;
  for (let index = 0, pixel = 0; index < data.length; index += 4, pixel += 1) {
    if (data[index + 3] <= 8) continue;
    const x = pixel % info.width;
    const y = Math.floor(pixel / info.width);
    minX = Math.min(minX, x);
    minY = Math.min(minY, y);
    maxX = Math.max(maxX, x);
    maxY = Math.max(maxY, y);
  }
  if (maxX < minX || maxY < minY) throw new Error("Background removal did not leave a visible garment");

  const trimmed = await sharp(data, { raw: info })
    .extract({ left: minX, top: minY, width: maxX - minX + 1, height: maxY - minY + 1 })
    .png()
    .toBuffer();
  const targetSize = Math.max(1, Math.round(canvasSize * Math.max(0.5, Math.min(0.96, occupancy))));
  const resized = await sharp(trimmed)
    .resize(targetSize, targetSize, { fit: "inside", withoutEnlargement: false })
    .png()
    .toBuffer({ resolveWithObject: true });
  const left = Math.floor((canvasSize - resized.info.width) / 2);
  const top = Math.floor((canvasSize - resized.info.height) / 2);
  return sharp({ create: { width: canvasSize, height: canvasSize, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } })
    .composite([{ input: resized.data, left, top }])
    .png()
    .toBuffer();
}

async function verifyNoChromaSpill(bytes, key) {
  const target = [1, 3, 5].map((offset) => Number.parseInt(key.slice(offset, offset + 2), 16));
  const keyedChannels = target.map((channel, index) => channel > 200 ? index : null).filter((index) => index !== null);
  const neutralChannels = target.map((channel, index) => channel < 55 ? index : null).filter((index) => index !== null);
  const { data } = await sharp(bytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  let contaminatedPixels = 0;
  let maxSpill = 0;
  for (let index = 0; index < data.length; index += 4) {
    if (data[index + 3] === 0) continue;
    const keyedLevel = keyedChannels.reduce((total, channel) => total + data[index + channel], 0) / keyedChannels.length;
    const neutralLevel = neutralChannels.reduce((total, channel) => total + data[index + channel], 0) / neutralChannels.length;
    const spill = Math.max(0, keyedLevel - neutralLevel);
    maxSpill = Math.max(maxSpill, spill);
    if (spill > 1.5) contaminatedPixels += 1;
  }
  return { contaminatedPixels, maxSpill };
}

// True when an image already has a real transparent backdrop (at least 5% fully clear pixels, all four corners clear).
export async function hasTransparentBackground(bytes) {
  const { data, info } = await sharp(bytes).ensureAlpha().extractChannel(3).raw().toBuffer({ resolveWithObject: true });
  const clear = data.reduce((count, alpha) => count + (alpha <= 8 ? 1 : 0), 0);
  const corners = [0, info.width - 1, (info.height - 1) * info.width, info.height * info.width - 1];
  return clear / data.length >= 0.05 && corners.every((index) => data[index] <= 8);
}

const PART_NAMES = { upperbody: "base top", midlayer: "mid layer", wholebody_up: "outer layer", lowerbody: "bottom", shoes: "shoes", accessories_up: "accessory" };

// Adapted from the generate-outfits skill template: one portrait of the user in exactly these garments.
// Reference images after the identity photo: each garment's front cutout, then its back cutout when it has one.
export function tryOnReferences(garments) {
  return garments.flatMap((item) => [{ item, side: "front", image: item.image }, ...(item.backImage ? [{ item, side: "back", image: item.backImage }] : [])]);
}

export function buildTryOnPrompt(plan, garments) {
  const refs = tryOnReferences(garments);
  const references = refs.map(({ item, side }, index) => `Image ${index + 2}: exact ${PART_NAMES[item.part] || "garment"} reference (${item.name}), ${side} view.${item.text && side === "front" ? ` Its text reads: ${item.text}.` : ""}`).join("\n");
  const backs = refs.filter((ref) => ref.side === "back").map((ref) => ref.item.name);
  const composition = backs.length
    ? `Full body from head to shoes, centered. Pose the person in a natural three-quarter back view, turned about 135 degrees away from the camera and glancing back over the shoulder, so the back of ${backs.join(" and ")} is clearly visible while the face stays recognizable and the front of the outfit is still partly readable.`
    : "Full body from head to shoes, centered, relaxed mostly front-facing pose with arms away from the torso so every garment stays readable.";
  const layered = garments.some((item) => item.part === "wholebody_up" || item.part === "midlayer")
    ? "\nLayering: wear the layers in order, base top innermost, then the mid layer, then the outer layer, so each stays identifiable (a collar or hem of the inner layer may show). Only open a layer if its reference shows a real full front zipper or buttons; never invent a closure."
    : "";
  return `Use case: identity-preserve
Asset type: vertical outfit try-on photograph

Image 1: identity reference for the exact person to preserve.
${references}

Primary request: Create a photorealistic vertical 2:3 editorial fashion photograph of the person from Image 1 wearing all of the referenced garments, and only those garments.

Outfit: ${plan.name} (${plan.style}).
Scene/backdrop: a restrained, softly lit real-world setting that suits a ${plan.style} outfit.

Subject: Preserve the person's recognizable face, hair, glasses if worn, age, build, skin texture and body proportions. ${garments.some((item) => item.part === "shoes") ? "" : "Plain understated shoes are allowed because no shoe reference is provided. "}Do not add, replace or invent any other visible clothing or accessory.${layered}

Composition: ${composition}

Garment fidelity: Preserve every garment precisely: color, material, fit, construction, pattern, graphics, logos, text, proportions and closures.

Avoid: hidden or redesigned garments, changed logos or text, extra layers, hats, bags or jewelry that were not referenced, crossed arms, cropped feet, extra people, text overlays, watermarks, studio cutout look, or synthetic AI polish.`;
}

async function atomicJson(file, value) {
  const tmp = `${file}.${randomUUID()}.tmp`;
  await writeFile(tmp, `${JSON.stringify(value, null, 2)}\n`);
  try {
    await rename(tmp, file);
  } catch (error) {
    if (!["EBUSY", "EXDEV", "EPERM"].includes(error.code)) {
      await rm(tmp, { force: true });
      throw error;
    }
    await copyFile(tmp, file);
    await rm(tmp, { force: true });
  }
}

function stageState() {
  return { status: "pending", decision: null, attempts: 0, assetUrl: null, failedAssetUrl: null, cleanupPreviewUrl: null, cleanupTolerance: 46, cleanupDiagnostics: null, error: null, prompt: null, updatedAt: null };
}

const ANALYZE_PROMPT = `Identify every distinct wearable clothing item visible in this image. A photo may show one isolated garment or a person wearing several items. Return one record per actual item that should enter a wardrobe. Ignore the person's body and non-wearable background objects. For each item, include a tight bounding box around only that item using integer coordinates normalized to a 1000 by 1000 image: x and y are the top-left corner, followed by width and height. Boxes may overlap when garments overlap, but each box must focus on one distinct item. Use only these category ids: upperbody (base tops worn against the skin: t-shirts, shirts, polos, tank tops, thin long-sleeve tees), midlayer (warm layers worn over a base top: hoodies, sweatshirts, sweaters, cardigans, fleeces, zip-up hoodies), wholebody_up (outerwear: jackets, coats, rain jackets, puffers, blazers, overshirts worn as jackets), lowerbody, accessories_up, shoes. Name each item specifically enough to tell it apart from similar pieces: color, distinguishing graphic or brand, and type, e.g. "Grey ROTATION LX varsity hoodie" or "Black Dickies chest-logo tee", not "Graphic hoodie". Give a primary hex color, an optional genuinely distinct secondary hex color, and 1-4 useful lowercase detail tags. description is one or two sentences a stylist can plan with: fabric and weight, fit, warmth, formality, and notable design details. text transcribes, letter for letter, every word printed, embroidered or patched on the item with its placement and relative size, e.g. 'front: large arched "ROTATION", small "LX" centered below'; use an empty string when there is no legible text.`;

const ANALYZE_SCHEMA = { type: "object", additionalProperties: false, properties: { items: { type: "array", minItems: 0, maxItems: 8, items: { type: "object", additionalProperties: false, properties: { name: { type: "string" }, part: { type: "string", enum: [...PARTS] }, color: { type: "string", pattern: "^#[0-9A-Fa-f]{6}$" }, secondaryColor: { anyOf: [{ type: "string", pattern: "^#[0-9A-Fa-f]{6}$" }, { type: "null" }] }, description: { type: "string" }, text: { type: "string" }, tags: { type: "array", items: { type: "string" }, maxItems: 4 }, boundingBox: { type: "object", additionalProperties: false, properties: { x: { type: "integer", minimum: 0, maximum: 999 }, y: { type: "integer", minimum: 0, maximum: 999 }, width: { type: "integer", minimum: 1, maximum: 1000 }, height: { type: "integer", minimum: 1, maximum: 1000 } }, required: ["x", "y", "width", "height"] } }, required: ["name", "part", "color", "secondaryColor", "description", "text", "tags", "boundingBox"] } } }, required: ["items"] };

async function analyzeClothes(ai, image) {
  const parsed = await ai.json({ prompt: ANALYZE_PROMPT, images: [image], schema: ANALYZE_SCHEMA, kind: "vision" })
    .catch((error) => { throw Object.assign(error, { status: 502 }); });
  if (!Array.isArray(parsed.items)) throw new Error("Clothing analysis returned an invalid clothing list");
  return parsed.items;
}

export function wardrobeImportApi(options = {}) {
  let root;
  let jobsDir;
  let importedFile;
  let libraryAssetDir;
  let plansFile;
  let outfitDir;
  const running = new Map();
  let writeQueue = Promise.resolve();
  // Serializes read-modify-write cycles on library.json and plans.json.
  const serial = (task) => (writeQueue = writeQueue.then(task, task));
  const setting = (name, fallback = "") => options.env?.[name] || process.env[name] || fallback;
  const ai = createAIProvider(setting);

  async function setupStatus() {
    const { provider, hasApiKey, hasCodex } = await ai.status();
    const referenceSetting = setting("WARDROBE_MODEL_REFERENCE", "data/model-reference.png");
    const referencePath = path.resolve(root, referenceSetting);
    let hasModelReference = false;
    try {
      hasModelReference = (await stat(referencePath)).isFile();
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    return {
      // The photo of the user is optional: without it imports stop after the cutout.
      ready: Boolean(provider),
      provider,
      hasApiKey,
      hasCodex,
      hasModelReference,
      modelReference: referenceSetting,
    };
  }

  async function loadJob(id) {
    if (!/^[a-f0-9-]{36}$/i.test(id)) return null;
    try { return JSON.parse(await readFile(path.join(jobsDir, id, "job.json"), "utf8")); }
    catch (error) { if (error.code === "ENOENT") return null; throw error; }
  }

  async function saveJob(job) {
    job.updatedAt = new Date().toISOString();
    await atomicJson(path.join(jobsDir, job.id, "job.json"), job);
  }

  async function loadImported() {
    try { return JSON.parse(await readFile(importedFile, "utf8")); }
    catch (error) { if (error.code === "ENOENT") return []; throw error; }
  }

  async function loadPlans() {
    try { return JSON.parse(await readFile(plansFile, "utf8")); }
    catch (error) { if (error.code === "ENOENT") return {}; throw error; }
  }

  async function planList(plans) {
    const items = await loadImported();
    return Object.values(plans).sort((a, b) => a.date.localeCompare(b.date)).map((plan) => ({ ...plan, repeats: repeatedGarments(plans, plan.date, items) }));
  }

  async function planOutfits(input) {
    if (!Array.isArray(input.days) || !input.days.length || input.days.length > 31) throw Object.assign(new Error("days must list 1-31 days"), { status: 400 });
    const days = input.days.map((day) => ({
      date: typeof day?.date === "string" && DATE.test(day.date) && !Number.isNaN(Date.parse(day.date)) ? day.date : null,
      style: typeof day?.style === "string" ? day.style.trim().slice(0, 80) || "everyday" : "everyday",
      weather: WEATHERS.has(day?.weather) ? day.weather : "auto",
      replace: typeof day?.replace === "string" ? day.replace : undefined,
    }));
    if (days.some((day) => !day.date) || new Set(days.map((day) => day.date)).size !== days.length) throw Object.assign(new Error("Each day needs a unique YYYY-MM-DD date"), { status: 400 });
    const library = await loadImported();
    const items = library.filter((item) => !item.unavailable);
    if (!items.some((item) => item.part === "upperbody") || !items.some((item) => item.part === "lowerbody")) {
      throw Object.assign(new Error("Plan needs at least one available top and one available bottom"), { status: 409 });
    }
    const plans = await loadPlans();
    // A swap keeps the rest of the day's outfit (whatever is still available) and only changes one piece.
    const swapBasis = new Map();
    for (const day of days) {
      const current = plans[day.date]?.garmentIds || [];
      if (!current.includes(day.replace)) { delete day.replace; continue; }
      swapBasis.set(day.date, current.join("+"));
      day.keep = current.filter((id) => id !== day.replace && items.some((item) => item.id === id));
      const part = library.find((item) => item.id === day.replace)?.part;
      if (!items.some((item) => item.part === part && item.id !== day.replace)) throw Object.assign(new Error(`No other ${PART_NAMES[part] || "piece"} to swap in`), { status: 409 });
    }
    const prompt = buildPlanPrompt({ items, days, history: historyFor(plans, days.map((day) => day.date)) });
    // AI and validation failures are upstream problems the app should be able to show, not opaque 500s.
    const stylist = (text) => ai.json({ prompt: text, schema: planSchema }).then((result) => validatePlan(result, { items, days }))
      .catch((error) => { throw Object.assign(error, { status: 502 }); });
    let planned = await stylist(prompt);
    const issues = [...planIssues(plans, planned, items), ...swapIssues(days, planned, library), ...layerIssues(days, planned, items)];
    if (issues.length) {
      const retry = `${prompt}\n\nA previous attempt broke these rules; avoid them: ${issues.join("; ")}.`;
      planned = await stylist(retry);
      // Repeats are soft rules, but a swap that changed more than the one piece would overwrite the user's outfit.
      if (swapIssues(days, planned, library).length) throw Object.assign(new Error("The stylist couldn't swap just that piece. Try again."), { status: 502 });
    }
    return serial(async () => {
      // Pieces may have been removed or put in the wash while the stylist ran.
      const available = (await loadImported()).filter((item) => !item.unavailable);
      try { planned = validatePlan({ outfits: planned }, { items: available, days }); }
      catch (error) { throw Object.assign(error, { message: "Your closet changed while styling. Try again.", status: 409 }); }
      const fresh = await loadPlans();
      // Another restyle or swap of the same day finished first; this swap was based on the old outfit.
      if ([...swapBasis].some(([date, basis]) => (fresh[date]?.garmentIds || []).join("+") !== basis)) {
        throw Object.assign(new Error("This outfit changed while swapping. Try again."), { status: 409 });
      }
      const createdAt = new Date().toISOString();
      const replacedTryOns = planned.map((plan) => fresh[plan.date]?.tryOn?.image);
      for (const plan of planned) fresh[plan.date] = { ...plan, createdAt };
      await atomicJson(plansFile, fresh);
      await Promise.all(replacedTryOns.map(removeOutfitImage));
      return await planList(fresh);
    });
  }

  // Read-modify-write of one library record; returns the updated record or null if it is gone.
  function updateRecord(id, change) {
    return serial(async () => {
      const records = await loadImported();
      const record = records.find((item) => item.id === id);
      if (!record) return null;
      await change(record);
      await atomicJson(importedFile, records);
      return record;
    });
  }

  async function editRecord(id, input) {
    // Invalid values are ignored rather than normalized to defaults, so a bad category never turns a piece into a top.
    const valid = { name: (value) => typeof value === "string", part: (value) => PARTS.has(value), color: (value) => HEX_COLOR.test(value), secondaryColor: (value) => value === null || HEX_COLOR.test(value), description: (value) => typeof value === "string", text: (value) => typeof value === "string", tags: Array.isArray, wears: (value) => value === null || (Number.isInteger(value) && value >= 1 && value <= 10) };
    const fields = Object.keys(valid).filter((key) => key in input && valid[key](input[key]));
    const record = await updateRecord(id, (record) => {
      const metadata = normalizeMetadata({ ...record, ...Object.fromEntries(fields.map((key) => [key, input[key]])) });
      Object.assign(record, { name: metadata.name, part: metadata.part, color: metadata.color, secondaryColor: metadata.secondaryColor, description: metadata.description, text: metadata.text, tags: metadata.tags, palette: [metadata.color, metadata.secondaryColor].filter(Boolean) });
      // null goes back to the category default.
      if (input.wears === null) delete record.wears;
      else if (fields.includes("wears")) record.wears = input.wears;
    });
    if (!record) throw Object.assign(new Error("Imported wardrobe item not found"), { status: 404 });
    return record;
  }

  // Cuts out the back of a piece from the user's photo, in the background like any other generation.
  async function startBack(id, input) {
    const photo = await normalizeImage(decodeImage(input).data);
    const lock = `back:${id}`;
    if (running.has(lock)) throw Object.assign(new Error("The back is already being cut out"), { status: 409 });
    // Reserved before any await so a second request can't start a duplicate generation.
    running.set(lock, null);
    const record = await updateRecord(id, (record) => { record.back = { status: "processing" }; }).catch((error) => { running.delete(lock); throw error; });
    if (!record) {
      running.delete(lock);
      throw Object.assign(new Error("Imported wardrobe item not found"), { status: 404 });
    }
    const task = (async () => {
      try {
        const chromaKey = chooseChromaKey(record.color);
        const transparent = (await ai.status()).provider === "codex";
        const prompt = `${buildGarmentPrompt({ ...record, name: `${record.name}, back view` }, chromaKey, { transparent })}

Back view: Image 1 shows the BACK of this garment. Reconstruct the garment as seen from behind, exactly as in Image 1. Image 2 is the existing front cutout of the same garment: keep color, material and proportions consistent with it, but do not copy front-only details such as buttons, plackets or chest graphics onto the back.`;
        const front = await readFile(path.join(libraryAssetDir, path.basename(record.image)));
        let bytes = await ai.editImage({ size: "1024x1024", quality: setting("OPENAI_IMAGE_QUALITY", "high"), transparent, prompt, images: [
          { data: photo, role: "the user's photo of the back of the garment; reproduce this exact back" },
          { data: await normalizeImage(front), role: "the existing front cutout of the same garment, for consistency only" },
        ] });
        bytes = await hasTransparentBackground(bytes) ? await frameTransparentGarment(bytes) : await removeChromaBackground(bytes, chromaKey);
        const file = `${id}-back-${Date.now()}.png`;
        await writeFile(path.join(libraryAssetDir, file), bytes);
        // removeBack clears the processing status; then this result is stale and is thrown away.
        let previous = null;
        let removed = false;
        const updated = await updateRecord(id, (record) => {
          if (record.back?.status !== "processing") { removed = true; return; }
          previous = record.backImage; record.backImage = `${LIBRARY_ASSET_ROOT}/${file}`; record.back = { status: "ready", updatedAt: new Date().toISOString() };
        });
        if (!updated) removed = true;
        const stale = removed ? file : previous;
        if (stale) await rm(path.join(libraryAssetDir, path.basename(stale)), { force: true });
      } catch (error) {
        await updateRecord(id, (record) => { if (record.back?.status === "processing") record.back = { status: "failed", error: error.message, updatedAt: new Date().toISOString() }; });
      }
    })().finally(() => running.delete(lock));
    running.set(lock, task);
    return record;
  }

  async function removeBack(id) {
    let previous = null;
    const record = await updateRecord(id, (record) => { previous = record.backImage; record.backImage = null; record.back = null; });
    if (!record) throw Object.assign(new Error("Imported wardrobe item not found"), { status: 404 });
    if (previous) await rm(path.join(libraryAssetDir, path.basename(previous)), { force: true });
    return record;
  }

  async function readModelReference() {
    const modelPath = path.resolve(root, setting("WARDROBE_MODEL_REFERENCE", "data/model-reference.png"));
    try {
      return await readFile(modelPath);
    } catch (error) {
      if (error.code === "ENOENT") throw Object.assign(new Error("Add a photo of yourself at data/model-reference.png on your Mac to try outfits on."), { status: 409 });
      throw error;
    }
  }

  const removeOutfitImage = (image) => image && rm(path.join(outfitDir, path.basename(image)), { force: true });

  // Saves try-on progress only if the plan still has the same garments; a restyle discards stale results.
  function saveTryOn(date, key, tryOn) {
    return serial(async () => {
      const plans = await loadPlans();
      const plan = plans[date];
      if (!plan || plan.garmentIds.join("+") !== key) return await removeOutfitImage(tryOn.image);
      const previous = plan.tryOn?.image;
      plan.tryOn = { ...tryOn, updatedAt: new Date().toISOString() };
      await atomicJson(plansFile, plans);
      if (previous !== plan.tryOn.image) await removeOutfitImage(previous);
    });
  }

  async function startTryOn(date) {
    const plan = (await loadPlans())[date];
    if (!plan) throw Object.assign(new Error("No outfit planned for that day"), { status: 404 });
    const reference = await readModelReference();
    const library = await loadImported();
    const garments = plan.garmentIds.map((id) => library.find((item) => item.id === id));
    if (garments.some((item) => !item?.image)) throw Object.assign(new Error("A piece in this outfit was removed. Restyle the day first."), { status: 409 });
    const lock = `try-on:${date}`;
    if (!running.has(lock)) {
      // Reserved before any await so a second request can't start a duplicate generation.
      running.set(lock, null);
      const key = plan.garmentIds.join("+");
      await saveTryOn(date, key, { status: "processing" }).catch((error) => { running.delete(lock); throw error; });
      const task = (async () => {
        try {
          const images = [{ data: reference, role: "identity reference: the exact person to dress" }];
          for (const { item, side, image } of tryOnReferences(garments)) {
            images.push({ data: await readFile(path.join(libraryAssetDir, path.basename(image))), role: `exact ${PART_NAMES[item.part] || "garment"} to wear: ${item.name}, ${side} view (transparent cutout)` });
          }
          const bytes = await ai.editImage({ size: "1024x1536", quality: setting("OPENAI_IMAGE_QUALITY", "high"), images: await Promise.all(images.map(async (image) => ({ ...image, data: await normalizeImage(image.data) }))), prompt: buildTryOnPrompt(plan, garments) });
          await mkdir(outfitDir, { recursive: true });
          const file = `${date}-${Date.now()}.png`;
          await writeFile(path.join(outfitDir, file), bytes);
          await saveTryOn(date, key, { status: "ready", image: `/api/import/outfits/${file}` });
        } catch (error) {
          await saveTryOn(date, key, { status: "failed", error: error.message });
        }
      })().finally(() => running.delete(lock));
      running.set(lock, task);
    }
    return planList(await loadPlans());
  }

  // Held open until every running generation finishes (capped), so a phone's background download can wake it.
  async function waitForWork(since) {
    const started = Date.now();
    while (running.size && Date.now() - started < 10 * 60 * 1000) await new Promise((resolve) => setTimeout(resolve, 2000));
    // Taken before reading results: the next wait starts here, so nothing finishing in between is missed.
    const cursor = Date.now();
    const ids = await readdir(jobsDir).catch(() => []);
    const jobs = (await Promise.all(ids.map((id) => loadJob(id)))).filter((job) => job && job.status !== "complete");
    const reviews = jobs.filter((job) => [job.stages.crop, job.stages.garment].some((stage) => stage?.status === "review" || stage?.status === "failed")).length;
    const tryOns = Object.values(await loadPlans())
      .filter((plan) => plan.tryOn && plan.tryOn.status !== "processing" && Date.parse(plan.tryOn.updatedAt) >= since)
      .map((plan) => ({ date: plan.date, name: plan.name, status: plan.tryOn.status }));
    const backs = (await loadImported())
      .filter((record) => record.back && record.back.status !== "processing" && Date.parse(record.back.updatedAt) >= since)
      .map((record) => ({ name: record.name, status: record.back.status }));
    return { busy: running.size > 0, reviews, tryOns, backs, cursor };
  }

  function persistImported(job, includeModeled = false) {
    return serial(() => writeImported(job, includeModeled));
  }

  async function writeImported(job, includeModeled) {
    const id = `import-${job.id}`;
    await mkdir(libraryAssetDir, { recursive: true });
    const garmentName = `${id}-garment.png`;
    const garmentSource = job.stages.garment.assetUrl
      ? path.basename(new URL(job.stages.garment.assetUrl, "http://localhost").pathname)
      : `garment-${job.stages.garment.attempts}.png`;
    await copyFile(path.join(jobsDir, job.id, garmentSource), path.join(libraryAssetDir, garmentName));
    let modeledImage = null;
    if (includeModeled) {
      const modeledName = `${id}-modeled.png`;
      const modeledSource = job.stages.modeled.assetUrl
        ? path.basename(new URL(job.stages.modeled.assetUrl, "http://localhost").pathname)
        : `modeled-${job.stages.modeled.attempts}.png`;
      await copyFile(path.join(jobsDir, job.id, modeledSource), path.join(libraryAssetDir, modeledName));
      modeledImage = `${LIBRARY_ASSET_ROOT}/${modeledName}`;
    }
    const metadata = job.metadata || {};
    const records = await loadImported();
    const existing = records.find((record) => record.id === id);
    const record = {
      id,
      name: metadata.name || "New piece",
      part: metadata.part || "upperbody",
      color: metadata.color || "#d8d0c2",
      secondaryColor: metadata.secondaryColor || null,
      palette: [metadata.color, metadata.secondaryColor].filter(Boolean),
      description: metadata.description || "",
      text: metadata.text || "",
      tags: Array.isArray(metadata.tags) ? metadata.tags : [],
      image: `${LIBRARY_ASSET_ROOT}/${garmentName}`,
      thumbnail: `${LIBRARY_ASSET_ROOT}/${garmentName}`,
      modeledImage: modeledImage || existing?.modeledImage || null,
      backImage: existing?.backImage || null,
      back: existing?.back || null,
      unavailable: existing?.unavailable || false,
      importJobId: job.id,
    };
    const next = [...records.filter((item) => item.id !== id), record];
    await atomicJson(importedFile, next);
    return record;
  }

  async function generate(job, stageName) {
    const lock = `${job.id}:${stageName}`;
    if (running.has(lock)) return running.get(lock);
    const task = (async () => {
      const current = await loadJob(job.id);
      const stage = current.stages[stageName];
      stage.status = "processing"; stage.decision = null; stage.error = null; stage.attempts += 1; stage.updatedAt = new Date().toISOString();
      await saveJob(current);
      let failedAssetUrl = null;
      let chromaKeyUsed = null;
      try {
        const dir = path.join(jobsDir, current.id);
        const output = path.join(dir, `${stageName}-${stage.attempts}.png`);
        // The photo the user selected: cropped to the garment when detection produced a crop.
        const selected = await readFile(path.join(dir, current.internal.cropFile || current.internal.originalFile));
        const fullPhoto = current.internal.cropFile ? await readFile(path.join(dir, current.internal.originalFile)) : null;
        let bytes;
        if (stageName === "garment") {
          chromaKeyUsed = chooseChromaKey(current.metadata.color);
          const transparent = (await ai.status()).provider === "codex";
          const basePrompt = options.garmentPrompt || buildGarmentPrompt(current.metadata, chromaKeyUsed, { transparent });
          const images = [{ data: selected, role: "the selected photo cropped to the garment; reproduce this exact garment" }];
          if (fullPhoto) images.push({ data: fullPhoto, role: "the full selected photo, for context only" });
          bytes = await ai.editImage({ model: setting("OPENAI_GARMENT_MODEL"), quality: setting("OPENAI_IMAGE_QUALITY", "high"), size: "1024x1024", transparent, images: await Promise.all(images.map(async (image) => ({ ...image, data: await normalizeImage(image.data) }))), prompt: current.stages.garment.prompt ? `${basePrompt}\nUser regeneration direction: ${current.stages.garment.prompt}` : basePrompt });
          const rawName = `${stageName}-${stage.attempts}-source.png`;
          await writeFile(path.join(dir, rawName), bytes);
          failedAssetUrl = `${ASSET_ROOT}/${current.id}/${rawName}`;
          bytes = await hasTransparentBackground(bytes) ? await frameTransparentGarment(bytes) : await removeChromaBackground(bytes, chromaKeyUsed);
        } else {
          const garmentName = current.stages.garment.assetUrl
            ? path.basename(new URL(current.stages.garment.assetUrl, "http://localhost").pathname)
            : `garment-${current.stages.garment.attempts}.png`;
          const garmentFile = path.join(dir, garmentName);
          const garment = { data: await readFile(garmentFile), mime: "image/png", name: "garment.png" };
          const modelPath = path.resolve(root, setting("WARDROBE_MODEL_REFERENCE", "data/model-reference.png"));
          let modelData;
          try {
            modelData = await readFile(modelPath);
          } catch (error) {
            if (error.code === "ENOENT") throw new Error(`Model reference not found at ${modelPath}. Set WARDROBE_MODEL_REFERENCE or add data/model-reference.png.`);
            throw error;
          }
          const basePrompt = options.modeledPrompt || "Create a professional horizontal 3:2 editorial fashion photograph of the person in Image 1 wearing the exact garment from Image 2. Image 3 is the user's original photo of that garment: use it to match its real color, texture and fit, but do not copy its background, wearer or other items. Preserve the person's recognizable identity, face, hair, age and proportions. Preserve every garment color, material, fit, construction, graphic, logo and distinctive detail. Keep the complete featured item clearly visible and unobstructed, use understated neutral supporting clothes, realistic anatomy, natural light, authentic fabric, a tasteful real-world setting, and leave environmental space around the model. No text, watermark, product mockup, or synthetic appearance.";
          bytes = await ai.editImage({ model: setting("OPENAI_MODELED_MODEL"), quality: setting("OPENAI_IMAGE_QUALITY", "high"), size: "1536x1024", images: await Promise.all([
            { data: modelData, role: "identity reference: the person to photograph" },
            { data: garment.data, role: "the exact garment to dress them in (transparent cutout)" },
            { data: selected, role: "the selected original photo of the garment, for fidelity context only" },
          ].map(async (image) => ({ ...image, data: await normalizeImage(image.data) }))), prompt: current.stages.modeled.prompt ? `${basePrompt}\nUser regeneration direction: ${current.stages.modeled.prompt}` : basePrompt });
        }
        await writeFile(output, bytes);
        const fresh = await loadJob(current.id);
        fresh.stages[stageName].status = "review";
        fresh.stages[stageName].assetUrl = `${ASSET_ROOT}/${fresh.id}/${path.basename(output)}`;
        fresh.stages[stageName].failedAssetUrl = null;
        fresh.stages[stageName].cleanupPreviewUrl = null;
        fresh.stages[stageName].cleanupDiagnostics = null;
        if (chromaKeyUsed) fresh.stages[stageName].chromaKey = chromaKeyUsed;
        fresh.stages[stageName].updatedAt = new Date().toISOString();
        await saveJob(fresh);
      } catch (error) {
        const fresh = await loadJob(current.id);
        fresh.stages[stageName].status = "failed"; fresh.stages[stageName].error = error.message; fresh.stages[stageName].updatedAt = new Date().toISOString();
        if (typeof failedAssetUrl === "string") fresh.stages[stageName].failedAssetUrl = failedAssetUrl;
        if (chromaKeyUsed) fresh.stages[stageName].chromaKey = chromaKeyUsed;
        await saveJob(fresh);
      }
    })().finally(() => running.delete(lock));
    running.set(lock, task);
    return task;
  }

  async function handler(req, res, next) {
    const url = new URL(req.url, "http://localhost");
    if (!url.pathname.startsWith("/api/import/")) return next();
    try {
      if (url.pathname === "/api/import/wardrobe" && req.method === "GET") {
        return json(res, 200, await loadImported());
      }
      if (url.pathname === "/api/import/config" && req.method === "GET") {
        return json(res, 200, await setupStatus());
      }
      const wardrobeDeleteMatch = url.pathname.match(/^\/api\/import\/wardrobe\/(import-[a-f0-9-]{36})$/i);
      if (wardrobeDeleteMatch && req.method === "PATCH") {
        return json(res, 200, await editRecord(wardrobeDeleteMatch[1], await body(req)));
      }
      const backMatch = url.pathname.match(/^\/api\/import\/wardrobe\/(import-[a-f0-9-]{36})\/back$/i);
      if (backMatch && req.method === "POST") {
        return json(res, 202, await startBack(backMatch[1], await body(req)));
      }
      if (backMatch && req.method === "DELETE") {
        return json(res, 200, await removeBack(backMatch[1]));
      }
      if (wardrobeDeleteMatch && req.method === "DELETE") {
        const id = wardrobeDeleteMatch[1];
        let removed = null;
        await serial(async () => {
          const records = await loadImported();
          removed = records.find((record) => record.id === id) || null;
          if (removed) await atomicJson(importedFile, records.filter((record) => record.id !== id));
        });
        if (!removed) return json(res, 404, { error: "Imported wardrobe item not found" });
        await Promise.all([
          rm(path.join(libraryAssetDir, `${id}-garment.png`), { force: true }),
          rm(path.join(libraryAssetDir, `${id}-modeled.png`), { force: true }),
          removed.backImage && rm(path.join(libraryAssetDir, path.basename(removed.backImage)), { force: true }),
        ]);
        return json(res, 200, { deleted: true, id });
      }
      if (url.pathname === "/api/import/wardrobe" && req.method === "PATCH") {
        const input = await body(req);
        if (!Array.isArray(input.ids) || typeof input.unavailable !== "boolean") throw Object.assign(new Error("Expected { ids: string[], unavailable: boolean }"), { status: 400 });
        const ids = new Set(input.ids);
        return json(res, 200, await serial(async () => {
          const records = await loadImported();
          for (const record of records) if (ids.has(record.id)) record.unavailable = input.unavailable;
          await atomicJson(importedFile, records);
          return records;
        }));
      }
      if (url.pathname === "/api/import/plans" && req.method === "GET") {
        return json(res, 200, await planList(await loadPlans()));
      }
      if (url.pathname === "/api/import/plans" && req.method === "POST") {
        return json(res, 200, await planOutfits(await body(req)));
      }
      const tryOnMatch = url.pathname.match(/^\/api\/import\/plans\/(\d{4}-\d{2}-\d{2})\/try-on$/);
      if (tryOnMatch && req.method === "POST") {
        return json(res, 202, await startTryOn(tryOnMatch[1]));
      }
      if (url.pathname === "/api/import/wait" && req.method === "GET") {
        const since = Number(url.searchParams.get("since"));
        return json(res, 200, await waitForWork(Number.isFinite(since) ? since : Date.now()));
      }
      const outfitAssetMatch = url.pathname.match(/^\/api\/import\/outfits\/([\w.-]+\.png)$/);
      if (outfitAssetMatch && req.method === "GET") {
        const file = path.join(outfitDir, path.basename(outfitAssetMatch[1]));
        await stat(file);
        res.setHeader("Content-Type", "image/png");
        res.setHeader("Cache-Control", "public, max-age=31536000, immutable");
        return res.end(await readFile(file));
      }
      const planMatch = url.pathname.match(/^\/api\/import\/plans\/(\d{4}-\d{2}-\d{2})$/);
      if (planMatch && req.method === "DELETE") {
        return json(res, 200, await serial(async () => {
          const plans = await loadPlans();
          const image = plans[planMatch[1]]?.tryOn?.image;
          delete plans[planMatch[1]];
          await atomicJson(plansFile, plans);
          await removeOutfitImage(image);
          return await planList(plans);
        }));
      }
      const libraryAssetMatch = url.pathname.match(/^\/api\/import\/library\/([\w.-]+)$/i);
      if (libraryAssetMatch && req.method === "GET") {
        const file = path.join(libraryAssetDir, path.basename(libraryAssetMatch[1]));
        await stat(file);
        res.setHeader("Content-Type", "image/png");
        res.setHeader("Cache-Control", "public, max-age=31536000, immutable");
        return res.end(await readFile(file));
      }
      const assetMatch = url.pathname.match(/^\/api\/import\/assets\/([a-f0-9-]{36})\/([\w.-]+)$/i);
      if (assetMatch && req.method === "GET") {
        const file = path.join(jobsDir, assetMatch[1], path.basename(assetMatch[2]));
        await stat(file);
        res.setHeader("Content-Type", file.endsWith(".svg") ? "image/svg+xml" : "image/png");
        res.setHeader("Cache-Control", "no-store");
        return res.end(await readFile(file));
      }
      if (url.pathname === API_ROOT && req.method === "POST") {
        const setup = await setupStatus();
        if (!setup.ready) {
          return json(res, 503, { error: "Setup required: run `codex login` (ChatGPT plan) or add OPENAI_API_KEY to .env, then restart the app." });
        }
        const input = await body(req);
        const image = decodeImage(input);
        const normalizedImage = await normalizeImage(image.data);
        const detected = (await analyzeClothes(ai, normalizedImage)).map(normalizeMetadata);
        const jobs = [];
        for (const metadata of detected) {
          const id = randomUUID();
          const dir = path.join(jobsDir, id); await mkdir(dir, { recursive: true });
          const originalFile = "original.png";
          const cropFile = "crop.png";
          const croppedImage = await cropDetectedItem(normalizedImage, metadata.boundingBox);
          await writeFile(path.join(dir, originalFile), normalizedImage);
          await writeFile(path.join(dir, cropFile), croppedImage);
          const now = new Date().toISOString();
          const cropStage = { ...stageState(), status: "review", assetUrl: `${ASSET_ROOT}/${id}/${cropFile}`, updatedAt: now };
          const job = { id, status: "active", metadata, stages: { crop: cropStage, garment: stageState(), modeled: stageState() }, createdAt: now, updatedAt: now, internal: { originalFile, cropFile, originalMime: "image/png" } };
          job.originalAssetUrl = `${ASSET_ROOT}/${id}/${originalFile}`;
          await saveJob(job); jobs.push(publicJob(job));
        }
        return json(res, 202, { jobs, noClothingDetected: jobs.length === 0 });
      }
      if (url.pathname === API_ROOT && req.method === "GET") {
        const ids = await readdir(jobsDir).catch(() => []);
        const loadedJobs = (await Promise.all(ids.map((id) => loadJob(id)))).filter(Boolean);
        const hiddenJobs = loadedJobs.filter((job) => job.status === "complete" || job.stages.crop?.status === "rejected" || job.stages.garment.status === "rejected" || job.stages.modeled.status === "rejected");
        await Promise.all(hiddenJobs.map((job) => rm(path.join(jobsDir, job.id), { recursive: true, force: true })));
        const jobs = loadedJobs.filter((job) => !hiddenJobs.includes(job)).sort((a, b) => a.createdAt.localeCompare(b.createdAt));
        return json(res, 200, jobs.map(publicJob));
      }
      const match = url.pathname.match(/^\/api\/import\/jobs\/([a-f0-9-]{36})(?:\/(.*))?$/i);
      if (!match) return json(res, 404, { error: "Not found" });
      const job = await loadJob(match[1]);
      if (!job) return json(res, 404, { error: "Job not found" });
      const action = match[2] || "";
      if (!action && req.method === "GET") return json(res, 200, publicJob(job));
      if (!action && req.method === "DELETE") {
        await rm(path.join(jobsDir, job.id), { recursive: true, force: true });
        return json(res, 200, { deleted: true, id: job.id });
      }
      if (action === "metadata" && (req.method === "PATCH" || req.method === "PUT")) {
        const input = await body(req);
        if (!input.metadata || typeof input.metadata !== "object" || Array.isArray(input.metadata)) throw Object.assign(new Error("metadata must be an object"), { status: 400 });
        job.metadata = normalizeMetadata({ ...job.metadata, ...input.metadata }); await saveJob(job);
        return json(res, 200, publicJob(job));
      }
      const cleanupAction = action.match(/^stages\/garment\/(cleanup-preview|cleanup-accept)$/);
      if (cleanupAction && req.method === "POST") {
        const stage = job.stages.garment;
        if (stage.status !== "failed" || !stage.failedAssetUrl) {
          throw Object.assign(new Error("No failed garment source is available for cleanup"), { status: 409 });
        }
        const input = await body(req);
        const tolerance = cleanupTolerance(input.tolerance);
        const sourceName = path.basename(new URL(stage.failedAssetUrl, "http://localhost").pathname);
        const source = await readFile(path.join(jobsDir, job.id, sourceName));
        const key = stage.chromaKey || chooseChromaKey(job.metadata?.color);
        const cleaned = await processChromaBackground(source, key, { tolerance });
        const previewName = `garment-${stage.attempts}-cleanup-${tolerance}.png`;
        const previewUrl = `${ASSET_ROOT}/${job.id}/${previewName}`;
        await writeFile(path.join(jobsDir, job.id, previewName), cleaned.bytes);
        stage.chromaKey = key;
        stage.cleanupTolerance = cleaned.tolerance;
        stage.cleanupDiagnostics = cleaned.verification;
        stage.cleanupPreviewUrl = previewUrl;
        stage.updatedAt = new Date().toISOString();
        if (cleanupAction[1] === "cleanup-accept") {
          stage.status = "review";
          stage.decision = null;
          stage.error = null;
          stage.assetUrl = previewUrl;
        }
        await saveJob(job);
        return json(res, 200, publicJob(job));
      }
      const stageMatch = action.match(/^stages\/(crop|garment|modeled)\/(approve|reject|regenerate)$/);
      if (stageMatch && req.method === "POST") {
        const [, stageName, decision] = stageMatch;
        if (!STAGES.has(stageName)) throw Object.assign(new Error("Invalid stage"), { status: 400 });
        if (decision === "regenerate") {
          if (stageName === "crop") throw Object.assign(new Error("Upload the image again to create new crops"), { status: 400 });
          const input = await body(req);
          job.stages[stageName].prompt = typeof input.prompt === "string" ? input.prompt.trim().slice(0, 1200) || null : null;
          job.stages[stageName].status = "queued";
          job.stages[stageName].decision = null;
          await saveJob(job);
          void generate(job, stageName);
          return json(res, 202, publicJob(job));
        }
        if (!DECISIONS.has(decision) || job.stages[stageName].status !== "review") throw Object.assign(new Error("Stage is not ready for review"), { status: 409 });
        const previousStatus = job.stages[stageName].status;
        const previousDecision = job.stages[stageName].decision;
        const previousJobStatus = job.status;
        job.stages[stageName].decision = decision === "approve" ? "approved" : "rejected";
        job.stages[stageName].status = job.stages[stageName].decision;
        job.stages[stageName].error = null;
        job.stages[stageName].updatedAt = new Date().toISOString();
        const startGarment = stageName === "crop" && decision === "approve" && job.stages.garment.status === "pending";
        await saveJob(job);
        if (decision === "approve" && stageName !== "crop") {
          try {
            await persistImported(job, stageName === "modeled");
            // Imports finish at the cutout. Marked complete only after the copy, because listing jobs deletes complete ones.
            job.status = "complete";
            await saveJob(job);
          } catch (error) {
            job.stages[stageName].status = previousStatus;
            job.stages[stageName].decision = previousDecision;
            job.status = previousJobStatus;
            await saveJob(job);
            throw error;
          }
        }
        if (decision === "reject") await rm(path.join(jobsDir, job.id), { recursive: true, force: true });
        if (startGarment) void generate(job, "garment");
        const response = publicJob(job);
        if (job.status === "complete") await rm(path.join(jobsDir, job.id), { recursive: true, force: true });
        return json(res, 200, response);
      }
      return json(res, 404, { error: "Not found" });
    } catch (error) {
      const statusCode = error.code === "ENOENT" ? 404 : error.status || 500;
      return json(res, statusCode, { error: statusCode === 500 ? "Internal server error" : error.message, ...(process.env.NODE_ENV === "development" && statusCode === 500 ? { detail: error.message } : {}) });
    }
  }

  return {
    name: "wardrobe-import-job-api",
    apply: "serve",
    async configResolved(config) {
      root = config.root;
      const dataDir = path.resolve(root, setting("WARDROBE_DATA_DIR", "data"));
      jobsDir = path.join(dataDir, "jobs");
      importedFile = path.join(dataDir, "library.json");
      plansFile = path.join(dataDir, "plans.json");
      outfitDir = path.join(dataDir, "outfit-images");
      // Back cutouts cannot survive a restart either.
      const library = await loadImported().catch(() => []);
      if (library.some((record) => record.back?.status === "processing")) {
        for (const record of library) if (record.back?.status === "processing") record.back = { status: "failed", error: "Interrupted, try again" };
        await atomicJson(importedFile, library);
      }
      // A try-on cannot survive a restart; let the user ask again.
      const plans = await loadPlans();
      const interrupted = Object.values(plans).filter((plan) => plan.tryOn?.status === "processing");
      for (const plan of interrupted) plan.tryOn = { status: "failed", error: "Interrupted, try again", updatedAt: new Date().toISOString() };
      if (interrupted.length) await atomicJson(plansFile, plans);
      libraryAssetDir = path.join(dataDir, "imported");
      await mkdir(jobsDir, { recursive: true });
      await mkdir(libraryAssetDir, { recursive: true });
      const ids = await readdir(jobsDir).catch(() => []);
      for (const id of ids) {
        const job = await loadJob(id);
        if (!job) continue;
        if (job.status === "complete") {
          try {
            await persistImported(job, job.stages.modeled.status === "approved");
            await rm(path.join(jobsDir, job.id), { recursive: true, force: true });
          } catch (error) {
            job.status = "active";
            job.stages.modeled.status = "review";
            job.stages.modeled.decision = null;
            job.stages.modeled.error = null;
            await saveJob(job);
          }
          continue;
        }
        if (job.stages.crop?.status === "rejected" || job.stages.garment.status === "rejected" || job.stages.modeled.status === "rejected") {
          await rm(path.join(jobsDir, job.id), { recursive: true, force: true });
          continue;
        }
        if (job.stages.crop && job.stages.crop.status !== "approved") continue;
        if (["processing", "queued"].includes(job.stages.garment.status)) {
          job.stages.garment.status = "pending";
          await saveJob(job);
          void generate(job, "garment");
        } else if (job.stages.garment.status === "approved") {
          // Older jobs that were waiting for a per-piece modeled photo are already in the library.
          await persistImported(job, false);
          await rm(path.join(jobsDir, job.id), { recursive: true, force: true });
        }
      }
    },
    configureServer(server) { server.middlewares.use(handler); },
    configurePreviewServer(server) { server.middlewares.use(handler); },
  };
}
