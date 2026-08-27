import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { describe, expect, it } from 'vitest';

import {
  collectTestkitIsolationHits,
  extractImportSpecifiers,
  extractUnsafeDynamicLoads,
  findForbiddenImportHits,
  isTestkitPackageSpecifier,
  scanAsarArchive,
} from './check-testkit-isolation.mjs';

describe('testkit isolation', () => {
  it('desktop / 生产包不得依赖或打包 testkit 与 Swift oracle', () => {
    expect(collectTestkitIsolationHits()).toEqual([]);
  });

  it('能识别 subpath、side-effect、dynamic import、require 与相对路径', () => {
    expect(isTestkitPackageSpecifier('@coc-helper/testkit')).toBe(true);
    expect(isTestkitPackageSpecifier('@coc-helper/testkit/src/oracle')).toBe(true);
    expect(isTestkitPackageSpecifier('@coc-helper/wire')).toBe(false);

    expect(extractImportSpecifiers(`import { x } from '@coc-helper/testkit/src/oracle';`)).toEqual([
      '@coc-helper/testkit/src/oracle',
    ]);
    expect(extractImportSpecifiers(`import '@coc-helper/testkit';`)).toEqual(['@coc-helper/testkit']);
    expect(extractImportSpecifiers(`const mod = import('@coc-helper/testkit');`)).toEqual([
      '@coc-helper/testkit',
    ]);
    expect(extractImportSpecifiers(`require('@coc-helper/testkit/src/oracle');`)).toEqual([
      '@coc-helper/testkit/src/oracle',
    ]);
    expect(extractImportSpecifiers(`export { runSwiftOracle } from '@coc-helper/testkit';`)).toEqual(
      ['@coc-helper/testkit'],
    );
    expect(
      extractImportSpecifiers(`
        const mod = import(
          /* webpackChunkName: "test" */
          '@coc-helper/testkit'
        );
      `),
    ).toEqual(['@coc-helper/testkit']);

    const fromMain = 'apps/desktop/src/main/index.ts';
    expect(
      findForbiddenImportHits(
        `import { runSwiftOracle } from '@coc-helper/testkit/src/oracle';`,
        fromMain,
      ),
    ).not.toEqual([]);
    expect(findForbiddenImportHits(`import('@coc-helper/testkit');`, fromMain)).not.toEqual([]);
    expect(
      findForbiddenImportHits(
        `import(\n  /* webpackChunkName: "test" */\n  '@coc-helper/testkit'\n)`,
        fromMain,
      ),
    ).not.toEqual([]);
    expect(findForbiddenImportHits(`import '@coc-helper/testkit';`, fromMain)).not.toEqual([]);
    expect(
      findForbiddenImportHits(
        `import { runSwiftOracle } from '../../../../packages/testkit/src/oracle';`,
        fromMain,
      ),
    ).not.toEqual([]);
    expect(findForbiddenImportHits(`import { parseJson } from '@coc-helper/wire';`, fromMain)).toEqual(
      [],
    );
    expect(findForbiddenImportHits(`import { createRequire } from 'node:module';`, fromMain)).toEqual(
      [],
    );
    expect(
      findForbiddenImportHits(`const pkg = '@coc-helper/testkit'; import(pkg);`, fromMain),
    ).not.toEqual([]);
    const createRequireHits = findForbiddenImportHits(
      `import { createRequire } from 'node:module'; createRequire(import.meta.url)(pkg);`,
      fromMain,
    );
    expect(createRequireHits).toContain(
      `${fromMain} 不得使用无法静态解析的动态加载（createRequire()）`,
    );
    expect(
      extractUnsafeDynamicLoads(
        `import { createRequire } from 'node:module'; createRequire(import.meta.url)(pkg);`,
      ),
    ).toContain('createRequire()');
    const aliased = `
      import { createRequire } from 'node:module';
      const make = createRequire;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(aliased, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const destructured = `
      const { createRequire: cr } = mod;
      const req = cr(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(destructured, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    expect(extractUnsafeDynamicLoads(destructured)).toContain('createRequire()');
    const destructuredShorthand = `
      const { createRequire } = mod;
      const req = createRequire(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(destructuredShorthand, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const assignmentDestructure = `
      let cr;
      ({ createRequire: cr } = mod);
      const req = cr(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(assignmentDestructure, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const asAlias = `
      import { createRequire } from 'node:module';
      const make = createRequire as typeof createRequire;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(asAlias, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const parenAlias = `
      import { createRequire } from 'node:module';
      const make = (createRequire);
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(parenAlias, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
  });

  it('会解包扫描 app.asar 内的 js', async () => {
    const asar = createRequire(fileURLToPath(import.meta.url))('@electron/asar');
    const root = mkdtempSync(path.join(os.tmpdir(), 'testkit-asar-'));
    const src = path.join(root, 'src');
    mkdirSync(src);
    try {
      writeFileSync(path.join(src, 'index.js'), 'export const x = 1;\n');
      const cleanArchive = path.join(root, 'clean.asar');
      await asar.createPackage(src, cleanArchive);
      expect(scanAsarArchive(cleanArchive, 'clean.asar')).toEqual([]);

      writeFileSync(path.join(src, 'index.js'), 'import "@coc-helper/testkit";\n');
      const dirtyArchive = path.join(root, 'app.asar');
      await asar.createPackage(src, dirtyArchive);
      expect(scanAsarArchive(dirtyArchive, 'app.asar').join('\n')).toContain('@coc-helper/testkit');

      const nested = path.join(src, 'node_modules/@coc-helper/testkit');
      mkdirSync(nested, { recursive: true });
      writeFileSync(path.join(src, 'index.js'), 'export const x = 1;\n');
      writeFileSync(path.join(nested, 'index.js'), 'export const oracle = 1;\n');
      const nestedArchive = path.join(root, 'nested.asar');
      await asar.createPackage(src, nestedArchive);
      expect(scanAsarArchive(nestedArchive, 'nested.asar').join('\n')).toContain(
        'node_modules/@coc-helper/testkit',
      );
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});
