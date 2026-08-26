#!/usr/bin/env node
import { readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const skipDir = new Set([
  'node_modules',
  '.git',
  '.webpack',
  'out',
  '.build',
  '.swiftpm',
  'Sources',
  'Tests',
  'Tools',
  'docs',
  'Resources',
]);

const patterns = [
  { re: /-----BEGIN [A-Z ]*PRIVATE KEY-----/, message: '私钥块' },
  { re: /Authorization:\s*Bearer\s+\S+/i, message: 'Authorization Bearer' },
  { re: /eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}/, message: 'JWT' },
];

function walk(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    if (skipDir.has(entry) || entry.startsWith('.')) {
      continue;
    }
    const full = path.join(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) {
      out.push(...walk(full));
    } else if (st.isFile()) {
      out.push(full);
    }
  }
  return out;
}

const files = [
  ...walk(path.join(root, 'apps')),
  ...walk(path.join(root, 'packages')),
  ...walk(path.join(root, 'scripts')),
];

const hits = [];
for (const file of files) {
  if (!/\.(ts|js|mjs|cjs|json|yml|yaml|md|html)$/.test(file)) {
    continue;
  }
  const text = readFileSync(file, 'utf8');
  for (const pattern of patterns) {
    if (pattern.re.test(text)) {
      hits.push(`${path.relative(root, file)} → ${pattern.message}`);
    }
  }
}

if (hits.length > 0) {
  console.error('敏感信息扫描失败:');
  for (const hit of hits) {
    console.error(`- ${hit}`);
  }
  process.exit(1);
}

console.log('敏感信息扫描通过');
