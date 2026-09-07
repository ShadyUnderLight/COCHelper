#!/usr/bin/env node
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const hits = [];

function walk(dir) {
  if (!existsSync(dir)) {
    return [];
  }
  const out = [];
  for (const entry of readdirSync(dir)) {
    if (entry === 'node_modules' || entry === '.webpack' || entry.startsWith('.')) {
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

const desktopPkg = JSON.parse(
  readFileSync(path.join(root, 'apps/desktop/package.json'), 'utf8'),
);
for (const section of ['dependencies', 'devDependencies', 'optionalDependencies']) {
  const deps = desktopPkg[section] ?? {};
  if ('@coc-helper/testkit' in deps) {
    hits.push(`apps/desktop/package.json ${section} 依赖 @coc-helper/testkit`);
  }
}

const forgeText = readFileSync(path.join(root, 'apps/desktop/forge.config.ts'), 'utf8');
if (/golden-oracle|Tools\/golden-oracle|@coc-helper\/testkit/.test(forgeText)) {
  hits.push('apps/desktop/forge.config.ts 引用了 oracle/testkit');
}

const forbidden = [/golden-oracle/, /@coc-helper\/testkit/, /COCHELPER_SWIFT_ORACLE/];
for (const file of walk(path.join(root, 'apps/desktop/src'))) {
  if (!/\.(ts|tsx|js|mjs|cjs)$/.test(file)) {
    continue;
  }
  const text = readFileSync(file, 'utf8');
  for (const pattern of forbidden) {
    if (pattern.test(text)) {
      hits.push(`${path.relative(root, file)} → ${pattern}`);
    }
  }
}

if (hits.length > 0) {
  console.error('oracle isolation 失败：');
  for (const hit of hits) {
    console.error(`- ${hit}`);
  }
  process.exit(1);
}

console.log('oracle isolation ok：desktop 不依赖 testkit/oracle，forge 未打包 golden-oracle');
