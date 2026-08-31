import { SeededRandom } from './seeded-random';

export type ReplayToken = {
  readonly seed: string;
  readonly iteration: number;
};

export type ReplayableProperty = (random: SeededRandom, iteration: number) => void;

export function makeReplayToken(seed: bigint | number, iteration: number): ReplayToken {
  const random = new SeededRandom(seed);
  if (!Number.isSafeInteger(iteration) || iteration < 0) {
    throw new RangeError('ReplayToken iteration 必须是非负安全整数。');
  }
  return { seed: random.seed.toString(), iteration };
}

export function serializeReplayToken(token: ReplayToken): string {
  validateReplayToken(token);
  return JSON.stringify(token);
}

export function parseReplayToken(serialized: string): ReplayToken {
  let value: unknown;
  try {
    value = JSON.parse(serialized) as unknown;
  } catch {
    throw new Error('ReplayToken 不是合法 JSON。');
  }
  if (
    typeof value !== 'object' ||
    value === null ||
    Array.isArray(value) ||
    !Object.hasOwn(value, 'seed') ||
    !Object.hasOwn(value, 'iteration')
  ) {
    throw new Error('ReplayToken 形状无效。');
  }
  const object = value as { seed?: unknown; iteration?: unknown };
  if (typeof object.seed !== 'string' || !/^-?\d+$/.test(object.seed)) {
    throw new Error('ReplayToken seed 必须是十进制整数文本。');
  }
  if (typeof object.iteration !== 'number') {
    throw new Error('ReplayToken iteration 必须是数字。');
  }
  const token = { seed: object.seed, iteration: object.iteration };
  validateReplayToken(token);
  return token;
}

export function replaySeededProperty(token: ReplayToken, property: ReplayableProperty): void {
  validateReplayToken(token);
  const random = new SeededRandom(BigInt(token.seed));
  for (let iteration = 0; iteration <= token.iteration; iteration += 1) {
    try {
      property(random, iteration);
    } catch (error: unknown) {
      const detail = error instanceof Error ? error.message : String(error);
      throw new Error(
        `可重放属性测试失败（seed=${random.seed.toString()}, iteration=${iteration}）：${detail}`,
      );
    }
  }
}

function validateReplayToken(token: ReplayToken): void {
  if (typeof token.seed !== 'string' || !/^-?\d+$/.test(token.seed)) {
    throw new Error('ReplayToken seed 必须是十进制整数文本。');
  }
  if (!Number.isSafeInteger(token.iteration) || token.iteration < 0) {
    throw new Error('ReplayToken iteration 必须是非负安全整数。');
  }
  // 构造一次以校验任意长度 seed，并将负数按测试随机源的 uint64 语义处理。
  new SeededRandom(BigInt(token.seed));
}
