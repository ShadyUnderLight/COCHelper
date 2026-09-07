import { existsSync } from 'node:fs';
import { resolve } from 'node:path';

import { describe, expect, it } from 'vitest';

import { loadGoldenManifest } from './manifest';

const root = process.cwd();

/**
 * E1-02 干净基线：只验证“已登记且 owner 文件存在”。
 * 未执行的 suite 不能因为缺文件检查被跳过而记为通过——缺 owner 即失败。
 */
describe('E1-02 registration baseline', () => {
  it('每个 manifest case 的 typescriptOwner 文件必须存在', () => {
    const manifest = loadGoldenManifest(root);
    const missing: string[] = [];

    for (const entry of manifest.cases) {
      const ownerPath = resolve(root, entry.typescriptOwner);
      if (!existsSync(ownerPath)) {
        missing.push(`${entry.id} → ${entry.typescriptOwner}`);
      }
    }

    expect(missing, `未登记完整（不得记为通过）：\n${missing.join('\n')}`).toEqual([]);
  });

  it('swiftOwner 为占位符或指向仓库内路径', () => {
    const manifest = loadGoldenManifest(root);
    for (const entry of manifest.cases) {
      if (entry.swiftOwner === '—') {
        continue;
      }
      const pathOnly = entry.swiftOwner.split('#')[0]!;
      const fragments = pathOnly.split(';');
      for (const fragment of fragments) {
        expect(existsSync(resolve(root, fragment)), `${entry.id}: missing ${fragment}`).toBe(true);
      }
    }
  });

  it('#269–#275 核心回链 case 均已登记', () => {
    const ids = new Set(loadGoldenManifest(root).cases.map((entry) => entry.id));
    for (const required of [
      'parser/account-snapshot-golden',
      'projection/catalog-contract',
      'projection/village-projection-contract',
      'projection/manual-queue-capacity',
      'projection/manual-reconciliation-preview',
      'diff/snapshot-history-contract',
      'error/error-scenarios-contract',
      'error/storage-fault-contract',
    ]) {
      expect(ids.has(required), `missing required registration: ${required}`).toBe(true);
    }
  });
});
