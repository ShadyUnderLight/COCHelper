/** 可注入的写入边界 fault，用于 kill/restart 与半提交对抗测试。 */
export type WriteFaultInjector = {
  beforePrepare?(filePath: string): void;
  beforeWrite?(filePath: string): void;
  beforeRename?(filePath: string): void;
  afterCommit?(filePath: string): void;
};

export class FaultInjectionError extends Error {
  readonly filePath: string;
  readonly stage: string;

  constructor(filePath: string, stage: string) {
    super(`fault injected at ${stage}: ${filePath}`);
    this.name = 'FaultInjectionError';
    this.filePath = filePath;
    this.stage = stage;
  }
}

export function createThrowingFault(
  stage: keyof WriteFaultInjector,
  match?: (filePath: string) => boolean,
): WriteFaultInjector {
  return {
    [stage](filePath: string): void {
      if (match !== undefined && !match(filePath)) {
        return;
      }
      throw new FaultInjectionError(filePath, stage);
    },
  };
}

/** 仅在第 N 次匹配时抛错，便于测试 commit 失败后的 rollback 路径。 */
export function createCountingFault(
  stage: keyof WriteFaultInjector,
  throwOnCall: number,
  match?: (filePath: string) => boolean,
): WriteFaultInjector {
  let calls = 0;
  return {
    [stage](filePath: string): void {
      if (match !== undefined && !match(filePath)) {
        return;
      }
      calls += 1;
      if (calls === throwOnCall) {
        throw new FaultInjectionError(filePath, stage);
      }
    },
  };
}
