import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
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
    const arrayAlias = `
      import { createRequire } from 'node:module';
      const [make] = [createRequire];
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(arrayAlias, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const arrayRequire = `
      const [req] = [require];
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(arrayRequire, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const aliasedArray = `
      import { createRequire } from 'node:module';
      const aliases = [createRequire];
      const [make] = aliases;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(aliasedArray, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const spreadArray = `
      import { createRequire } from 'node:module';
      const aliases = [createRequire];
      const [make] = [...aliases];
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(spreadArray, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const opaqueArray = `
      const [make] = getAliases();
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(opaqueArray, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（非静态数组解构）`]),
    );
    const opaqueElement = `
      import { createRequire } from 'node:module';
      const aliases = [getCreateRequire()];
      const [make] = aliases;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(opaqueElement, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（非静态数组解构）`]),
    );
    const conditionalElement = `
      import { createRequire } from 'node:module';
      const aliases = [flag ? createRequire : fallback];
      const [make] = aliases;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(conditionalElement, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const logicalElement = `
      import { createRequire } from 'node:module';
      const aliases = [flag && createRequire];
      const [make] = aliases;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(logicalElement, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const mutatedPush = `
      import { createRequire } from 'node:module';
      const aliases = [];
      aliases.push(createRequire);
      const [make] = aliases;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(mutatedPush, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（非静态数组解构）`]),
    );
    const mutatedIndex = `
      import { createRequire } from 'node:module';
      const aliases = [];
      aliases[0] = createRequire;
      const [make] = aliases;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(mutatedIndex, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（非静态数组解构）`]),
    );
    const mutatedSpread = `
      import { createRequire } from 'node:module';
      const aliases = [];
      aliases.push(createRequire);
      const [make] = [...aliases];
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(mutatedSpread, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（非静态数组解构）`]),
    );
    const computedPush = `
      import { createRequire } from 'node:module';
      const aliases = [];
      aliases['push'](createRequire);
      const [make] = aliases;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(computedPush, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（非静态数组解构）`]),
    );
    const computedUnknown = `
      import { createRequire } from 'node:module';
      const aliases = [];
      aliases[method](createRequire);
      const [make] = aliases;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(computedUnknown, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（非静态数组解构）`]),
    );
    const reassignedUnknown = `
      import { createRequire } from 'node:module';
      let aliases = [];
      aliases = getAliases();
      const [make] = aliases;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(reassignedUnknown, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（非静态数组解构）`]),
    );
    const reassignedConcat = `
      import { createRequire } from 'node:module';
      let aliases = [];
      aliases = aliases.concat(createRequire);
      const [make] = aliases;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(reassignedConcat, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const aliasedRefPush = `
      import { createRequire } from 'node:module';
      const aliases = [];
      const ref = aliases;
      ref.push(createRequire);
      const [make] = aliases;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(aliasedRefPush, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（非静态数组解构）`]),
    );
    const aliasedRefIndex = `
      import { createRequire } from 'node:module';
      const aliases = [];
      const ref = aliases;
      ref[0] = createRequire;
      const [make] = aliases;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(aliasedRefIndex, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（非静态数组解构）`]),
    );
    const objectDestructuredRef = `
      import { createRequire } from 'node:module';
      const aliases = [];
      const { ref } = { ref: aliases };
      ref.push(createRequire);
      const [make] = aliases;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(objectDestructuredRef, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（非静态数组解构）`]),
    );
    const objectPropertyRef = `
      import { createRequire } from 'node:module';
      const aliases = [];
      const box = { ref: aliases };
      const ref = box.ref;
      ref.push(createRequire);
      const [make] = aliases;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(objectPropertyRef, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（非静态数组解构）`]),
    );
    const objectAliasRef = `
      import { createRequire } from 'node:module';
      const aliases = [];
      const box = { ref: aliases };
      const otherBox = box;
      const { ref } = otherBox;
      ref[0] = createRequire;
      const [make] = aliases;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(objectAliasRef, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（非静态数组解构）`]),
    );
    const opaqueThenRebound = `
      import { createRequire } from 'node:module';
      let aliases = [];
      aliases.push(createRequire);
      aliases = [];
      const [make] = aliases;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(opaqueThenRebound, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（非静态数组解构）`]),
    );

    const arrayElementAlias = `
      import { createRequire } from 'node:module';
      const aliases = [createRequire];
      const make = aliases[0];
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(arrayElementAlias, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const objectFunctionDestructure = `
      import { createRequire } from 'node:module';
      const box = { make: createRequire };
      const { make } = box;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(objectFunctionDestructure, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const boundFactory = `
      import { createRequire } from 'node:module';
      const make = createRequire.bind(null);
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(boundFactory, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const objectSpreadAndConcat = `
      import { createRequire } from 'node:module';
      const box = { ...{ make: createRequire } };
      const { make } = box;
      const req = make(import.meta.url);
      req('@coc-helper/' + 'testkit');
    `;
    expect(extractImportSpecifiers(objectSpreadAndConcat)).toContain('@coc-helper/testkit');
    expect(findForbiddenImportHits(objectSpreadAndConcat, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const expressionAliasesAndJoin = `
      import { createRequire } from 'node:module';
      const make = [createRequire][0];
      const req = make(import.meta.url);
      const scope = ['@coc-', 'helper'].join('');
      const name = ['test', 'kit'].join('');
      req(scope + '/' + name);
    `;
    expect(extractImportSpecifiers(expressionAliasesAndJoin)).toContain('@coc-helper/testkit');
    expect(findForbiddenImportHits(expressionAliasesAndJoin, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const flowSensitiveString = `
      let pkg = getPackageName();
      require(pkg);
      pkg = 'safe';
    `;
    expect(findForbiddenImportHits(flowSensitiveString, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（非字面量 require()）`]),
    );
    const branchSensitiveString = `
      let pkg = getPackageName();
      if (flag) {
        pkg = 'safe';
      }
      require(pkg);
    `;
    expect(findForbiddenImportHits(branchSensitiveString, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（非字面量 require()）`]),
    );
    const nestedScopeString = `
      const pkg = 'safe';
      {
        const pkg = 'also-safe';
        require(pkg);
      }
    `;
    expect(findForbiddenImportHits(nestedScopeString, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（非字面量 require()）`]),
    );
    const functionReturnedRequirer = `
      function getRequire() {
        return require;
      }
      const req = getRequire();
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(functionReturnedRequirer, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const functionReturnedFactory = `
      import { createRequire } from 'node:module';
      const getFactory = () => createRequire;
      const make = getFactory();
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(functionReturnedFactory, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const inlineObjectProperty = `
      import { createRequire } from 'node:module';
      const req = ({ f: createRequire }).f(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(inlineObjectProperty, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const assignedObjectProperty = `
      import { createRequire } from 'node:module';
      const box = {};
      box.f = createRequire;
      const req = box.f(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(assignedObjectProperty, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const computedObjectProperty = `
      import { createRequire } from 'node:module';
      const box = {};
      box.f = createRequire;
      const key = 'f';
      const make = box[key];
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(computedObjectProperty, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const genericLoaderArgument = `
      function use(loader) {
        return loader('@coc-helper/testkit');
      }
      use(require);
    `;
    expect(findForbiddenImportHits(genericLoaderArgument, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（动态加载器作为参数）`]),
    );
    const unknownSpecifierDataFlow = `
      import { createRequire } from 'node:module';
      const box = { ...{ make: createRequire } };
      const { make } = box;
      const req = make(import.meta.url);
      const suffix = getPackageName();
      req('@coc-helper/' + suffix);
    `;
    expect(findForbiddenImportHits(unknownSpecifierDataFlow, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（非字面量 require()）`]),
    );
    const arrayAtAlias = `
      import { createRequire } from 'node:module';
      const aliases = [createRequire];
      const make = aliases.at(0);
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(extractImportSpecifiers(arrayAtAlias)).toContain('@coc-helper/testkit');
    const borrowedPush = `
      import { createRequire } from 'node:module';
      const aliases = [];
      Array.prototype.push.call(aliases, createRequire);
      const [make] = aliases;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(borrowedPush, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（非静态数组解构）`]),
    );
    const borrowedPushApply = `
      import { createRequire } from 'node:module';
      const aliases = [];
      Array.prototype.push.apply(aliases, [createRequire]);
      const [make] = aliases;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(borrowedPushApply, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（非静态数组解构）`]),
    );
    const borrowedPushSpreadArguments = `
      import { createRequire } from 'node:module';
      const aliases = [];
      Array.prototype.push.call(...[aliases, createRequire]);
      const [make] = aliases;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(borrowedPushSpreadArguments, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（非静态数组解构）`]),
    );
    const borrowedPushAlias = `
      import { createRequire } from 'node:module';
      const aliases = [];
      const push = Array.prototype.push;
      push.call(aliases, createRequire);
      const [make] = aliases;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(borrowedPushAlias, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（非静态数组解构）`]),
    );
    const borrowedFactoryCall = `
      import { createRequire } from 'node:module';
      const req = createRequire.call(null, import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(borrowedFactoryCall, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const borrowedFactoryApply = `
      import { createRequire } from 'node:module';
      const req = createRequire.apply(null, [import.meta.url]);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(borrowedFactoryApply, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const arrayAtNegative = `
      import { createRequire } from 'node:module';
      const aliases = [createRequire];
      const make = aliases.at(-1);
      const req = make(import.meta.url);
      const scope = ['@coc-', 'helper'].join('');
      const name = ['test', 'kit'].join('');
      req(scope + '/' + name);
    `;
    expect(findForbiddenImportHits(arrayAtNegative, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const arrayAtVariable = `
      import { createRequire } from 'node:module';
      const aliases = [createRequire];
      const idx = 0;
      const make = aliases.at(idx);
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(arrayAtVariable, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const bracketVariableIndex = `
      import { createRequire } from 'node:module';
      const aliases = [createRequire];
      const idx = 0;
      const make = aliases[idx];
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(bracketVariableIndex, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const objectMethodReturnsLoader = `
      const box = {
        get() { return require; },
      };
      const make = box.get();
      make('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(objectMethodReturnsLoader, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const assignedFunctionReturnsLoader = `
      let get;
      get = function () { return require; };
      const make = get();
      make('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(assignedFunctionReturnsLoader, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const objectPropertyFunctionReturnsLoader = `
      import { createRequire } from 'node:module';
      const box = {
        make: function () { return createRequire; },
      };
      const factory = box.make();
      const req = factory(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(objectPropertyFunctionReturnsLoader, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const borrowedSpreadVariable = `
      import { createRequire } from 'node:module';
      const aliases = [];
      const args = [aliases, createRequire];
      Array.prototype.push.call(...args);
      const [make] = aliases;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(borrowedSpreadVariable, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得使用无法静态解析的动态加载（非静态数组解构）`]),
    );
    const functionReturnedArray = `
      import { createRequire } from 'node:module';
      function getAliases() { return [createRequire]; }
      const make = getAliases()[0];
      const req = make(import.meta.url);
      const pkg = ['@coc-', 'helper'].join('') + '/' + ['test', 'kit'].join('');
      req(pkg);
    `;
    expect(findForbiddenImportHits(functionReturnedArray, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const functionReturnedArrayAt = `
      import { createRequire } from 'node:module';
      function getAliases() { return [createRequire]; }
      const make = getAliases().at(0);
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(functionReturnedArrayAt, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const functionReturnedObject = `
      import { createRequire } from 'node:module';
      function getBox() { return { f: createRequire }; }
      const make = getBox().f;
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(functionReturnedObject, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const arrowReturnedArray = `
      import { createRequire } from 'node:module';
      const getAliases = () => [createRequire];
      const make = getAliases()[0];
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(arrowReturnedArray, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const inlineObjectMethodCall = `
      const make = ({ get() { return require; } }).get();
      const pkg = ['@coc-', 'helper'].join('') + '/' + ['test', 'kit'].join('');
      make(pkg);
    `;
    expect(findForbiddenImportHits(inlineObjectMethodCall, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const inlineObjectPropertyFnCall = `
      import { createRequire } from 'node:module';
      const make = ({ f: () => createRequire }).f();
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(inlineObjectPropertyFnCall, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const opaqueShapeKnownIndex = `
      import { createRequire } from 'node:module';
      function get(flag) { if (flag) return [createRequire]; return [unknown]; }
      const make = get(flag)[0];
      const req = make(import.meta.url);
      const pkg = ['@coc-', 'helper'].join('') + '/' + ['test', 'kit'].join('');
      req(pkg);
    `;
    expect(findForbiddenImportHits(opaqueShapeKnownIndex, fromMain).length).toBeGreaterThan(0);
    const opaqueShapeKnownAt = `
      import { createRequire } from 'node:module';
      function get(flag) { if (flag) return [createRequire]; return [unknown]; }
      const make = get(flag).at(0);
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(opaqueShapeKnownAt, fromMain).length).toBeGreaterThan(0);
    const objectAliasMethodReturn = `
      const box = { get() { return require; } };
      const alias = box;
      const make = alias.get();
      const pkg = ['@coc-', 'helper'].join('') + '/' + ['test', 'kit'].join('');
      make(pkg);
    `;
    expect(findForbiddenImportHits(objectAliasMethodReturn, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const nestedObjectMethodReturn = `
      const box = { nested: { get() { return require; } } };
      const make = box.nested.get();
      const pkg = ['@coc-', 'helper'].join('') + '/' + ['test', 'kit'].join('');
      make(pkg);
    `;
    expect(findForbiddenImportHits(nestedObjectMethodReturn, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const functionReturnedObjectMethod = `
      function getBox() { return { get() { return require; } }; }
      const make = getBox().get();
      const pkg = ['@coc-', 'helper'].join('') + '/' + ['test', 'kit'].join('');
      make(pkg);
    `;
    expect(findForbiddenImportHits(functionReturnedObjectMethod, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const namedObjectMethodReturn = `
      const box = { get() { return require; } };
      function getBox() { return box; }
      const make = getBox().get();
      const pkg = ['@coc-', 'helper'].join('') + '/' + ['test', 'kit'].join('');
      make(pkg);
    `;
    expect(findForbiddenImportHits(namedObjectMethodReturn, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const multiBranchReturnObject = `
      function getBox(flag) { if (flag) return { f: require }; return { f: safe }; }
      const make = getBox(true).f;
      make('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(multiBranchReturnObject, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const conditionalReturnedObject = `
      function getBox(flag) {
        return flag ? { f: require } : { f: safe };
      }
      const make = getBox(flag).f;
      const pkg = ['@coc-', 'helper'].join('') + '/' + ['test', 'kit'].join('');
      make(pkg);
    `;
    expect(findForbiddenImportHits(conditionalReturnedObject, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const conditionalReturnedObjectMethod = `
      function getBox(flag) {
        return flag
          ? { get() { return require; } }
          : { get() { return safe; } };
      }
      const make = getBox(flag).get();
      const pkg = ['@coc-', 'helper'].join('') + '/' + ['test', 'kit'].join('');
      make(pkg);
    `;
    expect(findForbiddenImportHits(conditionalReturnedObjectMethod, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const destructuredObjectMethod = `
      const box = { get() { return require; } };
      const { get } = box;
      const make = get();
      const pkg = ['@coc-', 'helper'].join('') + '/' + ['test', 'kit'].join('');
      make(pkg);
    `;
    expect(findForbiddenImportHits(destructuredObjectMethod, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const aliasedFunctionValue = `
      const box = { get() { return require; } };
      const { get } = box;
      const alias = get;
      const make = alias();
      make('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(aliasedFunctionValue, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const aliasedFunctionReturningArray = `
      import { createRequire } from 'node:module';
      const box = { getAliases() { return [createRequire]; } };
      const { getAliases } = box;
      const alias = getAliases;
      const make = alias()[0];
      const req = make(import.meta.url);
      req('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(aliasedFunctionReturningArray, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const destructuredReturnedObjectMethod = `
      function getBox(flag) {
        if (flag) return { get() { return require; } };
        return { get() { return safe; } };
      }
      const { get } = getBox(flag);
      const make = get();
      const pkg = ['@coc-', 'helper'].join('') + '/' + ['test', 'kit'].join('');
      make(pkg);
    `;
    expect(findForbiddenImportHits(destructuredReturnedObjectMethod, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const classInstanceMethod = `
      class Box {
        get() { return require; }
      }
      const make = new Box().get();
      const pkg = ['@coc-', 'helper'].join('') + '/' + ['test', 'kit'].join('');
      make(pkg);
    `;
    expect(findForbiddenImportHits(classInstanceMethod, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const aliasedClassInstanceMethod = `
      class Box {
        getAliases() { return [require]; }
      }
      const box = new Box();
      const alias = box.getAliases;
      const make = alias().at(0);
      make('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(aliasedClassInstanceMethod, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const destructuredClassInstanceMethod = `
      class Box {
        get() { return require; }
      }
      const { get } = new Box();
      const alias = get;
      const make = alias();
      make('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(destructuredClassInstanceMethod, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const staticClassMethod = `
      class Box {
        static get() { return require; }
      }
      const alias = Box.get;
      const make = alias();
      make('@coc-helper/testkit');
    `;
    expect(findForbiddenImportHits(staticClassMethod, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const classFieldCallable = `
      class Box {
        get = () => require;
      }
      const make = new Box().get();
      const pkg = ['@coc-', 'helper'].join('') + '/' + ['test', 'kit'].join('');
      make(pkg);
    `;
    expect(findForbiddenImportHits(classFieldCallable, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const staticClassFieldCallable = `
      class Box {
        static get = () => require;
      }
      const make = Box.get();
      const pkg = ['@coc-', 'helper'].join('') + '/' + ['test', 'kit'].join('');
      make(pkg);
    `;
    expect(findForbiddenImportHits(staticClassFieldCallable, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
  });

  it('会闭合 callable、class 与容器表达式的传播', () => {
    const fromMain = 'apps/desktop/src/main/index.ts';
    const load = `
      const pkg = ['@coc-', 'helper'].join('') + '/' + ['test', 'kit'].join('');
      req(pkg);
    `;
    const cases = [
      `const box = { nested: { get() { return require; } } };
       const { nested: { get } } = box; const req = get(); ${load}`,
      `const get = () => require; function pick() { return get; }
       const alias = pick(); const req = alias(); ${load}`,
      `const get = flag ? (() => require) : safe; const req = get(); ${load}`,
      `const get = flag && (() => require); const req = get(); ${load}`,
      `const get = () => require; const box = { get }; const req = box.get(); ${load}`,
      `const get = () => require; const box = {}; box.get = get;
       const req = box.get(); ${load}`,
      `const box = { get() { return require; } };
       const req = box.get.call(box); ${load}`,
      `const box = { get() { return require; } };
       const req = box.get.apply(box, []); ${load}`,
      `const box = { get() { return require; } };
       const req = box.get.bind(box)(); ${load}`,
      `class Box { constructor() { this.get = () => require; } }
       const box = new Box(); const req = box.get(); ${load}`,
      `class Base { get() { return require; } } class Box extends Base {}
       const req = new Box().get(); ${load}`,
      `class Box { get() { return require; } } const holder = { box: new Box() };
       const req = holder.box.get(); ${load}`,
      `import { createRequire } from 'node:module'; const aliases = [createRequire];
       const make = aliases.slice()[0]; const req = make(import.meta.url); ${load}`,
      `import { createRequire } from 'node:module';
       const make = (() => [createRequire])()[0]; const req = make(import.meta.url); ${load}`,
      `const req = (() => ({ get() { return require; } }))().get(); ${load}`,
      `function makeBox() { return { get() { return require; } }; }
       const holder = { box: makeBox() }; const req = holder.box.get(); ${load}`,
      `const req = flag ? require : safe; ${load}`,
      `function getRequire(flag) { return flag && require; }
       const req = getRequire(flag); ${load}`,
      `const box = { get: flag ? require : safe }; const req = box.get; ${load}`,
      `class Box { constructor() { this.req = require; } }
       const req = new Box().req; ${load}`,
      `class Box { req = require; } const req = new Box().req; ${load}`,
      `class Base { static get() { return require; } } class Child extends Base {}
       const req = Child.get(); ${load}`,
      `class Base { static get = () => require; } class Child extends Base {}
       const req = Child.get(); ${load}`,
      `const box = { get() { return require; } };
       function getBox(flag) { return flag && box; }
       const req = getBox(flag).get(); ${load}`,
      `const box = { get() { return require; } };
       const req = Object.assign({}, box).get(); ${load}`,
      `const box = { get() { return require; } };
       const req = Reflect.apply(box.get, box, []); ${load}`,
      `import { createRequire } from 'node:module'; const aliases = [createRequire];
       const { at } = aliases; const make = at(0); const req = make(import.meta.url); ${load}`,
      `import { createRequire } from 'node:module'; const aliases = [createRequire];
       const at = aliases.at; const make = at(0); const req = make(import.meta.url); ${load}`,
      `import { createRequire } from 'node:module'; const aliases = [];
       const make = aliases.concat(createRequire)[0]; const req = make(import.meta.url); ${load}`,
      `import { createRequire } from 'node:module'; const aliases = [createRequire];
       const make = aliases.map((item) => item)[0]; const req = make(import.meta.url); ${load}`,
      `import { createRequire } from 'node:module'; const aliases = [, createRequire];
       const make = aliases.slice(1)[0]; const req = make(import.meta.url); ${load}`,
      `import { createRequire } from 'node:module'; const aliases = [createRequire];
       const at = aliases.at; const at2 = at; const make = at2(0); const req = make(import.meta.url); ${load}`,
      `import { createRequire } from 'node:module'; const aliases = [createRequire];
       const make = Array.prototype.at.call(aliases, 0); const req = make(import.meta.url); ${load}`,
      `import { createRequire } from 'node:module'; const aliases = [createRequire];
       const make = Array.prototype.at.apply(aliases, [0]); const req = make(import.meta.url); ${load}`,
      `import { createRequire } from 'node:module'; const aliases = [createRequire];
       const make = aliases.at(0, extra); const req = make(import.meta.url); ${load}`,
      `import { createRequire } from 'node:module';
       const make = Array.from([createRequire])[0]; const req = make(import.meta.url); ${load}`,
      `import { createRequire } from 'node:module'; const aliases = [createRequire];
       const make = aliases.filter((item) => item)[0]; const req = make(import.meta.url); ${load}`,
      `import { createRequire } from 'node:module';
       const make = [[createRequire]].flat()[0]; const req = make(import.meta.url); ${load}`,
      `class Box { get() { return require; } }
       const req = [new Box()][0].get(); ${load}`,
      `const req = [{ get() { return require; } }][0].get(); ${load}`,
      `const get = () => require; function use(loader) { return loader(); }
       const req = use(get); ${load}`,
      `const box = { get() { return require; } }; function use(loader) { return loader(); }
       const req = use(box.get); ${load}`,
      `const box = { get() { return require; } }; const assign = Object.assign;
       const req = assign({}, box).get(); ${load}`,
      `const box = { inner: { get() { return require; } } };
       const req = Object.assign({}, box).inner.get(); ${load}`,
      `const box = { get() { return require; } }; const apply = Reflect.apply;
       const req = apply(box.get, box, []); ${load}`,
      `const box = { get() { return require; } };
       const req = Function.prototype.call.call(box.get, box); ${load}`,
      `const arr = [{ skip: true }];
       const req = arr.map(() => ({ get() { return require; } }))[0].get(); ${load}`,
      `const arr = [{ get() { return require; } }]; const i = 0; const req = arr[i].get(); ${load}`,
      `const req = [[[{ get() { return require; } }]]].flat(2)[0].get(); ${load}`,
      `function use({ loader }) { return loader; } const req = use({ loader: require }); ${load}`,
      `function use(loader) { return loader; } const req = use(...[require]); ${load}`,
      `const box = { get() { return require; } }; const sources = [box];
       const req = Object.assign({}, ...sources).get(); ${load}`,
      `const box = { get req() { return require; } }; const req = box.req; ${load}`,
      `import { createRequire } from 'node:module'; const aliases = [createRequire];
       const make = aliases.at.bind(aliases)(0); const req = make(import.meta.url); ${load}`,
      `import { createRequire } from 'node:module'; const aliases = [createRequire];
       const make = Array.prototype.at.call(...[aliases, 0]); const req = make(import.meta.url); ${load}`,
      `const box = { get() { return require; } };
       const req = Reflect.apply(...[box.get, box, []]); ${load}`,
      `function use(loader = require) { return loader; } const req = use(); ${load}`,
      `function use(...args) { return args[0].loader; } const req = use({ loader: require }); ${load}`,
      `const arr = [{ skip: true }];
       const req = arr.map((item) => { if (item.skip) return { skip: true }; return { get() { return require; } }; })[0].get(); ${load}`,
      `const req = Array.of({ get() { return require; } })[0].get(); ${load}`,
      `const box = { get() { return require; } };
       const req = Object.assign.call(null, {}, box).get(); ${load}`,
      `const box = { get() { return require; } };
       const req = Object.assign.apply(null, [{}, box]).get(); ${load}`,
      `import { createRequire } from 'node:module'; const aliases = [createRequire];
       const make = aliases.at(...unknown); const req = make(import.meta.url); ${load}`,
      `const box = { get() { return require; } };
       const req = Reflect.apply(...unknown); ${load}`,
      `import { createRequire } from 'node:module'; const aliases = [createRequire];
       const box = { at: aliases.at.bind(aliases) }; const make = box.at(0);
       const req = make(import.meta.url); ${load}`,
      `import { createRequire } from 'node:module'; const aliases = [createRequire];
       function getAt() { return aliases.at.bind(aliases); }
       const make = getAt()(0); const req = make(import.meta.url); ${load}`,
      `const req = ${Array.from({ length: 33 }, () => 0).reduce((acc) => `[${acc}]`, '{ get() { return require; } }')}.flat(unknown)[0].get(); ${load}`,
      `const req = (0, require); ${load}`,
      `function use(loader) { loader = require; return loader; } const req = use(safe); ${load}`,
      `import { createRequire } from 'node:module';
       function get(flag) { return flag ? [createRequire] : []; }
       const make = get(flag)[0]; const req = make(import.meta.url); ${load}`,
      `class Box { constructor() { this.inner = { get() { return require; } }; } }
       const req = new Box().inner.get(); ${load}`,
      `const box = { get() { return require; } };
       const req = ({ assign: Object.assign }).assign({}, box).get(); ${load}`,
      `function getBoxes() { return unknown; }
       const req = [...getBoxes()][0].get(); ${load}`,
      `import { createRequire } from 'node:module'; const aliases = [createRequire];
       const make = Array.prototype.at.call(...[aliases, ...getArgs()]);
       const req = make(import.meta.url); ${load}`,
      `import { createRequire } from 'node:module'; const aliases = [createRequire];
       const make = aliases.concat(...unknown)[0]; const req = make(import.meta.url); ${load}`,
      `const req = Object.assign({}, ...unknown).get(); ${load}`,
      `function use(loader) { return loader(pkg); } const req = use(...unknown); ${load}`,
      `function getBox() { return unknown; }
       const req = [getBox()][0].get(); ${load}`,
      `const req = new Array({ get() { return require; } })[0].get(); ${load}`,
      `const box = {}; Object.defineProperty(box, 'req', { get() { return require; } });
       const req = box.req; ${load}`,
      `function use(...{ loader }) { return loader; } const req = use({ loader: require }); ${load}`,
    ];

    for (const source of cases) {
      expect(findForbiddenImportHits(source, fromMain), source.replace(/\s+/g, ' ').slice(0, 120)).toEqual(
        expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
      );
    }
  });

  it('不会把普通回调和同名参数误判为动态加载器', () => {
    const source = `
      function redactJsonValue(value, markChanged) {
        if (Array.isArray(value)) {
          return value.map((item) => redactJsonValue(item, markChanged));
        }
        return value;
      }
      function redact(value) {
        const sanitized = redactJsonValue(parsed, () => {});
        return JSON.stringify(sanitized);
      }
      redact(structured.value);
    `;
    expect(extractUnsafeDynamicLoads(source)).toEqual([]);
  });

  it('外层 loader 别名不得污染内部同名普通回调', () => {
    const fromMain = 'apps/desktop/src/main/index.ts';
    const shadowed = `
      const callback = require;
      function redact(value) {
        return value.replace(/x/g, (callback) => callback);
      }
      redact('x');
    `;
    expect(extractUnsafeDynamicLoads(shadowed)).toEqual([]);
    const stillHits = `
      const callback = require;
      const pkg = ['@coc-', 'helper'].join('') + '/' + ['test', 'kit'].join('');
      function redact(value) {
        return value.replace(/x/g, (callback) => callback);
      }
      redact('x');
      callback(pkg);
    `;
    expect(findForbiddenImportHits(stillHits, fromMain)).toEqual(
      expect.arrayContaining([`${fromMain} 不得 import @coc-helper/testkit`]),
    );
    const blockShadowed = `
      const callback = require;
      {
        const callback = (match) => match;
        value.replace(/x/g, callback);
      }
    `;
    expect(extractUnsafeDynamicLoads(blockShadowed)).toEqual([]);
    const forOfShadowed = `
      const callback = require;
      for (const callback of items) {
        value.replace(/x/g, callback);
      }
    `;
    expect(extractUnsafeDynamicLoads(forOfShadowed)).toEqual([]);
  });

  it('生产源文件通过 symlink 指向 testkit 时按真实路径拒绝', () => {
    const root = mkdtempSync(path.join(os.tmpdir(), 'testkit-symlink-'));
    try {
      for (const manifest of [
        'apps/desktop/package.json',
        'packages/wire/package.json',
        'packages/domain/package.json',
        'packages/contracts/package.json',
      ]) {
        const file = path.join(root, manifest);
        mkdirSync(path.dirname(file), { recursive: true });
        writeFileSync(file, '{}');
      }
      const target = path.join(root, 'packages/testkit/src/escape.ts');
      mkdirSync(path.dirname(target), { recursive: true });
      writeFileSync(target, 'export const fixture = 1;\n');
      const link = path.join(root, 'apps/desktop/src/main/escape.ts');
      mkdirSync(path.dirname(link), { recursive: true });
      symlinkSync(target, link);

      expect(collectTestkitIsolationHits(root)).toEqual(
        expect.arrayContaining([
          '生产源码通过真实路径到达 testkit：apps/desktop/src/main/escape.ts',
        ]),
      );
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
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

  it('发布产物遍历不会跳过 app.asar.unpacked 下的 node_modules', () => {
    const root = mkdtempSync(path.join(os.tmpdir(), 'testkit-packaged-'));
    try {
      for (const manifest of [
        'apps/desktop/package.json',
        'packages/wire/package.json',
        'packages/domain/package.json',
        'packages/contracts/package.json',
      ]) {
        const file = path.join(root, manifest);
        mkdirSync(path.dirname(file), { recursive: true });
        writeFileSync(file, '{}');
      }
      const nested = path.join(
        root,
        'apps/desktop/out/app.asar.unpacked/node_modules/@coc-helper/testkit/index.js',
      );
      mkdirSync(path.dirname(nested), { recursive: true });
      writeFileSync(nested, 'export const fixture = 1;\n');

      expect(collectTestkitIsolationHits(root)).toEqual(
        expect.arrayContaining([
          '发布产物含 golden-oracle / testkit：apps/desktop/out/app.asar.unpacked/node_modules/@coc-helper/testkit/index.js',
        ]),
      );
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});
