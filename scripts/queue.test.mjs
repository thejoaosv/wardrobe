import assert from "node:assert/strict";
import test from "node:test";
import { createKeyedLock, createQueue } from "./queue.mjs";

const tick = () => new Promise((resolve) => setTimeout(resolve, 5));

test("createQueue runs a few at a time, in order, and reports places in line", async () => {
  const queue = createQueue(2);
  let running = 0;
  let peak = 0;
  const order = [];
  const places = [];
  const job = (name) => async () => { running += 1; peak = Math.max(peak, running); order.push(name); await tick(); running -= 1; return name; };
  const results = await Promise.all(["a", "b", "c", "d"].map((name) => queue(job(name), (ahead) => places.push(`${name}:${ahead}`))));
  assert.deepEqual(results, ["a", "b", "c", "d"]);
  assert.deepEqual(order, ["a", "b", "c", "d"]);
  assert.equal(peak, 2);
  assert.ok(places.includes("c:0") && places.includes("d:1") && places.includes("d:0"));
  // A failing task frees its slot and rejects only its own caller.
  await assert.rejects(queue(async () => { throw new Error("boom"); }), /boom/);
  assert.equal(await queue(async () => "after"), "after");
});

test("createKeyedLock serializes one key but not others, and survives failures", async () => {
  const lock = createKeyedLock();
  const log = [];
  const step = (name) => async () => { log.push(`${name}+`); await tick(); log.push(`${name}-`); };
  await Promise.all([lock("x", step("x1")), lock("x", step("x2")), lock("y", step("y1"))]);
  assert.deepEqual(log.filter((entry) => entry.startsWith("x")), ["x1+", "x1-", "x2+", "x2-"]);
  assert.ok(log.indexOf("y1+") < log.indexOf("x1-"));
  await assert.rejects(lock("x", async () => { throw new Error("bad"); }), /bad/);
  assert.equal(await lock("x", async () => "ok"), "ok");
});
