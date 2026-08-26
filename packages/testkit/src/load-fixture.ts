import { readFileSync } from 'node:fs';
import path from 'node:path';

import { findRepoRoot, goldenFixturesRoot } from './paths';
import { assertGoldenPayloadSafe } from './secrets';

/** 只允许读取 `Tests/Golden/Fixtures/` 下的相对路径，拒绝绝对路径与 `..`。 */
export function resolveGoldenFixture(relativeName: string, repoRoot = findRepoRoot()): string {
  if (relativeName.includes('\0')) {
    throw new Error('golden 路径不得包含 NUL。');
  }
  const normalized = relativeName.replaceAll('\\', '/');
  if (path.isAbsolute(normalized) || normalized.startsWith('/')) {
    throw new Error(`禁止绝对 golden 路径：${relativeName}`);
  }
  const parts = normalized.split('/');
  if (parts.some((part) => part.length === 0 || part === '.' || part === '..')) {
    throw new Error(`非法 golden 相对路径：${relativeName}`);
  }
  const fixturesRoot = path.resolve(goldenFixturesRoot(repoRoot));
  const resolved = path.resolve(fixturesRoot, ...parts);
  const prefix = fixturesRoot.endsWith(path.sep) ? fixturesRoot : `${fixturesRoot}${path.sep}`;
  if (resolved !== fixturesRoot && !resolved.startsWith(prefix)) {
    throw new Error(`golden 路径逃出 Fixtures 目录：${relativeName}`);
  }
  return resolved;
}

export function loadGoldenBytes(relativeName: string, repoRoot = findRepoRoot()): Uint8Array {
  const absolute = resolveGoldenFixture(relativeName, repoRoot);
  const bytes = new Uint8Array(readFileSync(absolute));
  const text = new TextDecoder('utf-8', { fatal: false }).decode(bytes);
  assertGoldenPayloadSafe(text, relativeName);
  return bytes;
}

export function loadGoldenText(relativeName: string, repoRoot = findRepoRoot()): string {
  return new TextDecoder('utf-8', { fatal: true }).decode(loadGoldenBytes(relativeName, repoRoot));
}

export function loadGoldenJson<T>(relativeName: string, repoRoot = findRepoRoot()): T {
  return JSON.parse(loadGoldenText(relativeName, repoRoot)) as T;
}
