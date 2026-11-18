import { randomUUID } from "node:crypto";
import { copyFile, mkdir, readFile, readdir, rename, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import sharp from "sharp";
import { reviewCutout, reviewDetection, reviewWorn, untilApproved, withFeedback } from "./ai-review.mjs";
import { createAIProvider } from "./openai-provider.mjs";
import { parseChangelog } from "./changelog.mjs";
import { createKeyedLock, createQueue } from "./queue.mjs";
import { DATE, DEFAULT_WEARS, PALETTES, WEATHERS, buildPlanPrompt, historyFor, includeIssues, layerIssues, pairIssues, planIssues, planSchema, repeatedGarments, restyleIssues, rotationIssues, swapIssues, validatePlan } from "./outfit-planner.mjs";

const API_ROOT = "/api/import/jobs";
const ASSET_ROOT = "/api/import/assets";
const LIBRARY_ASSET_ROOT = "/api/import/library";
const STAGES = new Set(["crop", "garment", "modeled"]);
const DECISIONS = new Set(["approve", "reject"]);
const PARTS = new Set(["upperbody", "midlayer", "wholebody_up", "lowerbody", "accessories_up", "shoes"]);
const HEX_COLOR = /^#[0-9a-f]{6}$/i;
// Bumped when the app needs endpoints or fields an older server lacks; the app compares it with its minimum.
export const API_VERSION = 6;
const SETTINGS = { checks: new Set(["thorough", "fast"]) };
// wears: how many times each category is worn before washing, unless a piece sets its own.
const DEFAULT_SETTINGS = { checks: "thorough", wears: DEFAULT_WEARS };
// Generations tried before the best one goes to the user with the reviewer's remaining notes.
const CUTOUT_ATTEMPTS = 3;
const TRY_ON_ATTEMPTS = 3;
const DETECT_ATTEMPTS = 2;
const PLAN_ATTEMPTS = 3;

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
    backText: typeof metadata.backText === "string" ? metadata.backText.trim().slice(0, 200) : "",
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

// 2048px is more than the AI uses; bigger photos only make every copy, upload and preview slower.
async function normalizeImage(bytes) {
  return sharp(bytes).rotate().resize(2048, 2048, { fit: "inside", withoutEnlargement: true }).toColorspace("srgb").png().toBuffer();
}

const previewWidth = (url) => {
  const width = Number(url.searchParams.get("w"));
  return Number.isInteger(width) && width >= 64 && width <= 2048 ? width : null;
};

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

Primary request: Reconstruct ONLY the complete empty ${name} (${category}) as a clean, front-facing ecommerce catalog product photograph. If a wearer is present, remove them. Remove every other garment, object, and background element. Show the complete item with no person, body, mannequin, or hanger visible.

Straighten: Lay the garment out straight and symmetrical, as if freshly steamed and neatly flat-laid. Smooth away wrinkles, creases and folds that come from how it was photographed, untwist it, and extend sleeves, legs, hoods, collars and hems naturally instead of bunched, folded over or tucked. Keep features that belong to the garment itself, such as pleats, ribbing, distressing, quilting or an intentionally crinkled fabric.

Garment fidelity: Preserve the reference garment's exact primary color ${primary}${secondary}, material and texture, silhouette, neckline, sleeves, fastenings, pattern, and distinctive details (${details}).${description} Preserve any clearly legible existing graphic or logo exactly, but do not invent or reinterpret uncertain logos, text, pockets, seams, hardware, colors, or decoration.${lettering}

Composition: Centered straight-on product view. Keep the entire garment inside the frame with generous, even padding on every side. No cropping or truncation.

Background: ${transparent
    ? `Fully transparent background with a real alpha channel: only the garment is opaque. No backdrop, floor, shadow, or reflection. Only if true transparency is impossible, use a perfectly flat uniform solid ${chromaKey} instead.`
    : `Perfectly flat, absolutely uniform solid ${chromaKey} chroma-key color, edge-to-edge. No shadows, gradient, texture, vignette, floor, horizon, reflection, or lighting variation.`}

Lighting: Neutral diffuse product lighting contained on the garment only.

Avoid: person, body, skin, hair, mannequin, hanger, props, other garments, wrinkles, folded or twisted sleeves, retail tags, cast shadow, contact shadow, reflection, watermark, caption, border, background variation, or chroma spill.

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

// Turns a generated image into a framed transparent cutout, keying out the chroma backdrop when it has no alpha.
async function cleanCutout(bytes, chromaKey) {
  return await hasTransparentBackground(bytes) ? frameTransparentGarment(bytes) : removeChromaBackground(bytes, chromaKey);
}

// True when an image already has a real transparent backdrop (at least 5% fully clear pixels, all four corners clear).
export async function hasTransparentBackground(bytes) {
  const { data, info } = await sharp(bytes).ensureAlpha().extractChannel(3).raw().toBuffer({ resolveWithObject: true });
  const clear = data.reduce((count, alpha) => count + (alpha <= 8 ? 1 : 0), 0);
  const corners = [0, info.width - 1, (info.height - 1) * info.width, info.height * info.width - 1];
  return clear / data.length >= 0.05 && corners.every((index) => data[index] <= 8);
}

// The garments' cutouts on one light sheet, numbered in reading order, for when separate images would pass the input limit.
export async function garmentSheet(cutouts) {
  const columns = cutouts.length <= 4 ? 2 : 3;
  const cell = 768;
  const rows = Math.ceil(cutouts.length / columns);
  const tiles = await Promise.all(cutouts.map(async (bytes, index) => {
    const image = await sharp(bytes).resize(cell - 120, cell - 120, { fit: "inside" }).png().toBuffer();
    const { width, height } = await sharp(image).metadata();
    const label = Buffer.from(`<svg width="96" height="96"><circle cx="48" cy="48" r="34" fill="#222"/><text x="48" y="62" font-size="40" font-family="Helvetica" font-weight="bold" fill="#fff" text-anchor="middle">${index + 1}</text></svg>`);
    const left = (index % columns) * cell, top = Math.floor(index / columns) * cell;
    return [{ input: image, left: left + Math.round((cell - width) / 2), top: top + Math.round((cell - height) / 2) }, { input: label, left: left + 12, top: top + 12 }];
  }));
  return sharp({ create: { width: columns * cell, height: rows * cell, channels: 3, background: "#ededed" } }).composite(tiles.flat()).png().toBuffer();
}

const PART_NAMES = { upperbody: "base top", midlayer: "mid layer", wholebody_up: "outer layer", lowerbody: "bottom", shoes: "shoes", accessories_up: "accessory" };

// Try-ons edit the user's own photo: their pose and face stay, only the clothes and the scene change. Regenerating them
// in a new pose (as a back view once did) loses who they are, so each garment is referenced by its front cutout only.
export function tryOnReferences(garments) {
  return garments.map((item) => ({ item, side: "front", image: item.image }));
}

const LAYER_ORDER = ["upperbody", "midlayer", "wholebody_up", "lowerbody", "shoes", "accessories_up"];
const SCENES = { warm: "a sunny, warm day outdoors", mild: "a bright, mild day", cold: "a crisp, cold day with soft winter light", rain: "an overcast, rainy-looking day on damp pavement, without rain drops on the lens" };

// Codex's image tool takes at most this many input images; beyond it, the garments share one numbered sheet.
export const IMAGE_INPUT_LIMIT = 5;

// face adds a close-up of the user's head as Image 2, so the garments start at Image 3; sheet puts them all in one image.
export function buildTryOnPrompt(plan, garments, { face = false, sheet = false } = {}) {
  const first = face ? 3 : 2;
  const describe = (item) => `exact ${PART_NAMES[item.part] || "garment"} (${item.name}).${item.text ? ` Its text reads: ${item.text}.` : ""}`;
  const references = sheet
    ? `Image ${first}: a reference sheet with every garment, each numbered in its corner:\n${garments.map((item, index) => `${index + 1}. ${describe(item)}`).join("\n")}`
    : tryOnReferences(garments).map(({ item }, index) => `Image ${index + first}: ${describe(item)}`).join("\n");
  const worn = [...garments].sort((a, b) => LAYER_ORDER.indexOf(a.part) - LAYER_ORDER.indexOf(b.part))
    .map((item) => `${PART_NAMES[item.part] || "garment"}: ${item.name}`).join("; ");
  const layered = garments.some((item) => item.part === "wholebody_up" || item.part === "midlayer")
    ? "\nLayering: base top innermost, then the mid layer, then the outer layer. The base top shows naturally a little at the neckline or below the hem of the layer over it. Only open a layer if its reference has a real full front zipper or buttons; never invent a closure."
    : "";
  return `Use case: identity-preserving clothing edit
Asset type: vertical outfit try-on photograph

Image 1: a photo of the user. This is the photo to edit.${face ? "\nImage 2: a close-up of the same person's head from Image 1, the authority for their face, hair and glasses." : ""}
${sheet ? "The last image holds" : "The remaining images are"} product cutouts of the exact garments to put on them:
${references}

Edit Image 1: replace everything the person wears, including any shoes, watch, wristband and anything they hold, with exactly this outfit and nothing else: ${worn}. Replace the background with ${SCENES[plan.weather] || "a softly lit, real-world setting"} that suits a ${plan.style} outfit, simple and softly out of focus.

Keep the person exactly as they are in Image 1: the same face and features, hair color, length and style, glasses, skin, age, height and build, and the same pose, camera angle and full-body framing from head to shoes, facing the camera. This must be unmistakably the same real person, not a lookalike: do not beautify, slim, de-age or restyle their hair. ${garments.some((item) => item.part === "shoes") ? "" : "Plain understated shoes replace theirs because no shoe reference is provided. "}Hands hang relaxed and empty.${layered}

Garment fidelity: each garment matches its cutout exactly: color, material, fit, construction, pattern, graphics, logos, proportions and closures, worn with natural drape and creases on this body. Text reads letter for letter as listed; never swap in a different or more familiar word or symbol.

Realism: one real camera photograph with natural light, true-to-life colors, natural skin texture and believable fabric; the lighting on the person matches the new scene.

Avoid: a different face or hairstyle, a new pose or back view, any of the original clothes, shoes or accessories from Image 1, hidden or redesigned garments, changed logos or text, extra layers, hats, bags or jewelry, cropped head or feet, extra people, text overlays, watermarks, a studio cutout look, or synthetic AI polish.`;
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

const ANALYZE_PROMPT = `Identify every distinct wearable clothing item visible in this image. A photo may show one isolated garment or a person wearing several items. Return one record per actual item that should enter a wardrobe. Ignore the person's body and non-wearable background objects. Only include items the photo is clearly meant to show: what the main person wears, or garments laid out or held as the subject. Leave out other people's clothes, things on hangers, chairs or floors in the background, items mostly out of frame, and layers hidden under others. Include small accessories such as glasses, watches, wristbands, jewelry or bags only when they are the clear focus of the photo, not when they are simply worn with an outfit. For each item, include a tight bounding box around only that item using integer coordinates normalized to a 1000 by 1000 image: x and y are the top-left corner, followed by width and height. Boxes may overlap when garments overlap, but each box must focus on one distinct item. Use only these category ids: upperbody (base tops worn against the skin: t-shirts, shirts, polos, tank tops, thin long-sleeve tees), midlayer (warm layers worn over a base top: hoodies, sweatshirts, sweaters, cardigans, fleeces, zip-up hoodies), wholebody_up (outerwear: jackets, coats, rain jackets, puffers, blazers, overshirts worn as jackets), lowerbody, accessories_up, shoes. Name each item specifically enough to tell it apart from similar pieces: color, distinguishing graphic or brand, and type, e.g. "Grey ROTATION LX varsity hoodie" or "Black Dickies chest-logo tee", not "Graphic hoodie". Give a primary hex color, an optional genuinely distinct secondary hex color, and 1-4 useful lowercase detail tags. description is one or two sentences a stylist can plan with: fabric and weight, fit, warmth, formality, and notable design details. text transcribes, letter for letter, every word printed, embroidered or patched on the outside of the item with its placement and relative size (leave out size, care and inside-neck labels), e.g. 'front: large arched "ROTATION", small "LX" centered below'; use an empty string when there is no legible text.`;

const ANALYZE_SCHEMA = { type: "object", additionalProperties: false, properties: { items: { type: "array", minItems: 0, maxItems: 8, items: { type: "object", additionalProperties: false, properties: { name: { type: "string" }, part: { type: "string", enum: [...PARTS] }, color: { type: "string", pattern: "^#[0-9A-Fa-f]{6}$" }, secondaryColor: { anyOf: [{ type: "string", pattern: "^#[0-9A-Fa-f]{6}$" }, { type: "null" }] }, description: { type: "string" }, text: { type: "string" }, tags: { type: "array", items: { type: "string" }, maxItems: 4 }, boundingBox: { type: "object", additionalProperties: false, properties: { x: { type: "integer", minimum: 0, maximum: 999 }, y: { type: "integer", minimum: 0, maximum: 999 }, width: { type: "integer", minimum: 1, maximum: 1000 }, height: { type: "integer", minimum: 1, maximum: 1000 } }, required: ["x", "y", "width", "height"] } }, required: ["name", "part", "color", "secondaryColor", "description", "text", "tags", "boundingBox"] } } }, required: ["items"] };

const HEX = { type: "string", pattern: "^#[0-9A-Fa-f]{6}$" };
const FACE_SCHEMA = { type: "object", additionalProperties: false, properties: { x: { type: "integer", minimum: 0, maximum: 999 }, y: { type: "integer", minimum: 0, maximum: 999 }, width: { type: "integer", minimum: 1, maximum: 1000 }, height: { type: "integer", minimum: 1, maximum: 1000 } }, required: ["x", "y", "width", "height"] };
const DETAILS_SCHEMA = { type: "object", additionalProperties: false, properties: { description: { type: "string" }, text: { type: "string" }, backText: { type: "string" }, tags: { type: "array", items: { type: "string" }, maxItems: 4 }, color: HEX, secondaryColor: { anyOf: [HEX, { type: "null" }] } }, required: ["description", "text", "backText", "tags", "color", "secondaryColor"] };

// Re-reads a piece's details from both sides once it has a back: colors, a description covering both, and each side's text.
async function describeBothSides(ai, record, front, back) {
  const flat = (bytes) => sharp(bytes).flatten({ background: "#e8e8e8" }).png().toBuffer();
  const current = { description: record.description, text: record.text, tags: record.tags, color: record.color, secondaryColor: record.secondaryColor };
  return ai.json({ kind: "vision", schema: DETAILS_SCHEMA, images: [await flat(front), await flat(back)], prompt: `Image 1 is the front and Image 2 the back of the same piece in a wardrobe app: ${record.name} (${record.part}).
Its current details: ${JSON.stringify(current)}
Update them so they describe the whole piece, front and back.
- description: one or two sentences for a stylist: fabric and weight, fit, warmth, formality, and notable design details on either side.
- text: every word on the outside of the FRONT, letter for letter, with placement and relative size, e.g. 'chest: small "DICKIES"'. Leave out size, care and inside-neck labels. Keep the current text unless Image 1 clearly shows otherwise. The same words can appear on both sides in different sizes and styles; then list them on each side, never move them from one to the other.
- backText: the same for the BACK, e.g. 'large "GO BROKE FOR PORSCHE" across the shoulders'. Empty when the back has no legible text.
- tags: 1-4 lowercase details.
- color: the main hex color; secondaryColor: a genuinely distinct second color across both sides, or null.` });
}

async function analyzeClothes(ai, image, feedback = []) {
  const parsed = await ai.json({ prompt: withFeedback(ANALYZE_PROMPT, feedback), images: [image], schema: ANALYZE_SCHEMA, kind: "vision" });
  if (!Array.isArray(parsed.items)) throw new Error("Clothing analysis returned an invalid clothing list");
  return parsed.items;
}

// Detects pieces, has a reviewer drop the ones the user isn't adding, and runs detection again when crops or labels are off.
async function detectClothes(ai, photo, report, run = untilApproved) {
  const { result } = await run({
    attempts: DETECT_ATTEMPTS,
    make: async (feedback) => {
      if (!feedback.length) report("Finding clothes…");
      const items = (await analyzeClothes(ai, photo, feedback)).map(normalizeMetadata);
      return Promise.all(items.map(async (metadata) => ({ metadata, crop: await cropDetectedItem(photo, metadata.boundingBox) })));
    },
    check: async (found) => {
      if (!found.length) return [];
      report(found.length === 1 ? "Checking the piece…" : `Checking ${found.length} pieces…`);
      const { keep, problems } = await reviewDetection(ai, { photo, found });
      // Dropped pieces leave the result in place, so a final attempt with notes still returns only kept ones.
      for (let index = found.length - 1; index >= 0; index -= 1) if (!keep[index]) found.splice(index, 1);
      return problems;
    },
    onRetry: (problems, attempt) => report(`Taking another look (${attempt}/${DETECT_ATTEMPTS}): ${problems[0]}`),
  }).catch((error) => { throw Object.assign(error, { status: 502 }); });
  return result;
}

export function wardrobeImportApi(options = {}) {
  let root;
  let jobsDir;
  let importedFile;
  let libraryAssetDir;
  let plansFile;
  let outfitDir;
  // Vite restarts the server inside the same process when the config or these scripts change, and work already in
  // flight keeps running in the old copy of this plugin. All live state is shared through globalThis, so the new copy
  // sees that work instead of resuming it a second time, and both copies queue their file writes in one line.
  const shared = (globalThis.__wardrobe ??= {});
  const running = (shared.running ??= new Map());
  const detectQueue = (shared.detectQueue ??= createQueue(2));
  const jobLock = (shared.jobLock ??= createKeyedLock());
  // Photos being searched for clothes in the background, by id. Their photo stays on disk until done, so a restart resumes them.
  const detections = (shared.detections ??= new Map());
  // Days being styled in the background, by date; a failure stays until the app has seen it.
  const styling = (shared.styling ??= new Map());
  // Small WebP previews of stored PNGs, keyed by file, width and change time.
  const previews = (shared.previews ??= new Map());
  let detectionsDir;
  // Live status lines for running AI work ("Checking the cutout…"), keyed by what they belong to; the app polls them.
  const progress = (shared.progress ??= new Map());
  const say = (key, message) => { if (key) (message ? progress.set(key, message) : progress.delete(key)); };
  const waiting = (key) => (ahead) => say(key, ahead ? `Waiting in line, ${ahead} ahead…` : "Up next…");
  const queued = (key, task) => imageQueue(() => { say(key, null); return task(); }, waiting(key));
  const retrying = (key, total) => (problems, attempt) => say(key, `Retrying (${attempt}/${total}): ${problems[0]}`);
  const libraryFile = (url) => path.join(libraryAssetDir, path.basename(url));
  let settingsFile;

  async function loadSettings() {
    try {
      const saved = JSON.parse(await readFile(settingsFile, "utf8"));
      return { ...DEFAULT_SETTINGS, ...saved, wears: { ...DEFAULT_WEARS, ...saved.wears } };
    } catch (error) { if (error.code === "ENOENT") return structuredClone(DEFAULT_SETTINGS); throw error; }
  }

  // Unknown keys and values are ignored, so an older app can't write anything the server doesn't understand.
  async function saveSettings(input) {
    return serial(async () => {
      const next = await loadSettings();
      for (const [key, allowed] of Object.entries(SETTINGS)) if (allowed.has(input?.[key])) next[key] = input[key];
      for (const [part, wears] of Object.entries(input?.wears && typeof input.wears === "object" ? input.wears : {})) {
        if (PARTS.has(part) && Number.isInteger(wears) && wears >= 1 && wears <= 10) next.wears[part] = wears;
      }
      await atomicJson(settingsFile, next);
      return next;
    });
  }

  // Pieces without their own wear count get the user's default for their category, so the planner sees one number.
  const withWears = (items, settings) => items.map((item) => (Number.isInteger(item.wears) ? item : { ...item, wears: settings.wears[item.part] ?? 1 }));

  // The Fast setting skips the AI reviewer and its retries for image work and detection.
  const reviewed = async (options) => ((await loadSettings()).checks === "fast" ? untilApproved({ ...options, attempts: 1, check: () => [] }) : untilApproved(options));

  async function versionInfo() {
    const pkg = JSON.parse(await readFile(path.join(root, "package.json"), "utf8"));
    const changelog = parseChangelog(await readFile(path.join(root, "CHANGELOG.md"), "utf8").catch(() => ""));
    return { version: pkg.version, api: API_VERSION, changelog };
  }

  // The photo of the user that try-ons dress, uploaded from the phone instead of copied onto the Mac.
  async function saveModelReference(input) {
    const photo = await sharp(decodeImage(input).data).rotate().resize(2048, 2048, { fit: "inside", withoutEnlargement: true }).toColorspace("srgb").png().toBuffer();
    const file = path.resolve(root, setting("WARDROBE_MODEL_REFERENCE", "data/model-reference.png"));
    await mkdir(path.dirname(file), { recursive: true });
    await writeFile(file, photo);
    return setupStatus();
  }
  shared.writeQueue ??= Promise.resolve();
  // Serializes read-modify-write cycles on library.json and plans.json.
  const serial = (task) => (shared.writeQueue = shared.writeQueue.then(task, task));
  const setting = (name, fallback = "") => options.env?.[name] || process.env[name] || fallback;
  const ai = createAIProvider(setting);
  // Image work (cutouts, try-ons) runs a few at a time so the Mac and the plan's rate limits aren't swamped; the rest wait in line.
  const imageQueue = (shared.imageQueue ??= createQueue(Math.max(1, Number(setting("WARDROBE_AI_CONCURRENCY", "2")) || 2)));

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
    const items = withWears(await loadImported(), await loadSettings());
    return Object.values(plans).sort((a, b) => a.date.localeCompare(b.date)).map((plan) => ({ ...plan, repeats: repeatedGarments(plans, plan.date, items) }));
  }

  async function planOutfits(input) {
    if (!Array.isArray(input.days) || !input.days.length || input.days.length > 31) throw Object.assign(new Error("days must list 1-31 days"), { status: 400 });
    const days = input.days.map((day) => ({
      date: typeof day?.date === "string" && DATE.test(day.date) && !Number.isNaN(Date.parse(day.date)) ? day.date : null,
      style: typeof day?.style === "string" ? day.style.trim().slice(0, 80) || "everyday" : "everyday",
      weather: WEATHERS.has(day?.weather) ? day.weather : "auto",
      palette: PALETTES.has(day?.palette) ? day.palette : "any",
      include: typeof day?.include === "string" && day.include ? day.include : undefined,
      note: typeof day?.note === "string" ? day.note.trim().slice(0, 200) : "",
      replace: typeof day?.replace === "string" ? day.replace : undefined,
    }));
    if (days.some((day) => !day.date) || new Set(days.map((day) => day.date)).size !== days.length) throw Object.assign(new Error("Each day needs a unique YYYY-MM-DD date"), { status: 400 });
    const library = withWears(await loadImported(), await loadSettings());
    const items = library.filter((item) => !item.unavailable);
    if (!items.some((item) => item.part === "upperbody") || !items.some((item) => item.part === "lowerbody")) {
      throw Object.assign(new Error("Plan needs at least one available top and one available bottom"), { status: 409 });
    }
    for (const day of days) {
      if (day.include && !items.some((item) => item.id === day.include)) {
        throw Object.assign(new Error(`${library.find((item) => item.id === day.include)?.name || "That piece"} is in the wash or was removed`), { status: 409 });
      }
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
    // A day that already has an outfit is a restyle: the current one comes first, then ones seen before it.
    for (const day of days) {
      const current = plans[day.date];
      if (current && !day.replace) day.avoid = [current.garmentIds, ...(current.tried || []).toReversed()].slice(0, 5);
    }
    const prompt = buildPlanPrompt({ items, days, history: historyFor(plans, days.map((day) => day.date)) });
    const report = (message) => days.forEach((day) => say(`plan:${day.date}`, message));
    let planned;
    try {
      ({ result: planned } = await untilApproved({
        attempts: PLAN_ATTEMPTS,
        make: (feedback) => ai.json({ prompt: feedback.length ? `${prompt}\n\nA previous attempt broke these rules; avoid them: ${feedback.join("; ")}.` : prompt, schema: planSchema, effort: setting("PLANNER_REASONING_EFFORT", "medium") })
          .then((result) => validatePlan(result, { items, days })),
        check: (planned) => {
          const fresh = planned.filter((plan) => !days.find((day) => day.date === plan.date)?.replace);
          return [...planIssues(plans, planned, items), ...swapIssues(days, planned, library), ...layerIssues(days, planned, items), ...includeIssues(days, planned),
            ...restyleIssues(days, planned, items), ...pairIssues(plans, fresh, items), ...rotationIssues(plans, fresh, items, days)];
        },
        onRetry: (problems, attempt) => report(`Restyling to fix ${problems.length === 1 ? "a clash" : `${problems.length} clashes`} (${attempt}/${PLAN_ATTEMPTS})…`),
      }));
    } catch (error) {
      // AI and validation failures are upstream problems the app should be able to show, not opaque 500s.
      throw Object.assign(error, { status: 502 });
    } finally {
      report(null);
    }
    // Repeats are soft rules, but a swap that changed more than the one piece would overwrite the user's outfit.
    if (swapIssues(days, planned, library).length) throw Object.assign(new Error("The stylist couldn't swap just that piece. Try again."), { status: 502 });
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
      for (const plan of planned) {
        // Earlier outfits for the day, so restyling again doesn't swing back to one of them.
        const old = fresh[plan.date];
        const tried = old ? [...(old.tried || []), old.garmentIds].slice(-5) : undefined;
        fresh[plan.date] = { ...plan, createdAt, ...(tried && { tried }) };
      }
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
    const valid = { name: (value) => typeof value === "string", part: (value) => PARTS.has(value), color: (value) => HEX_COLOR.test(value), secondaryColor: (value) => value === null || HEX_COLOR.test(value), description: (value) => typeof value === "string", text: (value) => typeof value === "string", backText: (value) => typeof value === "string", tags: Array.isArray, wears: (value) => value === null || (Number.isInteger(value) && value >= 1 && value <= 10) };
    const fields = Object.keys(valid).filter((key) => key in input && valid[key](input[key]));
    const record = await updateRecord(id, (record) => {
      const metadata = normalizeMetadata({ ...record, ...Object.fromEntries(fields.map((key) => [key, input[key]])) });
      Object.assign(record, { name: metadata.name, part: metadata.part, color: metadata.color, secondaryColor: metadata.secondaryColor, description: metadata.description, text: metadata.text, backText: metadata.backText, tags: metadata.tags, palette: [metadata.color, metadata.secondaryColor].filter(Boolean) });
      // null goes back to the category default.
      if (input.wears === null) delete record.wears;
      else if (fields.includes("wears")) record.wears = input.wears;
    });
    if (!record) throw Object.assign(new Error("Imported wardrobe item not found"), { status: 404 });
    return record;
  }

  // Makes a side's cutout again in the background like any other generation: from a new photo, else the photo kept
  // for that side, else its current cutout (older pieces kept no photo). A new photo is kept for the next redo.
  async function startCutout(id, side, input) {
    // input.photo is a pending upload resumed after a restart.
    const upload = input.photo || (input.imageDataUrl || input.imageBase64 ? await normalizeImage(decodeImage(input).data) : null);
    const sourceKey = side === "back" ? "backSourceImage" : "sourceImage";
    const imageKey = side === "back" ? "backImage" : "image";
    if (!upload && side === "back" && !(await loadImported()).find((record) => record.id === id)?.backImage) {
      throw Object.assign(new Error("Add a photo of the back first"), { status: 400 });
    }
    const direction = typeof input.direction === "string" ? input.direction.trim().slice(0, 600) : "";
    const lock = `${side}:${id}`;
    if (running.has(lock)) throw Object.assign(new Error(side === "back" ? "The back is already being cut out" : "The cutout is already being redone"), { status: 409 });
    // Reserved before any await so a second request can't start a duplicate generation.
    running.set(lock, null);
    // A new photo is saved first, so a restart can still finish this cutout.
    const pendingFile = upload ? `${id}-${side}-pending.png` : null;
    const record = await (async () => {
      if (pendingFile) await writeFile(libraryFile(pendingFile), upload);
      return updateRecord(id, (record) => { record[side] = { status: "processing", pending: pendingFile, direction: direction || null }; });
    })().catch((error) => { running.delete(lock); throw error; });
    if (!record) {
      running.delete(lock);
      throw Object.assign(new Error("Imported wardrobe item not found"), { status: 404 });
    }
    const key = `cutout:${id}`;
    const task = queued(key, async () => {
      try {
        const chromaKey = chooseChromaKey(record.color);
        const transparent = (await ai.status()).provider === "codex";
        const front = await normalizeImage(await readFile(libraryFile(record.image)));
        const current = side === "front" ? front : record.backImage ? await readFile(libraryFile(record.backImage)).then(normalizeImage) : null;
        const kept = !upload && record[sourceKey] ? await readFile(libraryFile(record[sourceKey])).then(normalizeImage).catch(() => null) : null;
        const photo = upload || kept || current;
        const fromCutout = photo === current;
        // The front's text describes the front only; the back photo speaks for itself.
        const metadata = side === "back" ? { ...record, name: `${record.name}, back view`, text: record.backText || "" } : record;
        let prompt = buildGarmentPrompt(metadata, chromaKey, { transparent });
        if (side === "back") prompt += "\n\nBack view: Image 1 shows the BACK of this garment. Reconstruct the garment as seen from behind, exactly as in Image 1. Image 2 is the existing front cutout of the same garment: keep color, material and proportions consistent with it, but do not copy front-only details such as buttons, plackets or chest graphics onto the back.";
        if (fromCutout) prompt += "\n\nImage 1 is this piece's current cutout. Recreate the same real garment as a cleaner cutout, and where its text or details contradict the description and text above, follow the description and text.";
        if (direction) prompt += `\nUser regeneration direction: ${direction}`;
        const images = side === "back"
          ? [{ data: photo, role: fromCutout ? "the current cutout of the back of the garment to recreate" : "the user's photo of the back of the garment; reproduce this exact back" }, { data: front, role: "the existing front cutout of the same garment, for consistency only" }]
          : [{ data: photo, role: fromCutout ? "the current cutout of the garment to recreate" : "the user's photo of the garment; reproduce this exact garment" }];
        const { result, problems } = await reviewed({
          attempts: CUTOUT_ATTEMPTS,
          make: async (feedback) => cleanCutout(await ai.editImage({ size: "1024x1024", quality: setting("OPENAI_IMAGE_QUALITY", "high"), transparent, prompt: withFeedback(prompt, feedback), images }), chromaKey),
          check: (cutout) => { say(key, "Checking the cutout…"); return reviewCutout(ai, { photo, cutout, metadata, side, referenceIsCutout: fromCutout }); },
          onRetry: retrying(key, CUTOUT_ATTEMPTS),
        });
        // A back adds colors, text and details the front alone didn't show.
        let details = null;
        if (side === "back") {
          say(key, "Updating its details…");
          details = await describeBothSides(ai, record, front, result).catch((error) => { console.warn(`Back details skipped: ${error.message}`); return null; });
        }
        const stamp = Date.now();
        const file = `${id}-${side === "back" ? "back" : "garment"}-${stamp}.png`;
        const sourceFile = upload ? `${id}-${side}-source-${stamp}.png` : null;
        await writeFile(path.join(libraryAssetDir, file), result);
        if (sourceFile) await rename(libraryFile(pendingFile), libraryFile(sourceFile));
        // removeBack clears the processing status; then this result is stale and is thrown away.
        let previous = [];
        let removed = false;
        const updated = await updateRecord(id, (record) => {
          if (record[side]?.status !== "processing") { removed = true; return; }
          previous = [record[imageKey], sourceFile && record[sourceKey]];
          record[imageKey] = `${LIBRARY_ASSET_ROOT}/${file}`;
          if (sourceFile) record[sourceKey] = `${LIBRARY_ASSET_ROOT}/${sourceFile}`;
          if (side === "front") record.thumbnail = record.image;
          if (details) {
            const metadata = normalizeMetadata({ ...record, ...details });
            Object.assign(record, { description: metadata.description, text: metadata.text, backText: metadata.backText, tags: metadata.tags, color: metadata.color, secondaryColor: metadata.secondaryColor, palette: [metadata.color, metadata.secondaryColor].filter(Boolean) });
          }
          record[side] = { status: "ready", warnings: problems, updatedAt: new Date().toISOString() };
        });
        if (!updated) removed = true;
        const stale = removed ? [file, sourceFile] : previous;
        await Promise.all(stale.filter(Boolean).map((name) => rm(libraryFile(name), { force: true })));
      } catch (error) {
        await updateRecord(id, (record) => { if (record[side]?.status === "processing") record[side] = { status: "failed", error: error.message, updatedAt: new Date().toISOString() }; });
        if (pendingFile) await rm(libraryFile(pendingFile), { force: true });
      } finally {
        say(key, null);
      }
    }).finally(() => running.delete(lock));
    running.set(lock, task);
    return record;
  }

  async function removeBack(id) {
    let previous = null;
    const record = await updateRecord(id, (record) => { previous = [record.backImage, record.backSourceImage]; record.backImage = null; record.backSourceImage = null; record.back = null; });
    if (!record) throw Object.assign(new Error("Imported wardrobe item not found"), { status: 404 });
    await Promise.all(previous.filter(Boolean).map((image) => rm(libraryFile(image), { force: true })));
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

  // A close-up of the user's head from the reference photo, where the face is often small; cached until the photo changes.
  // null when the AI can't find a face, and try-ons go on without it.
  async function readFaceReference(reference) {
    const modelPath = path.resolve(root, setting("WARDROBE_MODEL_REFERENCE", "data/model-reference.png"));
    const facePath = modelPath.replace(/(\.[a-z]+)?$/i, "-face.png");
    const [photo, cached] = await Promise.all([stat(modelPath), stat(facePath).catch(() => null)]);
    if (cached && cached.mtimeMs >= photo.mtimeMs) return readFile(facePath);
    try {
      const source = await sharp(reference).rotate().png().toBuffer();
      const { width, height } = await sharp(source).metadata();
      const box = await ai.json({ kind: "vision", schema: FACE_SCHEMA, images: [await sharp(source).resize(1024, 1024, { fit: "inside" }).png().toBuffer()],
        prompt: "Find the main person's head in this photo. Return a tight box around the whole head: hair, ears, glasses and chin. Use integers normalized to a 1000 by 1000 image: x and y are the top-left corner, then width and height." });
      // Room around the head for the neck and hair, kept square.
      const side = Math.max(box.width * width, box.height * height) / 1000 * 1.6;
      const left = Math.max(0, Math.round((box.x + box.width / 2) * width / 1000 - side / 2));
      const top = Math.max(0, Math.round((box.y + box.height / 2) * height / 1000 - side / 2));
      const size = Math.round(Math.min(side, width - left, height - top));
      if (size < 32) return null;
      const face = await sharp(source).extract({ left, top, width: size, height: size }).resize(768, 768, { kernel: "lanczos3" }).png().toBuffer();
      await writeFile(facePath, face);
      return face;
    } catch (error) {
      console.warn(`Couldn't crop the face from the reference photo: ${error.message}`);
      return null;
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
      const status = `tryon:${date}`;
      const task = queued(status, async () => {
        try {
          const face = await readFaceReference(reference);
          const images = [{ data: reference, role: "identity reference: the exact person to dress" }, ...(face ? [{ data: face, role: "identity close-up: the same person's face and hair" }] : [])];
          const cutouts = await Promise.all(tryOnReferences(garments).map(({ image }) => readFile(libraryFile(image))));
          const sheet = images.length + cutouts.length > IMAGE_INPUT_LIMIT;
          if (sheet) images.push({ data: await garmentSheet(cutouts), role: "reference sheet of every garment to wear, numbered" });
          else garments.forEach((item, index) => images.push({ data: cutouts[index], role: `exact ${PART_NAMES[item.part] || "garment"} to wear: ${item.name} (transparent cutout)` }));
          const inputs = await Promise.all(images.map(async (image) => ({ ...image, data: await normalizeImage(image.data) })));
          const worn = await Promise.all(garments.map(async (item) => ({ name: item.name, text: item.text, image: await readFile(libraryFile(item.image)) })));
          const { result: bytes, problems } = await reviewed({
            attempts: TRY_ON_ATTEMPTS,
            make: (feedback) => ai.editImage({ size: "1024x1536", quality: setting("OPENAI_IMAGE_QUALITY", "high"), images: inputs, prompt: withFeedback(buildTryOnPrompt(plan, garments, { face: Boolean(face), sheet }), feedback) }),
            check: (image) => { say(status, "Checking the photo…"); return reviewWorn(ai, { person: reference, face, image, garments: worn }); },
            onRetry: retrying(status, TRY_ON_ATTEMPTS),
          });
          await mkdir(outfitDir, { recursive: true });
          const file = `${date}-${Date.now()}.png`;
          await writeFile(path.join(outfitDir, file), bytes);
          await saveTryOn(date, key, { status: "ready", image: `/api/import/outfits/${file}`, warnings: problems });
        } catch (error) {
          await saveTryOn(date, key, { status: "failed", error: error.message });
        } finally {
          say(status, null);
        }
      }).finally(() => running.delete(lock));
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
    const backs = (await loadImported()).flatMap((record) => ["back", "front"]
      .filter((side) => record[side] && record[side].status !== "processing" && Date.parse(record[side].updatedAt) >= since)
      .map((side) => ({ name: record.name, status: record[side].status, side })));
    return { busy: running.size > 0, reviews, tryOns, backs, cursor };
  }

  // One review job per detected piece, starting at its crop.
  async function createJobs(photo, detected) {
    const jobs = [];
    for (const { metadata, crop } of detected) {
      const id = randomUUID();
      const dir = path.join(jobsDir, id);
      await mkdir(dir, { recursive: true });
      const originalFile = "original.png";
      const cropFile = "crop.png";
      await writeFile(path.join(dir, originalFile), photo);
      await writeFile(path.join(dir, cropFile), crop);
      const now = new Date().toISOString();
      const cropStage = { ...stageState(), status: "review", assetUrl: `${ASSET_ROOT}/${id}/${cropFile}`, updatedAt: now };
      const job = { id, status: "active", metadata, stages: { crop: cropStage, garment: stageState(), modeled: stageState() }, createdAt: now, updatedAt: now, internal: { originalFile, cropFile, originalMime: "image/png" } };
      job.originalAssetUrl = `${ASSET_ROOT}/${id}/${originalFile}`;
      await saveJob(job);
      jobs.push(job);
    }
    return jobs;
  }

  // Finds clothes in a photo in the background, so a phone that sleeps or loses Wi-Fi mid-way loses nothing.
  // A retried upload with the same id joins the detection already there instead of starting a second one.
  async function startDetection(photo, clientId) {
    const id = clientId || randomUUID();
    if (detections.has(id)) return detections.get(id);
    const file = path.join(detectionsDir, `${id}.png`);
    await writeFile(file, photo);
    return runDetection(id, file, photo);
  }

  function runDetection(id, file, photo) {
    const detection = { id, status: "working", message: null, found: 0, error: null, updatedAt: Date.now() };
    detections.set(id, detection);
    const report = (message) => Object.assign(detection, { message, updatedAt: Date.now() });
    const task = detectQueue(async () => {
      report(null);
      try {
        const jobs = await createJobs(photo, await detectClothes(ai, photo, report, reviewed));
        Object.assign(detection, { status: "done", found: jobs.length, message: null, updatedAt: Date.now() });
      } catch (error) {
        Object.assign(detection, { status: "failed", error: error.message, message: null, updatedAt: Date.now() });
      } finally {
        await rm(file, { force: true });
      }
    }, (ahead) => report(ahead ? `Waiting in line, ${ahead} ahead…` : "Up next…"));
    running.set(`detect:${id}`, task);
    task.finally(() => running.delete(`detect:${id}`));
    return detection;
  }

  // Finished detections that found pieces disappear after a minute; failures and empty photos wait to be dismissed.
  function detectionList() {
    for (const [id, detection] of detections) {
      if (detection.status === "done" && detection.found > 0 && Date.now() - detection.updatedAt > 60 * 1000) detections.delete(id);
    }
    return [...detections.values()];
  }

  // Styles days in the background; the app polls the list and the plans.
  function startStyling(input) {
    const dates = Array.isArray(input.days) ? input.days.map((day) => day?.date) : [];
    if (!dates.length || dates.some((date) => typeof date !== "string" || !DATE.test(date))) throw Object.assign(new Error("Each day needs a YYYY-MM-DD date"), { status: 400 });
    if (dates.some((date) => styling.get(date)?.status === "working")) throw Object.assign(new Error("That day is already being styled"), { status: 409 });
    for (const date of dates) styling.set(date, { date, status: "working", error: null });
    const key = `plan:${dates.join(",")}`;
    const task = planOutfits(input).then(
      () => dates.forEach((date) => styling.delete(date)),
      (error) => dates.forEach((date) => styling.set(date, { date, status: "failed", error: error.message })),
    );
    running.set(key, task);
    task.finally(() => running.delete(key));
    return [...styling.values()];
  }

  async function sendImage(res, file, width, cacheControl) {
    const info = await stat(file);
    res.setHeader("Cache-Control", cacheControl);
    if (!width) {
      res.setHeader("Content-Type", file.endsWith(".svg") ? "image/svg+xml" : "image/png");
      return res.end(await readFile(file));
    }
    const cacheKey = `${file}:${width}:${info.mtimeMs}`;
    let bytes = previews.get(cacheKey);
    if (!bytes) {
      bytes = await sharp(file).resize({ width, height: width, fit: "inside", withoutEnlargement: true }).webp({ quality: 82 }).toBuffer();
      previews.set(cacheKey, bytes);
      if (previews.size > 400) previews.delete(previews.keys().next().value);
    }
    res.setHeader("Content-Type", "image/webp");
    return res.end(bytes);
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
    // The photo is kept so the cutout can be redone later from the real garment.
    const sourceName = `${id}-source.png`;
    await copyFile(path.join(jobsDir, job.id, job.internal.cropFile || job.internal.originalFile), path.join(libraryAssetDir, sourceName));
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
      sourceImage: `${LIBRARY_ASSET_ROOT}/${sourceName}`,
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
    const status = `job:${job.id}`;
    const task = queued(status, async () => {
      const current = await jobLock(job.id, async () => {
        const current = await loadJob(job.id);
        // Discarded while it waited in line.
        if (!current) return null;
        const stage = current.stages[stageName];
        stage.status = "processing"; stage.decision = null; stage.error = null; stage.warnings = null; stage.attempts += 1; stage.updatedAt = new Date().toISOString();
        await saveJob(current);
        return current;
      });
      if (!current) return;
      const stage = current.stages[stageName];
      let failedAssetUrl = null;
      let chromaKeyUsed = null;
      let warnings = [];
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
          const inputs = await Promise.all(images.map(async (image) => ({ ...image, data: await normalizeImage(image.data) })));
          const prompt = current.stages.garment.prompt ? `${basePrompt}\nUser regeneration direction: ${current.stages.garment.prompt}` : basePrompt;
          ({ result: bytes, problems: warnings } = await reviewed({
            attempts: CUTOUT_ATTEMPTS,
            make: async (feedback, attempt) => {
              if (!(await loadJob(current.id))) throw Object.assign(new Error("Discarded"), { cancelled: true });
              const raw = await ai.editImage({ model: setting("OPENAI_GARMENT_MODEL"), quality: setting("OPENAI_IMAGE_QUALITY", "high"), size: "1024x1024", transparent, images: inputs, prompt: withFeedback(prompt, feedback) });
              const rawName = `${stageName}-${stage.attempts}-${attempt}-source.png`;
              await writeFile(path.join(dir, rawName), raw);
              failedAssetUrl = `${ASSET_ROOT}/${current.id}/${rawName}`;
              return cleanCutout(raw, chromaKeyUsed);
            },
            check: (cutout) => { say(status, "Checking the cutout…"); return reviewCutout(ai, { photo: selected, cutout, metadata: current.metadata }); },
            onRetry: retrying(status, CUTOUT_ATTEMPTS),
          }));
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
          const inputs = await Promise.all([
            { data: modelData, role: "identity reference: the person to photograph" },
            { data: garment.data, role: "the exact garment to dress them in (transparent cutout)" },
            { data: selected, role: "the selected original photo of the garment, for fidelity context only" },
          ].map(async (image) => ({ ...image, data: await normalizeImage(image.data) })));
          const prompt = current.stages.modeled.prompt ? `${basePrompt}\nUser regeneration direction: ${current.stages.modeled.prompt}` : basePrompt;
          ({ result: bytes, problems: warnings } = await reviewed({
            attempts: TRY_ON_ATTEMPTS,
            make: (feedback) => ai.editImage({ model: setting("OPENAI_MODELED_MODEL"), quality: setting("OPENAI_IMAGE_QUALITY", "high"), size: "1536x1024", images: inputs, prompt: withFeedback(prompt, feedback) }),
            check: (image) => { say(status, "Checking the photo…"); return reviewWorn(ai, { person: modelData, image, garments: [{ name: current.metadata.name, text: current.metadata.text, image: garment.data }] }); },
            onRetry: retrying(status, TRY_ON_ATTEMPTS),
          }));
        }
        await writeFile(output, bytes);
        await jobLock(current.id, async () => {
        const fresh = await loadJob(current.id);
        if (!fresh) return;
        fresh.stages[stageName].status = "review";
        fresh.stages[stageName].assetUrl = `${ASSET_ROOT}/${fresh.id}/${path.basename(output)}`;
        fresh.stages[stageName].failedAssetUrl = null;
        fresh.stages[stageName].cleanupPreviewUrl = null;
        fresh.stages[stageName].cleanupDiagnostics = null;
        fresh.stages[stageName].warnings = warnings;
        if (chromaKeyUsed) fresh.stages[stageName].chromaKey = chromaKeyUsed;
        fresh.stages[stageName].updatedAt = new Date().toISOString();
        await saveJob(fresh);
        });
      } catch (error) {
        await jobLock(current.id, async () => {
          const fresh = await loadJob(current.id);
          if (!fresh) return;
          fresh.stages[stageName].status = "failed"; fresh.stages[stageName].error = error.message; fresh.stages[stageName].updatedAt = new Date().toISOString();
          if (typeof failedAssetUrl === "string") fresh.stages[stageName].failedAssetUrl = failedAssetUrl;
          if (chromaKeyUsed) fresh.stages[stageName].chromaKey = chromaKeyUsed;
          await saveJob(fresh);
        });
      } finally {
        say(status, null);
      }
    }).finally(() => running.delete(lock));
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
      if (url.pathname === "/api/import/version" && req.method === "GET") {
        return json(res, 200, await versionInfo());
      }
      if (url.pathname === "/api/import/settings" && req.method === "GET") {
        return json(res, 200, await loadSettings());
      }
      if (url.pathname === "/api/import/settings" && req.method === "PATCH") {
        return json(res, 200, await saveSettings(await body(req)));
      }
      if (url.pathname === "/api/import/model-reference" && req.method === "POST") {
        return json(res, 200, await saveModelReference(await body(req)));
      }
      if (url.pathname === "/api/import/model-reference" && req.method === "GET") {
        return sendImage(res, path.resolve(root, setting("WARDROBE_MODEL_REFERENCE", "data/model-reference.png")), previewWidth(url), "no-store");
      }
      const wardrobeDeleteMatch = url.pathname.match(/^\/api\/import\/wardrobe\/(import-[a-f0-9-]{36})$/i);
      if (wardrobeDeleteMatch && req.method === "PATCH") {
        return json(res, 200, await editRecord(wardrobeDeleteMatch[1], await body(req)));
      }
      const backMatch = url.pathname.match(/^\/api\/import\/wardrobe\/(import-[a-f0-9-]{36})\/back$/i);
      if (backMatch && req.method === "POST") {
        return json(res, 202, await startCutout(backMatch[1], "back", await body(req)));
      }
      const frontMatch = url.pathname.match(/^\/api\/import\/wardrobe\/(import-[a-f0-9-]{36})\/front$/i);
      if (frontMatch && req.method === "POST") {
        return json(res, 202, await startCutout(frontMatch[1], "front", await body(req)));
      }
      if (url.pathname === "/api/import/progress" && req.method === "GET") {
        return json(res, 200, Object.fromEntries(progress));
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
          ...[removed.image, removed.backImage, removed.sourceImage, removed.backSourceImage].filter(Boolean).map((image) => rm(libraryFile(image), { force: true })),
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
        const input = await body(req);
        if (input.background === true) return json(res, 202, startStyling(input));
        return json(res, 200, await planOutfits(input));
      }
      if (url.pathname === "/api/import/plans/styling" && req.method === "GET") {
        return json(res, 200, [...styling.values()]);
      }
      const stylingMatch = url.pathname.match(/^\/api\/import\/plans\/styling\/(\d{4}-\d{2}-\d{2})$/);
      if (stylingMatch && req.method === "DELETE") {
        if (styling.get(stylingMatch[1])?.status === "failed") styling.delete(stylingMatch[1]);
        return json(res, 200, [...styling.values()]);
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
        return sendImage(res, path.join(outfitDir, path.basename(outfitAssetMatch[1])), previewWidth(url), "public, max-age=31536000, immutable");
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
        return sendImage(res, path.join(libraryAssetDir, path.basename(libraryAssetMatch[1])), previewWidth(url), "public, max-age=31536000, immutable");
      }
      const assetMatch = url.pathname.match(/^\/api\/import\/assets\/([a-f0-9-]{36})\/([\w.-]+)$/i);
      if (assetMatch && req.method === "GET") {
        return sendImage(res, path.join(jobsDir, assetMatch[1], path.basename(assetMatch[2])), previewWidth(url), "no-store");
      }
      if (url.pathname === API_ROOT && req.method === "POST") {
        const setup = await setupStatus();
        if (!setup.ready) {
          return json(res, 503, { error: "Setup required: run `codex login` (ChatGPT plan) or add OPENAI_API_KEY to .env, then restart the app." });
        }
        const input = await body(req);
        const photo = await normalizeImage(decodeImage(input).data);
        const clientId = typeof input.clientId === "string" && /^[\w-]{1,64}$/.test(input.clientId) ? input.clientId : null;
        if (input.background === true) return json(res, 202, await startDetection(photo, clientId));
        // The web app still waits for the result in the request.
        const jobs = await createJobs(photo, await detectClothes(ai, photo, () => {}, reviewed));
        return json(res, 202, { jobs: jobs.map(publicJob), noClothingDetected: jobs.length === 0 });
      }
      if (url.pathname === "/api/import/detections" && req.method === "GET") {
        return json(res, 200, detectionList());
      }
      const detectionMatch = url.pathname.match(/^\/api\/import\/detections\/([\w-]{1,64})$/);
      if (detectionMatch && req.method === "DELETE") {
        if (detections.get(detectionMatch[1])?.status !== "working") detections.delete(detectionMatch[1]);
        return json(res, 200, detectionList());
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
      const action = match[2] || "";
      const stageMatch = action.match(/^stages\/(crop|garment|modeled)\/(approve|reject|regenerate)$/);
      const input = ["POST", "PATCH", "PUT"].includes(req.method) ? await body(req) : {};
      // Every change to a job runs under its lock, so a double tap or a generation finishing at the same moment waits its turn.
      const [statusCode, value] = await jobLock(match[1], async () => {
        const job = await loadJob(match[1]);
        if (!job) {
          // Approving or discarding a piece that already finished, e.g. a request retried after the phone lost Wi-Fi, is not an error.
          if (stageMatch && stageMatch[2] !== "regenerate") return [200, { id: match[1], gone: true }];
          if (!action && req.method === "DELETE") return [200, { deleted: true, id: match[1] }];
          throw Object.assign(new Error("Job not found"), { status: 404 });
        }
        if (!action && req.method === "GET") return [200, publicJob(job)];
        if (!action && req.method === "DELETE") {
          await rm(path.join(jobsDir, job.id), { recursive: true, force: true });
          return [200, { deleted: true, id: job.id }];
        }
        if (action === "metadata" && (req.method === "PATCH" || req.method === "PUT")) {
          if (!input.metadata || typeof input.metadata !== "object" || Array.isArray(input.metadata)) throw Object.assign(new Error("metadata must be an object"), { status: 400 });
          job.metadata = normalizeMetadata({ ...job.metadata, ...input.metadata }); await saveJob(job);
          return [200, publicJob(job)];
        }
        const cleanupAction = action.match(/^stages\/garment\/(cleanup-preview|cleanup-accept)$/);
        if (cleanupAction && req.method === "POST") {
          const stage = job.stages.garment;
          if (stage.status !== "failed" || !stage.failedAssetUrl) {
            throw Object.assign(new Error("No failed garment source is available for cleanup"), { status: 409 });
          }
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
          return [200, publicJob(job)];
        }
        if (stageMatch && req.method === "POST") {
          const [, stageName, decision] = stageMatch;
          if (!STAGES.has(stageName)) throw Object.assign(new Error("Invalid stage"), { status: 400 });
          if (decision === "regenerate") {
            if (stageName === "crop") throw Object.assign(new Error("Upload the image again to create new crops"), { status: 400 });
            if (running.has(`${job.id}:${stageName}`)) return [202, publicJob(job)];
            job.stages[stageName].prompt = typeof input.prompt === "string" ? input.prompt.trim().slice(0, 1200) || null : null;
            job.stages[stageName].status = "queued";
            job.stages[stageName].decision = null;
            await saveJob(job);
            void generate(job, stageName);
            return [202, publicJob(job)];
          }
          if (job.stages[stageName].decision === (decision === "approve" ? "approved" : "rejected")) return [200, publicJob(job)];
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
          return [200, response];
        }
        return [404, { error: "Not found" }];
      });
      return json(res, statusCode, value);
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
      settingsFile = path.join(dataDir, "settings.json");
      detectionsDir = path.join(dataDir, "detections");
      await mkdir(detectionsDir, { recursive: true });
      outfitDir = path.join(dataDir, "outfit-images");
      // Back cutouts cannot survive a restart either.
      const library = await loadImported().catch(() => []);
      // Cutouts and try-ons that were running when the server stopped are resumed once everything below is set up.
      const interruptedCutouts = library.flatMap((record) => ["back", "front"].filter((side) => record[side]?.status === "processing").map((side) => [record, side]));
      const interruptedTryOns = Object.values(await loadPlans()).filter((plan) => plan.tryOn?.status === "processing");
      libraryAssetDir = path.join(dataDir, "imported");
      await mkdir(jobsDir, { recursive: true });
      await mkdir(libraryAssetDir, { recursive: true });
      for (const [record, side] of interruptedCutouts) {
        if (running.has(`${side}:${record.id}`)) continue;
        const pending = record[side].pending ? await readFile(libraryFile(record[side].pending)).catch(() => null) : null;
        startCutout(record.id, side, { photo: pending, direction: record[side].direction || "" }).catch((error) => updateRecord(record.id, (fresh) => {
          fresh[side] = { status: "failed", error: `Interrupted: ${error.message}`, updatedAt: new Date().toISOString() };
        }));
      }
      for (const plan of interruptedTryOns) {
        startTryOn(plan.date).catch((error) => saveTryOn(plan.date, plan.garmentIds.join("+"), { status: "failed", error: error.message }));
      }
      // Photos that were still being searched when the server stopped.
      for (const name of await readdir(detectionsDir).catch(() => [])) {
        const match = name.match(/^([\w-]{1,64})\.png$/);
        if (match && !detections.has(match[1])) runDetection(match[1], path.join(detectionsDir, name), await readFile(path.join(detectionsDir, name)));
      }
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
        if (["processing", "queued"].includes(job.stages.garment.status) && !running.has(`${job.id}:garment`)) {
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
    configureServer(server) {
      // Longer than iOS keeps idle connections, so the server never closes one the phone is about to reuse
      // (that race shows up in the app as "The network connection was lost").
      if (server.httpServer) Object.assign(server.httpServer, { keepAliveTimeout: 120 * 1000, headersTimeout: 125 * 1000 });
      server.middlewares.use(handler);
    },
    configurePreviewServer(server) { server.middlewares.use(handler); },
  };
}
