import { readFileSync } from 'node:fs';

import { TEST_CATEGORIES, type TestCategory } from './manifest';
import { testRegistryPath } from './paths';

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

export function loadTestRegistry(repoRoot?: string): TestRegistry {
  const raw = JSON.parse(readFileSync(testRegistryPath(repoRoot), 'utf8')) as TestRegistry;
  if (raw.schemaVersion !== 1) {
    throw new Error(`test registry schemaVersion 必须为 1，实际 ${raw.schemaVersion}。`);
  }
  if (!Array.isArray(raw.tests) || raw.tests.length === 0) {
    throw new Error('test registry 必须包含 tests。');
  }
  const ids = new Set<string>();
  for (const entry of raw.tests) {
    validateRegistryEntry(entry);
    if (ids.has(entry.id)) {
      throw new Error(`test registry 重复 id：${entry.id}`);
    }
    ids.add(entry.id);
  }
  return raw;
}

function validateRegistryEntry(entry: TestRegistryEntry): void {
  if (typeof entry.id !== 'string' || entry.id.length === 0) {
    throw new Error('registry id 不能为空。');
  }
  if (typeof entry.swift !== 'string' || !entry.swift.startsWith('Tests/')) {
    throw new Error(`${entry.id} 的 swift 路径必须位于 Tests/。`);
  }
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
  } else if (entry.status === 'unported') {
    if (entry.tsOwner !== null) {
      throw new Error(`${entry.id} 未 port 时 tsOwner 必须为 null。`);
    }
  } else {
    throw new Error(`${entry.id} status 必须是 ported 或 unported。`);
  }
}
