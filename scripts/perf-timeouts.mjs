export class PerfTimeoutError extends Error {
  constructor(label, timeoutMs) {
    super(`${label} 超时（${timeoutMs}ms）`);
    this.name = 'PerfTimeoutError';
    this.label = label;
    this.timeoutMs = timeoutMs;
  }
}

export async function withHardTimeout(task, timeoutMs, label) {
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    throw new RangeError(`timeoutMs 必须是正数：${String(timeoutMs)}`);
  }

  let timer;
  const operation = Promise.resolve().then(task);
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new PerfTimeoutError(label, timeoutMs)), timeoutMs);
  });
  try {
    return await Promise.race([operation, timeout]);
  } finally {
    if (timer !== undefined) {
      clearTimeout(timer);
    }
  }
}

export function evaluateWithTimeout(page, pageFunction, arg, timeoutMs, label) {
  return withHardTimeout(
    () => page.evaluate(pageFunction, arg),
    timeoutMs,
    label,
  );
}
