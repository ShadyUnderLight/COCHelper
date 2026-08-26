import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

import { findSecretHits, listTrackedFiles, scanFileBuffer, scanTrackedFiles } from './secret-scan.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

describe('secret scan', () => {
  it('扫描 git ls-files，包含 .npmrc', () => {
    const files = listTrackedFiles(root);
    expect(files).toContain('.npmrc');
    expect(files.some((file) => file.startsWith('apps/'))).toBe(true);
  });

  it('能发现 npm token 与 GitHub PAT', () => {
    const npmToken = ['npm_', 'a'.repeat(24)].join('');
    const authTokenKey = ['_auth', 'Token'].join('');
    const npmrc = `//registry.npmjs.org/:${authTokenKey}=${npmToken}`;
    const githubPat = ['ghp_', 'a'.repeat(36)].join('');
    const bearer = ['Authorization', ': ', 'Bearer', ' ', 'super-secret-value'].join('');

    expect(findSecretHits(npmrc, '.npmrc')).toEqual([
      '.npmrc → npm _authToken',
      '.npmrc → npm token',
    ]);
    expect(findSecretHits(`token=${githubPat}`, 'notes.txt')).toEqual(['notes.txt → GitHub PAT']);
    expect(findSecretHits(bearer, 'apps/desktop/.env')).toEqual([
      'apps/desktop/.env → Authorization Bearer',
    ]);
  });

  it('普通 .npmrc 注释不会误报', () => {
    expect(
      findSecretHits(
        '# pnpm 11 只从本文件读取 registry / auth。其余设置见 pnpm-workspace.yaml。\n',
        '.npmrc',
      ),
    ).toEqual([]);
  });

  it('NUL 不能绕过密钥扫描', () => {
    const githubPat = ['ghp_', 'a'.repeat(36)].join('');
    const prefixed = ['\u0000', githubPat].join('');
    const suffixed = [githubPat, '\u0000'].join('');
    expect(findSecretHits(prefixed, 'notes.txt')).toEqual(['notes.txt → GitHub PAT']);
    expect(scanFileBuffer(Buffer.from(suffixed, 'utf8'), 'notes.txt')).toEqual([
      'notes.txt → GitHub PAT',
    ]);
  });

  it('当前 tracked 文件不含密钥', () => {
    expect(scanTrackedFiles(root)).toEqual([]);
  });
});
