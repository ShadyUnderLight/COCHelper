#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { existsSync, readdirSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const outDir = path.join(root, 'apps/desktop/out');

function findBinary(dir) {
  if (!existsSync(dir)) {
    return null;
  }
  const entries = readdirSync(dir);
  for (const entry of entries) {
    const full = path.join(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) {
      if (entry.endsWith('.app')) {
        const binary = path.join(full, 'Contents/MacOS/COCHelper');
        if (existsSync(binary)) {
          return binary;
        }
      }
      const nested = findBinary(full);
      if (nested !== null) {
        return nested;
      }
    } else if (entry === 'COCHelper' && (st.mode & 0o111) !== 0) {
      return full;
    }
  }
  return null;
}

const binary = findBinary(outDir);
if (binary === null) {
  console.error('未找到 packaged app。请先运行 pnpm package。');
  process.exit(1);
}

const child = spawn(binary, ['--smoke'], {
  env: {
    ...process.env,
    COCHELPER_SMOKE: '1',
    ELECTRON_ENABLE_LOGGING: '1',
  },
  stdio: ['ignore', 'pipe', 'pipe'],
});

let stdout = '';
let stderr = '';
child.stdout.on('data', (chunk) => {
  const text = chunk.toString();
  stdout += text;
  process.stdout.write(text);
});
child.stderr.on('data', (chunk) => {
  const text = chunk.toString();
  stderr += text;
  process.stderr.write(text);
});

const timeout = setTimeout(() => {
  child.kill('SIGKILL');
}, 45_000);

child.on('close', (code) => {
  clearTimeout(timeout);
  if (code === 0 && stdout.includes('COCHELPER_SMOKE_OK')) {
    process.exit(0);
  }
  console.error('packaged smoke 失败');
  if (!stdout.includes('COCHELPER_SMOKE_OK')) {
    console.error('未看到 COCHELPER_SMOKE_OK');
  }
  if (stderr.length > 0) {
    console.error(stderr);
  }
  process.exit(code === null ? 1 : code);
});
