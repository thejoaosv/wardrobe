import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import sharp from "sharp";
import { buildGarmentPrompt, chooseChromaKey, processChromaBackground, tryOnLock, wardrobeImportApi } from "./import-job-api.mjs";
import { oversized } from "./responsive-image-api.mjs";

// A square garment in the middle of a keyed backdrop; paint(x, y) returns the garment's color at that pixel, or null for backdrop.
async function keyed(key, paint, size = 256) {
  const target = [1, 3, 5].map((offset) => Number.parseInt(key.slice(offset, offset + 2), 16));
  const raw = Buffer.alloc(size * size * 3);
  for (let pixel = 0; pixel < size * size; pixel += 1) raw.set(paint(pixel % size, Math.floor(pixel / size)) || target, pixel * 3);
  return sharp(raw, { raw: { width: size, height: size, channels: 3 } }).png().toBuffer();
}
const inside = (x, y, from, to) => x >= from && x < to && y >= from && y < to;
const center = async (bytes) => {
  const { data, info } = await sharp(bytes).raw().toBuffer({ resolveWithObject: true });
  const index = (Math.floor(info.height / 2) * info.width + Math.floor(info.width / 2)) * 4;
  return [...data.subarray(index, index + 4)];
};

test("chroma cleanup keeps the garment's own colors and only cleans the backdrop and its edge", async () => {
  // Navy leans toward a magenta key's channels but is the garment, not spill.
  const navy = await processChromaBackground(await keyed("#ff00ff", (x, y) => (inside(x, y, 64, 192) ? [20, 30, 80] : null)), "#ff00ff");
  assert.deepEqual(await center(navy.bytes), [20, 30, 80, 255]);
  // A green logo inside a white tee on a green key stays opaque and green.
  const logo = await processChromaBackground(await keyed("#00ff00", (x, y) => (inside(x, y, 112, 144) ? [30, 160, 60] : inside(x, y, 64, 192) ? [240, 240, 240] : null)), "#00ff00");
  assert.deepEqual(await center(logo.bytes), [30, 160, 60, 255]);
  // A shaded floor beyond the tolerance and a greenish fringe around the garment are both backdrop.
  const shaded = await processChromaBackground(await keyed("#00ff00", (x, y) => (inside(x, y, 64, 192) ? [240, 240, 240] : inside(x, y, 62, 194) ? [150, 230, 150] : y > 210 ? [25, 185, 25] : null)), "#00ff00");
  const { data } = await sharp(shaded.bytes).raw().toBuffer({ resolveWithObject: true });
  let green = 0;
  for (let index = 0; index < data.length; index += 4) if (data[index + 3] > 8 && data[index + 1] > data[index] + 10) green += 1;
  assert.equal(green, 0);
  assert.equal(shaded.verification.contaminatedPixels, 0);
});

test("the chroma key avoids the secondary color too", () => {
  assert.equal(chooseChromaKey("#ffffff"), "#00ff00");
  assert.notEqual(chooseChromaKey("#ffffff", "#1ea03c"), "#00ff00");
  assert.equal(chooseChromaKey("not a color"), chooseChromaKey("#808080"));
});

test("a restyled day's try-on doesn't share the stale outfit's lock", () => {
  assert.notEqual(tryOnLock("2026-11-18", ["tee", "jeans"]), tryOnLock("2026-11-18", ["shirt", "jeans"]));
  assert.equal(tryOnLock("2026-11-18", ["tee", "jeans"]), tryOnLock("2026-11-18", ["tee", "jeans"]));
});

test("the back cutout prompt describes its own inputs", () => {
  const back = buildGarmentPrompt({ name: "Hoodie" }, "#00ff00", { side: "back" });
  assert.match(back, /BACK of this garment/);
  assert.match(back, /Image 2 is the existing front cutout/);
  assert.match(back, /back view ecommerce/);
  assert.doesNotMatch(back, /full selected photo|front-facing/);
  const front = buildGarmentPrompt({ name: "Tee" });
  assert.match(front, /front-facing/);
  assert.match(front, /Image 2, when present, is the full selected photo/);
  assert.match(buildGarmentPrompt({ name: "Tee" }, "#00ff00", { fromCutout: true }), /current cutout/);
});

test("the API refuses foreign origins and changes that aren't JSON", async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "wardrobe-test-"));
  try {
    const plugin = wardrobeImportApi({ env: { WARDROBE_DATA_DIR: dir } });
    await plugin.configResolved({ root: dir });
    let handler;
    plugin.configureServer({ middlewares: { use: (fn) => { handler = fn; } } });
    const call = (method, url, headers = {}) => new Promise((resolve) => {
      const res = { statusCode: 200, setHeader() {}, on() {}, end: (body) => resolve({ status: res.statusCode, body: body && JSON.parse(body) }) };
      handler({ method, url, headers: { host: "localhost:5173", ...headers }, [Symbol.asyncIterator]: async function* () {} }, res, () => resolve({ status: "next" }));
    });
    assert.equal((await call("GET", "/api/import/settings", { origin: "https://evil.example" })).status, 403);
    assert.equal((await call("GET", "/api/import/settings", { origin: "http://localhost:5173" })).status, 200);
    assert.equal((await call("POST", "/api/import/plans/2026-11-18/try-on", { origin: "null" })).status, 403);
    assert.equal((await call("POST", "/api/import/plans/2026-11-18/try-on")).status, 415);
    assert.equal((await call("DELETE", "/api/import/plans/2026-11-18", { "content-type": "text/plain" })).status, 415);
    // JSON gets through to the route, which finds no outfit planned.
    assert.equal((await call("POST", "/api/import/plans/2026-11-18/try-on", { "content-type": "application/json; charset=utf-8" })).status, 404);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("ipx refuses sizes far beyond any screen", () => {
  assert.equal(oversized("/w_640/icon.svg"), false);
  assert.equal(oversized("/_/icon-9999.svg"), false);
  assert.equal(oversized("/s_8000x8000/icon.svg"), true);
});
