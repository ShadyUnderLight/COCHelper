#!/usr/bin/env node
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const defaultRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FORBIDDEN_PACKAGE = '@coc-helper/testkit';

function walk(dir) {
  if (!existsSync(dir)) {
    return [];
  }
  const out = [];
  for (const entry of readdirSync(dir)) {
    if (entry === 'node_modules' || (entry.startsWith('.') && entry !== '.webpack')) {
      continue;
    }
    const full = path.join(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) {
      out.push(...walk(full));
    } else {
      out.push(full);
    }
  }
  return out;
}

function packageHits(workspaceRoot) {
  const hits = [];
  const productionManifests = [
    ['apps/desktop/package.json', ['dependencies', 'devDependencies']],
    ['packages/wire/package.json', ['dependencies']],
    ['packages/domain/package.json', ['dependencies']],
    ['packages/contracts/package.json', ['dependencies']],
  ];
  for (const [relative, fields] of productionManifests) {
    const json = JSON.parse(readFileSync(path.join(workspaceRoot, relative), 'utf8'));
    for (const field of fields) {
      if (json[field]?.[FORBIDDEN_PACKAGE]) {
        hits.push(`${relative} ${field} 不得依赖 ${FORBIDDEN_PACKAGE}`);
      }
    }
  }
  return hits;
}

function sourceImportHits(workspaceRoot) {
  const hits = [];
  const roots = [
    path.join(workspaceRoot, 'apps/desktop/src'),
    path.join(workspaceRoot, 'packages/wire/src'),
    path.join(workspaceRoot, 'packages/domain/src'),
    path.join(workspaceRoot, 'packages/contracts/src'),
  ];
  const importRe = /from\s+['"]@coc-helper\/testkit['"]|require\(\s*['"]@coc-helper\/testkit['"]\s*\)/;
  for (const dir of roots) {
    for (const file of walk(dir)) {
      if (!/\.(ts|js|mjs|cjs|tsx)$/.test(file)) {
        continue;
      }
      const relative = path.relative(workspaceRoot, file).split(path.sep).join('/');
      if (relative.includes('.test.') || relative.endsWith('.test.ts')) {
        continue;
      }
      const text = readFileSync(file, 'utf8');
      if (importRe.test(text)) {
        hits.push(`生产源码不得 import testkit: ${relative}`);
      }
    }
  }
  return hits;
}

function packagedHits(workspaceRoot) {
  const hits = [];
  const outputs = [
    path.join(workspaceRoot, 'apps/desktop/out'),
    path.join(workspaceRoot, 'apps/desktop/.webpack'),
  ];
  for (const dir of outputs) {
    if (!existsSync(dir)) {
      continue;
    }
    for (const file of walk(dir)) {
      const relative = path.relative(workspaceRoot, file).split(path.sep).join('/');
      if (file.endsWith('.swift')) {
        hits.push(`发布产物含 Swift 源：${relative}`);
      }
      if (relative.includes('golden-oracle')) {
        hits.push(`发布产物含 golden-oracle：${relative}`);
      }
      if (/\.(js|mjs|cjs|json)$/.test(file)) {
        const text = readFileSync(file, 'utf8');
        if (text.includes(FORBIDDEN_PACKAGE)) {
          hits.push(`发布产物含 testkit：${relative}`);
        }
      }
    }
  }
  return hits;
}

export function collectTestkitIsolationHits(workspaceRoot = defaultRoot) {
  return [
    ...packageHits(workspaceRoot),
    ...sourceImportHits(workspaceRoot),
    ...packagedHits(workspaceRoot),
  ];
}

const invokedDirectly = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  const hits = collectTestkitIsolationHits();
  if (hits.length > 0) {
    console.error('testkit / oracle 隔离检查失败:');
    for (const hit of hits) {
      console.error(`- ${hit}`);
    }
    process.exit(1);
  }
  console.log('testkit / oracle 隔离检查通过');
}
