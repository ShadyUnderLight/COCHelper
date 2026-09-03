import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import { cleanupOrphanAtomicTempFiles, PERSISTENCE_MAX_FILE_BYTES } from './limits';

describe('persistence limits', () => {
  it('清理 data root 内孤儿原子写临时文件', () => {
    const directory = mkdtempSync(join(tmpdir(), 'coc-orphan-'));
    const orphan = join(directory, '.villages-v1.json.12345.999.tmp');
    const keep = join(directory, 'villages-v1.json');
    writeFileSync(orphan, 'tmp');
    writeFileSync(keep, '[]');
    const removed = cleanupOrphanAtomicTempFiles(directory);
    expect(removed).toEqual([orphan]);
    expect(existsSync(orphan)).toBe(false);
    expect(existsSync(keep)).toBe(true);
    rmSync(directory, { recursive: true, force: true });
  });

  it('暴露统一大小上限常量', () => {
    expect(PERSISTENCE_MAX_FILE_BYTES).toBeGreaterThan(0);
  });
});
