import { describe, expect, it } from 'vitest';

import {
  collectTestkitIsolationHits,
  extractImportSpecifiers,
  findForbiddenImportHits,
  isTestkitPackageSpecifier,
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

    const fromMain = 'apps/desktop/src/main/index.ts';
    expect(
      findForbiddenImportHits(
        `import { runSwiftOracle } from '@coc-helper/testkit/src/oracle';`,
        fromMain,
      ),
    ).not.toEqual([]);
    expect(findForbiddenImportHits(`import('@coc-helper/testkit');`, fromMain)).not.toEqual([]);
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
  });
});
