// Runs at most `concurrency` tasks at once; the rest wait in order and hear how many are ahead of them.
export function createQueue(concurrency) {
  const waiting = [];
  let active = 0;
  const next = () => {
    while (active < concurrency && waiting.length) {
      const entry = waiting.shift();
      active += 1;
      entry.start();
    }
    waiting.forEach((entry, ahead) => entry.onWait?.(ahead));
  };
  return (task, onWait) => new Promise((resolve, reject) => {
    waiting.push({
      onWait,
      start: () => Promise.resolve().then(task).then(resolve, reject).finally(() => { active -= 1; next(); }),
    });
    next();
  });
}

// Serializes tasks that share a key; different keys run freely. Used for one job's read-modify-write cycles.
export function createKeyedLock() {
  const tails = new Map();
  return (key, task) => {
    const run = (tails.get(key) || Promise.resolve()).then(task);
    const tail = run.catch(() => {});
    tails.set(key, tail);
    tail.then(() => { if (tails.get(key) === tail) tails.delete(key); });
    return run;
  };
}
