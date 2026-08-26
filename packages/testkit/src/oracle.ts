import { execFileSync } from 'node:child_process';

import { findRepoRoot } from './paths';

/** 显式打开后才允许调用仓库内 Swift `golden-oracle`。默认关闭，避免 Linux CI / 运行时误用。 */
export const SWIFT_ORACLE_ENV = 'COCHELPER_SWIFT_ORACLE';

export function isSwiftOracleEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return env[SWIFT_ORACLE_ENV] === '1';
}

/**
 * 迁移期生成参考结果。不得被 Electron runtime 调用。
 * 需要本机 Swift 工具链；Ubuntu Electron job 应继续消费冻结 fixture。
 */
export function runSwiftOracle(
  args: readonly string[],
  repoRoot = findRepoRoot(),
  env: NodeJS.ProcessEnv = process.env,
): string {
  if (!isSwiftOracleEnabled(env)) {
    throw new Error(`Swift oracle 默认关闭。设置 ${SWIFT_ORACLE_ENV}=1 才可在迁移期生成参考结果。`);
  }
  return execFileSync('swift', ['run', 'golden-oracle', ...args], {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    env,
  });
}
