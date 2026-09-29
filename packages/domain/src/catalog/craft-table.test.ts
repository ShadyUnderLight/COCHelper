import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import {
  assessCraftTableModuleLevel,
  craftTableModuleStageMaxLevel,
  loadCraftTableCatalog,
  resolveCatalogBundleRoot,
} from './index';

const repoRoot = resolveCatalogBundleRoot(process.cwd());
const describeIfBundle = repoRoot === null ? describe.skip : describe;

describeIfBundle('CraftTableCatalog', () => {
  const versionRoot = join(repoRoot!, '18.400.13');
  const manifestText = readFileSync(join(versionRoot, 'manifest.json'), 'utf8');
  const craftText = readFileSync(join(versionRoot, 'craft_table_catalog.json'), 'utf8');

  it('loadBundled 返回 catalog（V3 manifest，无 hash 对账）', () => {
    const catalog = loadCraftTableCatalog({
      version: '18.400.13',
      manifestText,
      craftText,
    });
    expect(catalog).not.toBeNull();
    expect(catalog!.defense(103_000_000n)?.name).toBe('钩索塔');
    const module = catalog!.module(102_000_033n);
    expect(module?.maxLevel).toBe(10);
    expect(module?.levels.find((level) => level.level === 2)?.requiredTownHallLevel).toBe(12);
  });

  it('旧 schemaVersion manifest 被拒绝', () => {
    const oldManifest = JSON.stringify({
      schemaVersion: 2,
      gameVersion: '18.400.13',
      buildTag: '18_400_7',
      locale: 'zh-CN',
    });
    expect(
      loadCraftTableCatalog({ version: '18.400.13', manifestText: oldManifest, craftText }),
    ).toBeNull();
  });

  it('版本不一致时返回 null', () => {
    expect(loadCraftTableCatalog({ version: '9.999.0', manifestText, craftText })).toBeNull();
  });

  it('同 gameVersion 不同 buildTag 时拒绝（业务版本绑定）', () => {
    const manifest = JSON.parse(manifestText) as { buildTag: string };
    manifest.buildTag = '19_0_0';
    expect(
      loadCraftTableCatalog({
        version: '18.400.13',
        manifestText: JSON.stringify(manifest),
        craftText,
      }),
    ).toBeNull();
  });

  it('craft 内容损坏时返回 null', () => {
    expect(
      loadCraftTableCatalog({ version: '18.400.13', manifestText, craftText: 'not-json' }),
    ).toBeNull();
  });

  it.each([
    ['缺少 maxLevel', (module: Record<string, unknown>) => delete module.maxLevel],
    ['maxLevel 字符串', (module: Record<string, unknown>) => (module.maxLevel = '10')],
    ['maxLevel 布尔值', (module: Record<string, unknown>) => (module.maxLevel = true)],
    ['maxLevel null', (module: Record<string, unknown>) => (module.maxLevel = null)],
    ['maxLevel 为零', (module: Record<string, unknown>) => (module.maxLevel = 0)],
    ['maxLevel 非整数', (module: Record<string, unknown>) => (module.maxLevel = 1.5)],
    ['level 字符串', (module: Record<string, unknown>) => setFirstLevel(module, 'level', '1')],
    ['level 非整数', (module: Record<string, unknown>) => setFirstLevel(module, 'level', 1.5)],
    [
      '大本营门槛字符串',
      (module: Record<string, unknown>) => setFirstLevel(module, 'requiredTownHallLevel', '12'),
    ],
    [
      '大本营门槛布尔值',
      (module: Record<string, unknown>) => setFirstLevel(module, 'requiredTownHallLevel', true),
    ],
    [
      '缺少大本营门槛',
      (module: Record<string, unknown>) => setFirstLevel(module, 'requiredTownHallLevel', null),
    ],
    [
      '大本营门槛超出游戏范围',
      (module: Record<string, unknown>) => setFirstLevel(module, 'requiredTownHallLevel', 19),
    ],
    [
      '大本营门槛不单调',
      (module: Record<string, unknown>) => {
        setFirstLevel(module, 'requiredTownHallLevel', 13);
        setSecondLevel(module, 'requiredTownHallLevel', 12);
      },
    ],
  ])('目录包含非法数值时拒绝整个目录：%s', (_caseName, mutate) => {
    const parsed = JSON.parse(craftText) as { modules: Array<Record<string, unknown>> };
    const module = parsed.modules.find((entry) => entry.dataID === 102_000_033);
    expect(module).toBeDefined();
    mutate(module!);

    expect(
      loadCraftTableCatalog({
        version: '18.400.13',
        manifestText,
        craftText: JSON.stringify(parsed),
      }),
    ).toBeNull();
  });

  it('NaN 在 JSON 目录中不可编码，且非法门槛令状态保持 unknown', () => {
    const module = loadCraftTableCatalog({
      version: '18.400.13',
      manifestText,
      craftText: craftText.replace(/("maxLevel"\s*:\s*)\d+/, '$1NaN'),
    });
    expect(module).toBeNull();

    const validCatalog = loadCraftTableCatalog({ version: '18.400.13', manifestText, craftText });
    const spec = validCatalog!.module(102_000_033n)!;
    const nonMonotonicSpec = {
      ...spec,
      levels: spec.levels.map((level) =>
        level.level === 2 ? { ...level, requiredTownHallLevel: 11 } : level,
      ),
    };
    expect(craftTableModuleStageMaxLevel(nonMonotonicSpec, 18)).toBeNull();
    expect(assessCraftTableModuleLevel(nonMonotonicSpec, 1, 18).status).toBe('unknown');
  });
});

function setFirstLevel(module: Record<string, unknown>, key: string, value: unknown): void {
  const levels = module.levels as Array<Record<string, unknown>>;
  levels[0]![key] = value;
}

function setSecondLevel(module: Record<string, unknown>, key: string, value: unknown): void {
  const levels = module.levels as Array<Record<string, unknown>>;
  levels[1]![key] = value;
}
