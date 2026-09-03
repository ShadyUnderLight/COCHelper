import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import { atomicWriteFile } from './atomic-write';
import { createThrowingFault, FaultInjectionError } from './fault';

describe('atomicWriteFile', () => {
  it('写入成功且目标可读', () => {
    const directory = mkdtempSync(join(tmpdir(), 'coc-atomic-'));
    const filePath = join(directory, 'target.json');
    atomicWriteFile(filePath, new TextEncoder().encode('{"ok":true}'));
    expect(readFileSync(filePath, 'utf8')).toBe('{"ok":true}');
    rmSync(directory, { recursive: true, force: true });
  });

  it('rename 前注入 fault 时保留旧字节', () => {
    const directory = mkdtempSync(join(tmpdir(), 'coc-atomic-fault-'));
    const filePath = join(directory, 'target.json');
    writeFileSync(filePath, 'old-bytes');
    expect(() =>
      atomicWriteFile(filePath, new TextEncoder().encode('new-bytes'), {
        fault: createThrowingFault('beforeRename'),
      }),
    ).toThrow(FaultInjectionError);
    expect(readFileSync(filePath, 'utf8')).toBe('old-bytes');
    rmSync(directory, { recursive: true, force: true });
  });
});
