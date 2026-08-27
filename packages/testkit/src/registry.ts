import { readFileSync, realpathSync, statSync } from 'node:fs';
import path from 'node:path';

import { TEST_CATEGORIES, type TestCategory } from './manifest';
import { findRepoRoot, testRegistryPath } from './paths';

export type TestPortStatus = 'ported' | 'unported';

export type TestRegistryEntry = {
  readonly id: string;
  readonly swift: string;
  readonly category: TestCategory;
  readonly ownerIssue: number;
  readonly tsOwner: string | null;
  readonly status: TestPortStatus;
  readonly loadBearing: true;
};

export type TestRegistry = {
  readonly schemaVersion: number;
  readonly description: string;
  readonly tests: readonly TestRegistryEntry[];
};

const CATEGORY_SET = new Set<string>(TEST_CATEGORIES);

const IGNORED_OWNER_SEGMENTS = ['node_modules', '.webpack', 'out'];

export function loadTestRegistry(repoRoot?: string): TestRegistry {
  const root = repoRoot ?? findRepoRoot();
  const raw = JSON.parse(readFileSync(testRegistryPath(root), 'utf8')) as TestRegistry;
  if (raw.schemaVersion !== 1) {
    throw new Error(`test registry schemaVersion 必须为 1，实际 ${raw.schemaVersion}。`);
  }
  if (!Array.isArray(raw.tests) || raw.tests.length === 0) {
    throw new Error('test registry 必须包含 tests。');
  }
  const ids = new Set<string>();
  for (const entry of raw.tests) {
    validateRegistryEntry(entry, root);
    if (ids.has(entry.id)) {
      throw new Error(`test registry 重复 id：${entry.id}`);
    }
    ids.add(entry.id);
  }
  return raw;
}

/** 对齐 vitest.config.ts 的 include/exclude：ported tsOwner 必须是会被执行的测试文件。 */
export function isVitestExecutedOwner(relativePath: string): boolean {
  const posix = relativePath.split(path.sep).join('/');
  if (posix.startsWith('/') || posix.split('/').some((part) => part === '..' || part === '')) {
    return false;
  }
  if (IGNORED_OWNER_SEGMENTS.some((segment) => posix.split('/').includes(segment))) {
    return false;
  }
  if (posix.endsWith('.parity.test.ts')) {
    return posix.startsWith('packages/');
  }
  if (posix.endsWith('.replay.test.ts')) {
    return posix.startsWith('packages/');
  }
  if (posix.endsWith('.test.ts')) {
    return /^(?:apps|packages|scripts)\//.test(posix);
  }
  return false;
}

function validateRegistryEntry(entry: TestRegistryEntry, repoRoot: string): void {
  if (typeof entry.id !== 'string' || entry.id.length === 0) {
    throw new Error('registry id 不能为空。');
  }
  assertSwiftTestOwner(entry.id, entry.swift, repoRoot);
  if (!CATEGORY_SET.has(entry.category)) {
    throw new Error(`${entry.id} 的 category 非法：${entry.category}`);
  }
  if (!Number.isSafeInteger(entry.ownerIssue) || entry.ownerIssue <= 0) {
    throw new Error(`${entry.id} ownerIssue 必须是正整数。`);
  }
  if (entry.loadBearing !== true) {
    throw new Error(`${entry.id} 必须是 load-bearing 条目。`);
  }
  if (entry.status === 'ported') {
    if (typeof entry.tsOwner !== 'string' || entry.tsOwner.length === 0) {
      throw new Error(`${entry.id} 已 ported 但缺少 tsOwner。`);
    }
    assertExecutedTsOwner(entry.id, entry.tsOwner, repoRoot);
  } else if (entry.status === 'unported') {
    if (entry.tsOwner !== null) {
      throw new Error(`${entry.id} 未 port 时 tsOwner 必须为 null。`);
    }
  } else {
    throw new Error(`${entry.id} status 必须是 ported 或 unported。`);
  }
}

function assertSwiftTestOwner(id: string, swift: string, repoRoot: string): void {
  if (typeof swift !== 'string' || swift.length === 0 || path.isAbsolute(swift)) {
    throw new Error(`${id} 的 swift 路径必须位于 Tests/ 内。`);
  }
  const root = path.resolve(repoRoot);
  const testsRoot = path.resolve(root, 'Tests');
  const resolved = path.resolve(root, swift);
  const prefix = testsRoot.endsWith(path.sep) ? testsRoot : `${testsRoot}${path.sep}`;
  if (!resolved.startsWith(prefix)) {
    throw new Error(`${id} 的 swift 路径解析后必须位于 Tests/ 内：${swift}`);
  }
  let canonicalRoot: string;
  let canonicalTestsRoot: string;
  let canonicalFile: string;
  try {
    canonicalRoot = realpathSync(root);
    canonicalTestsRoot = realpathSync(testsRoot);
    canonicalFile = realpathSync(resolved);
  } catch {
    throw new Error(`${id} 的 swift 路径不是文件：${swift}`);
  }
  if (canonicalTestsRoot !== path.join(canonicalRoot, 'Tests')) {
    throw new Error(`${id} 的 swift 路径解析后必须位于 Tests/ 内：${swift}`);
  }
  const canonicalPrefix = canonicalTestsRoot.endsWith(path.sep)
    ? canonicalTestsRoot
    : `${canonicalTestsRoot}${path.sep}`;
  if (!canonicalFile.startsWith(canonicalPrefix)) {
    throw new Error(`${id} 的 swift 路径解析后必须位于 Tests/ 内：${swift}`);
  }
  if (path.extname(canonicalFile) !== '.swift' || !statSync(canonicalFile).isFile()) {
    throw new Error(`${id} 的 swift 路径必须指向 .swift 文件：${swift}`);
  }
}

function assertExecutedTsOwner(id: string, tsOwner: string, repoRoot: string): void {
  if (!isVitestExecutedOwner(tsOwner)) {
    throw new Error(`${id} 的 tsOwner 必须是 Vitest 会执行的测试文件，实际 ${tsOwner}`);
  }
  const root = path.resolve(repoRoot);
  const file = path.resolve(root, tsOwner);
  const prefix = root.endsWith(path.sep) ? root : `${root}${path.sep}`;
  if (file !== root && !file.startsWith(prefix)) {
    throw new Error(`${id} 的 tsOwner 逃出仓库：${tsOwner}`);
  }
  let canonicalRoot: string;
  let canonicalFile: string;
  try {
    canonicalRoot = realpathSync(root);
    canonicalFile = realpathSync(file);
  } catch {
    throw new Error(`${id} 的 tsOwner 不是文件：${tsOwner}`);
  }
  const canonicalPrefix = canonicalRoot.endsWith(path.sep)
    ? canonicalRoot
    : `${canonicalRoot}${path.sep}`;
  if (canonicalFile !== canonicalRoot && !canonicalFile.startsWith(canonicalPrefix)) {
    throw new Error(`${id} 的 tsOwner 解析后逃出仓库：${tsOwner}`);
  }
  if (canonicalFile !== file) {
    throw new Error(`${id} 的 tsOwner 不得是 symlink：${tsOwner}`);
  }
  const canonicalRelative = path.relative(canonicalRoot, canonicalFile).split(path.sep).join('/');
  if (!isVitestExecutedOwner(canonicalRelative)) {
    throw new Error(`${id} 的 tsOwner 解析后不是 Vitest 会执行的测试文件：${tsOwner}`);
  }
  if (!statSync(canonicalFile).isFile()) {
    throw new Error(`${id} 的 tsOwner 不是文件：${tsOwner}`);
  }
}
