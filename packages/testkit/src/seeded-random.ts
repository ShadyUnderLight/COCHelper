const UINT64_MASK = (1n << 64n) - 1n;
const UINT64_RANGE = 1n << 64n;
const SPLITMIX64_GAMMA = 0x9e3779b97f4a7c15n;
const SPLITMIX64_MUL1 = 0xbf58476d1ce4e5b9n;
const SPLITMIX64_MUL2 = 0x94d049bb133111ebn;

/** 固定算法的 SplitMix64 测试随机源；不是生产安全随机数。 */
export class SeededRandom {
  readonly seed: bigint;
  private state: bigint;

  constructor(seed: bigint | number) {
    if (typeof seed === 'number' && !Number.isSafeInteger(seed)) {
      throw new RangeError('SeededRandom seed 必须是安全整数。');
    }
    this.seed = BigInt(seed) & UINT64_MASK;
    this.state = this.seed;
  }

  nextUint64(): bigint {
    this.state = (this.state + SPLITMIX64_GAMMA) & UINT64_MASK;
    let value = this.state;
    value = ((value ^ (value >> 30n)) * SPLITMIX64_MUL1) & UINT64_MASK;
    value = ((value ^ (value >> 27n)) * SPLITMIX64_MUL2) & UINT64_MASK;
    return (value ^ (value >> 31n)) & UINT64_MASK;
  }

  nextBoolean(): boolean {
    return (this.nextUint64() & 1n) === 1n;
  }

  nextBigInt(min: bigint, max: bigint): bigint {
    if (min > max) {
      throw new RangeError('SeededRandom nextBigInt 必须满足 min <= max。');
    }
    const range = max - min + 1n;
    if (range <= UINT64_RANGE) {
      return min + this.nextUint64Below(range);
    }

    const bitCount = (range - 1n).toString(2).length;
    const wordCount = Math.ceil(bitCount / 64);
    const mask = (1n << BigInt(bitCount)) - 1n;
    let candidate: bigint;
    do {
      candidate = 0n;
      for (let word = 0; word < wordCount; word += 1) {
        candidate = (candidate << 64n) | this.nextUint64();
      }
      candidate &= mask;
    } while (candidate >= range);
    return min + candidate;
  }

  /** 返回包含 min/max 的安全整数。 */
  nextInt(min: number, max: number): number {
    if (!Number.isSafeInteger(min) || !Number.isSafeInteger(max) || min > max) {
      throw new RangeError('SeededRandom nextInt 需要有序的安全整数边界。');
    }
    return Number(this.nextBigInt(BigInt(min), BigInt(max)));
  }

  private nextUint64Below(range: bigint): bigint {
    const limit = UINT64_RANGE - (UINT64_RANGE % range);
    let value: bigint;
    do {
      value = this.nextUint64();
    } while (value >= limit);
    return value % range;
  }
}
