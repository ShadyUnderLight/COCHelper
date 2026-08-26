import { SeededRandom } from './seeded-random';

export type SeededProperty = (random: SeededRandom, iteration: number) => void;

export type SeededPropertyOptions = {
  readonly seed: bigint | number;
  readonly iterations: number;
  readonly property: SeededProperty;
};

/** 运行可重放的属性测试；失败信息固定带 seed 与 iteration。 */
export function runSeededProperty(options: SeededPropertyOptions): void {
  if (!Number.isSafeInteger(options.iterations) || options.iterations < 0) {
    throw new RangeError('属性测试 iterations 必须是非负安全整数。');
  }

  const random = new SeededRandom(options.seed);
  for (let iteration = 0; iteration < options.iterations; iteration += 1) {
    try {
      options.property(random, iteration);
    } catch (error: unknown) {
      const detail = error instanceof Error ? error.message : String(error);
      throw new Error(
        `确定性属性测试失败（seed=${random.seed.toString()}, iteration=${iteration}）：${detail}`,
      );
    }
  }
}
