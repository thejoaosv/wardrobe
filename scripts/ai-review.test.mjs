import assert from "node:assert/strict";
import test from "node:test";
import sharp from "sharp";
import { UNCHECKED, backoff, isTransient, missingWords, reviewCutout, untilApproved, withFeedback } from "./ai-review.mjs";

test("untilApproved retries with the reviewer's problems as feedback", async () => {
  const seen = [];
  const retries = [];
  const { result, problems } = await untilApproved({
    attempts: 3,
    make: async (feedback, attempt) => { seen.push(feedback); return attempt; },
    check: async (attempt) => (attempt < 2 ? ["text reads RUTGERS"] : []),
    onRetry: (problems, attempt) => retries.push(attempt),
  });
  assert.equal(result, 2);
  assert.deepEqual(problems, []);
  assert.deepEqual(seen, [[], ["text reads RUTGERS"]]);
  assert.deepEqual(retries, [2]);
});

test("untilApproved keeps the last result when every attempt has problems, and survives a failed attempt", async () => {
  let calls = 0;
  const kept = await untilApproved({
    attempts: 3,
    make: async (_, attempt) => { calls += 1; if (attempt === 3) throw new Error("no image"); return attempt; },
    check: async () => ["still wrong"],
  });
  assert.equal(calls, 3);
  assert.deepEqual(kept, { result: 2, problems: ["still wrong"] });
  await assert.rejects(untilApproved({ attempts: 2, make: async () => { throw new Error("down"); }, check: async () => [] }), /down/);
});

test("missingWords catches a swapped word but not spacing or case", () => {
  const text = 'front: large arched "ROTATION", small "LX" centered below';
  assert.deepEqual(missingWords(text, "RUTGERS L X"), ["ROTATION"]);
  assert.deepEqual(missingWords(text, "Rotation\nl.x"), []);
  assert.deepEqual(missingWords("no quotes here", "anything"), []);
  assert.match(withFeedback("Base", ["Fix the text"]), /Base\n\nA reviewer rejected[\s\S]*- Fix the text/);
  assert.equal(withFeedback("Base", []), "Base");
});

test("parseChangelog reads versions, dates and notes newest first", async () => {
  const { parseChangelog } = await import("./changelog.mjs");
  const entries = parseChangelog("# Changelog\n\nIntro\n\n## 1.1.0 — 2026-11-17\n- Two\n- Three\n\n## 1.0.0\n- One\n");
  assert.deepEqual(entries, [{ version: "1.1.0", date: "2026-11-17", notes: ["Two", "Three"] }, { version: "1.0.0", date: null, notes: ["One"] }]);
});

test("untilApproved stops at once when an attempt is cancelled", async () => {
  let calls = 0;
  await assert.rejects(untilApproved({ attempts: 3, make: async () => { calls += 1; throw Object.assign(new Error("Discarded"), { cancelled: true }); }, check: async () => [] }), /Discarded/);
  assert.equal(calls, 1);
});

test("untilApproved waits out a busy service without telling the model, and stops on a refusal", async () => {
  const waits = [];
  const seen = [];
  const notes = [];
  let calls = 0;
  const { result } = await untilApproved({
    attempts: 3,
    wait: async (ms) => { waits.push(ms); },
    make: async (feedback) => { seen.push(feedback); calls += 1; if (calls === 1) throw Object.assign(new Error("Rate limit reached"), { status: 429, retryAfter: 7 }); return "image"; },
    check: async () => [],
    onRetry: (problems) => notes.push(problems[0]),
  });
  assert.equal(result, "image");
  assert.deepEqual(waits, [7000]);
  assert.deepEqual(seen, [[], []]);
  assert.match(notes[0], /busy/);
  assert.equal(backoff(new Error("x"), 1), 4000);
  assert.ok(isTransient(Object.assign(new Error("timed out"), { transient: true })) && isTransient({ status: 503 }) && !isTransient({ status: 400 }));
  // A moderation refusal fails the same way every time: no second attempt, but an earlier result is kept.
  let tries = 0;
  const refusal = () => Object.assign(new Error("Rejected by the safety system"), { status: 400 });
  await assert.rejects(untilApproved({ attempts: 3, wait: async () => {}, make: async () => { tries += 1; throw refusal(); }, check: async () => [] }), /safety/);
  assert.equal(tries, 1);
  const kept = await untilApproved({ attempts: 3, wait: async () => {}, make: async (_, attempt) => { if (attempt === 2) throw refusal(); return attempt; }, check: async () => ["off"] });
  assert.deepEqual(kept, { result: 1, problems: ["off"] });
});

test("an unavailable reviewer marks the result unchecked instead of paying for another attempt", async () => {
  const image = await sharp({ create: { width: 32, height: 32, channels: 3, background: "#336699" } }).png().toBuffer();
  const ai = { json: async () => { throw new Error("down"); } };
  const problems = await reviewCutout(ai, { photo: image, cutout: image });
  assert.deepEqual([...problems], [UNCHECKED]);
  let attempts = 0;
  const kept = await untilApproved({ attempts: 3, make: async () => { attempts += 1; return image; }, check: (cutout) => reviewCutout(ai, { photo: image, cutout }) });
  assert.equal(attempts, 1);
  assert.deepEqual([...kept.problems], [UNCHECKED]);
});
