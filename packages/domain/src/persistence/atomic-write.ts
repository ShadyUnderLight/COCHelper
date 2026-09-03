import {
  closeSync,
  fsyncSync,
  mkdirSync,
  openSync,
  renameSync,
  rmSync,
  writeFileSync,
  writeSync,
} from 'node:fs';
import { dirname, join } from 'node:path';

import type { WriteFaultInjector } from './fault';

export type AtomicWriteOptions = {
  readonly fault?: WriteFaultInjector;
};

/**
 * 兄弟临时文件 + fsync + rename，对齐 Foundation Data.write(.atomic) 语义：
 * 失败时尽量保留目标路径旧字节。
 */
export function atomicWriteFile(
  filePath: string,
  data: Uint8Array,
  options: AtomicWriteOptions = {},
): void {
  const directory = dirname(filePath);
  mkdirSync(directory, { recursive: true });
  options.fault?.beforePrepare?.(filePath);

  const temporaryPath = join(
    directory,
    `.${basenameSafe(filePath)}.${process.pid}.${Date.now()}.tmp`,
  );

  let fd: number | undefined;
  try {
    options.fault?.beforeWrite?.(filePath);
    fd = openSync(temporaryPath, 'w');
    writeSync(fd, data);
    fsyncSync(fd);
    closeSync(fd);
    fd = undefined;
    options.fault?.beforeRename?.(filePath);
    renameSync(temporaryPath, filePath);
    options.fault?.afterCommit?.(filePath);
  } catch (error) {
    if (fd !== undefined) {
      try {
        closeSync(fd);
      } catch {
        // best-effort
      }
    }
    try {
      rmSync(temporaryPath, { force: true });
    } catch {
      // best-effort
    }
    throw error;
  }
}

/** 无文件描述符路径（测试或受限环境）：仍使用临时文件 + rename。 */
export function atomicWriteFileSimple(
  filePath: string,
  data: Uint8Array,
  options: AtomicWriteOptions = {},
): void {
  const directory = dirname(filePath);
  mkdirSync(directory, { recursive: true });
  options.fault?.beforePrepare?.(filePath);
  const temporaryPath = join(
    directory,
    `.${basenameSafe(filePath)}.${process.pid}.${Date.now()}.tmp`,
  );
  try {
    options.fault?.beforeWrite?.(filePath);
    writeFileSync(temporaryPath, data);
    options.fault?.beforeRename?.(filePath);
    renameSync(temporaryPath, filePath);
    options.fault?.afterCommit?.(filePath);
  } catch (error) {
    try {
      rmSync(temporaryPath, { force: true });
    } catch {
      // best-effort
    }
    throw error;
  }
}

function basenameSafe(filePath: string): string {
  const parts = filePath.split(/[/\\]/);
  return parts[parts.length - 1] ?? 'file';
}
