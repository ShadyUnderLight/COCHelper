#!/usr/bin/env node
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const forbiddenSource = [
  { re: /\bfrom\s+['"]electron['"]/, message: 'import electron' },
  { re: /\bfrom\s+['"]node:/, message: 'import node:' },
  { re: /\brequire\s*\(/, message: 'require(' },
  { re: /\bipcRenderer\b/, message: 'ipcRenderer' },
  { re: /\bprocess\.versions\b/, message: 'process.versions' },
];

const forbiddenBundle = [
  { re: /require\(['"]electron['"]\)/, message: 'require("electron")' },
  { re: /require\(['"]fs['"]\)/, message: 'require("fs")' },
  { re: /require\(['"]child_process['"]\)/, message: 'require("child_process")' },
];

const hardening = [
  { re: /nodeIntegration\s*:\s*true/, message: 'nodeIntegration: true' },
  { re: /contextIsolation\s*:\s*false/, message: 'contextIsolation: false' },
  { re: /sandbox\s*:\s*false/, message: 'sandbox: false' },
  { re: /webSecurity\s*:\s*false/, message: 'webSecurity: false' },
];

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

function scan(files, patterns, label) {
  const hits = [];
  for (const file of files) {
    if (!/\.(ts|js|mjs|cjs|tsx)$/.test(file)) {
      continue;
    }
    const text = readFileSync(file, 'utf8');
    for (const pattern of patterns) {
      if (pattern.re.test(text)) {
        hits.push(`${label}: ${path.relative(root, file)} → ${pattern.message}`);
      }
    }
  }
  return hits;
}

function isRendererPageBundle(file) {
  const normalized = file.split(path.sep).join('/');
  return (
    normalized.includes('/renderer/') &&
    normalized.endsWith('.js') &&
    !normalized.endsWith('.map') &&
    !normalized.endsWith('/preload.js')
  );
}

const rendererSource = walk(path.join(root, 'apps/desktop/src/renderer'));
const desktopSource = [
  ...walk(path.join(root, 'apps/desktop/src/main')),
  ...walk(path.join(root, 'apps/desktop/src/preload')),
];
const rendererBundle = walk(path.join(root, 'apps/desktop/.webpack')).filter(isRendererPageBundle);
const preloadSource = readFileSync(path.join(root, 'apps/desktop/src/preload/index.ts'), 'utf8');

const hits = [
  ...scan(rendererSource, forbiddenSource, 'renderer source'),
  ...scan(rendererBundle, forbiddenBundle, 'renderer bundle'),
  ...scan(desktopSource, hardening, 'desktop source'),
];

if (/\bexposeInMainWorld\b[\s\S]*\bipcRenderer\b/.test(preloadSource)) {
  hits.push('preload: contextBridge 不得暴露 ipcRenderer');
}

if (hits.length > 0) {
  console.error('renderer / 安全边界静态检查失败:');
  for (const hit of hits) {
    console.error(`- ${hit}`);
  }
  process.exit(1);
}

console.log('renderer / 安全边界静态检查通过');
