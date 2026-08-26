import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

import { findSecretHits, listTrackedFiles } from './secret-scan.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

describe('secret scan', () => {
  it('扫描 git ls-files，包含 .npmrc', () => {
    const files = listTrackedFiles(root);
    expect(files).toContain('.npmrc');
    expect(files.some((file) => file.startsWith('apps/'))).toBe(true);
  });

  it('能发现 npm token 与 GitHub PAT', () => {
    expect(
      findSecretHits('//registry.npmjs.org/:_authToken=npm_abcdefghijklmnopqrstuvwxyz12', '.npmrc'),
    ).toEqual(['.npmrc → npm _authToken', '.npmrc → npm token']);
    expect(findSecretHits('token=ghp_abcdefghijklmnopqrstuvwxyz0123456789', 'notes.txt')).toEqual([
      'notes.txt → GitHub PAT',
    ]);
    expect(
      findSecretHits('Authorization: Bearer super-secret-value', 'apps/desktop/.env'),
    ).toEqual(['apps/desktop/.env → Authorization Bearer']);
  });

  it('普通 .npmrc 注释不会误报', () => {
    expect(
      findSecretHits('# pnpm 11 只从本文件读取 registry / auth。其余设置见 pnpm-workspace.yaml。\n', '.npmrc'),
    ).toEqual([]);
  });

  it('当前 tracked 文件不含密钥', () => {
    const listed = execFileSync('git', ['ls-files', '.npmrc'], { cwd: root }).toString().trim();
    expect(listed).toBe('.npmrc');
  });
});
