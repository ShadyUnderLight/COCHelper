/**
 * Generation 绑定的待确认槽（#323 P2：normal/quick 共用同一 CAS 不变量）。
 * 调用者 token == 当前 generation == 创建代，三者齐才算“针对这一版 prepare 的提交”，
 * 否则按过期拒绝。两边必须走同一个 takeLive，禁止各自手写 CAS。
 */

export const STALE_PENDING_MESSAGE = '导入状态已过期，请刷新后重试。';

export class GenerationBoundSlot<T> {
  private entry: { readonly value: T; readonly generation: number } | null = null;

  store(value: T, generation: number): void {
    this.entry = { value, generation };
  }

  peek(): T | null {
    return this.entry?.value ?? null;
  }

  clear(): void {
    this.entry = null;
  }

  /**
   * 取出与 currentGeneration 绑定的值。
   * 创建代落后即为死 pending（generation 只增不减，它永不可能再被合法提交）：
   * 直接清理并调用 onStale（调用方抛 conflict），且绝不 bump。fresh/null 原样返回，
   * 调用方继续走自己的 token 校验与生命周期。
   */
  takeLive(currentGeneration: number, onStale: () => never): T | null {
    const entry = this.entry;
    if (entry !== null && entry.generation !== currentGeneration) {
      this.entry = null;
      onStale();
    }
    return entry?.value ?? null;
  }
}
