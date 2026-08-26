#!/usr/bin/env node
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { scanTrackedFiles } from './secret-scan.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const hits = scanTrackedFiles(root);

if (hits.length > 0) {
  console.error('敏感信息扫描失败:');
  for (const hit of hits) {
    console.error(`- ${hit}`);
  }
  process.exit(1);
}

console.log('敏感信息扫描通过');
