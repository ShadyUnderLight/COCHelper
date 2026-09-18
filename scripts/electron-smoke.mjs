#!/usr/bin/env node
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { resolvePackagedBinary } from './electron-package.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
let binary;
try {
  binary = resolvePackagedBinary(root);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}

process.stdout.write(`packaged smoke binary: ${binary}\n`);

// Linux CI 上 forge 产物的 chrome-sandbox 通常无 root/SUID；smoke 仅验证进程拉起，
// 使用 --no-sandbox，避免 SUID helper 误配置直接 abort（与业务沙箱策略无关）。
const smokeArgs = process.platform === 'linux' ? ['--smoke', '--no-sandbox'] : ['--smoke'];
const child = spawn(binary, smokeArgs, {
  env: {
    ...process.env,
    COCHELPER_SMOKE: '1',
    ELECTRON_ENABLE_LOGGING: '1',
    ...(process.platform === 'linux' ? { ELECTRON_DISABLE_SANDBOX: '1' } : {}),
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
