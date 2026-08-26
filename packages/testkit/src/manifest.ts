import { readFileSync } from 'node:fs';

import { loadGoldenBytes } from './load-fixture';
import { fixtureFingerprint, isFixtureFingerprint } from './fingerprint';
import { goldenManifestPath } from './paths';

export const TEST_CATEGORIES = [
  'wire',
  'parser',
  'projection',
  'state-machine',
  'storage-fault',
  'api',
  'renderer',
  'e2e',
] as const;

export type TestCategory = (typeof TEST_CATEGORIES)[number];

export type FixturePortStatus = 'ported' | 'unported';

export type GoldenFixtureEntry = {
  readonly id: string;
  readonly category: TestCategory;
  readonly contract: string;
  readonly inputFiles: readonly string[];
  readonly outputFiles: readonly string[];
  readonly inputFingerprint: string;
  readonly outputFingerprint: string;
  readonly schemaVersion: number;
  readonly ownerIssue: number;
  readonly status: FixturePortStatus;
};

export type GoldenManifest = {
  readonly schemaVersion: number;
  readonly description: string;
  readonly fixtures: readonly GoldenFixtureEntry[];
};

const CATEGORY_SET = new Set<string>(TEST_CATEGORIES);

export function loadGoldenManifest(repoRoot?: string): GoldenManifest {
  const raw = JSON.parse(readFileSync(goldenManifestPath(repoRoot), 'utf8')) as GoldenManifest;
  if (raw.schemaVersion !== 1) {
    throw new Error(`golden manifest schemaVersion 必须为 1，实际 ${raw.schemaVersion}。`);
  }
  if (!Array.isArray(raw.fixtures) || raw.fixtures.length === 0) {
    throw new Error('golden manifest 必须包含 fixtures。');
  }
  const ids = new Set<string>();
  for (const fixture of raw.fixtures) {
    validateFixtureEntry(fixture);
    if (ids.has(fixture.id)) {
      throw new Error(`golden manifest 重复 id：${fixture.id}`);
    }
    ids.add(fixture.id);
  }
  return raw;
}

export function fingerprintGoldenFiles(files: readonly string[], repoRoot?: string): string {
  if (files.length === 0) {
    throw new Error('fingerprint 至少需要一个文件。');
  }
  const chunks = files.map((file) => loadGoldenBytes(file, repoRoot));
  const total = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0);
  const joined = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    joined.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return fixtureFingerprint(joined);
}

export function assertFixtureFingerprints(entry: GoldenFixtureEntry, repoRoot?: string): void {
  const input = fingerprintGoldenFiles(entry.inputFiles, repoRoot);
  const output = fingerprintGoldenFiles(entry.outputFiles, repoRoot);
  if (input !== entry.inputFingerprint) {
    throw new Error(
      `fixture ${entry.id} 输入 fingerprint 漂移：登记 ${entry.inputFingerprint}，实测 ${input}`,
    );
  }
  if (output !== entry.outputFingerprint) {
    throw new Error(
      `fixture ${entry.id} 输出 fingerprint 漂移：登记 ${entry.outputFingerprint}，实测 ${output}`,
    );
  }
}

function validateFixtureEntry(entry: GoldenFixtureEntry): void {
  if (typeof entry.id !== 'string' || entry.id.length === 0) {
    throw new Error('fixture id 不能为空。');
  }
  if (!CATEGORY_SET.has(entry.category)) {
    throw new Error(`fixture ${entry.id} 的 category 非法：${entry.category}`);
  }
  if (typeof entry.contract !== 'string' || entry.contract.length === 0) {
    throw new Error(`fixture ${entry.id} 缺少 contract。`);
  }
  if (!Array.isArray(entry.inputFiles) || entry.inputFiles.length === 0) {
    throw new Error(`fixture ${entry.id} 缺少 inputFiles。`);
  }
  if (!Array.isArray(entry.outputFiles) || entry.outputFiles.length === 0) {
    throw new Error(`fixture ${entry.id} 缺少 outputFiles。`);
  }
  if (
    !isFixtureFingerprint(entry.inputFingerprint) ||
    !isFixtureFingerprint(entry.outputFingerprint)
  ) {
    throw new Error(`fixture ${entry.id} 的 fingerprint 必须是 sha256: + 64 hex。`);
  }
  if (entry.schemaVersion !== 1) {
    throw new Error(`fixture ${entry.id} schemaVersion 必须为 1。`);
  }
  if (!Number.isSafeInteger(entry.ownerIssue) || entry.ownerIssue <= 0) {
    throw new Error(`fixture ${entry.id} ownerIssue 必须是正整数。`);
  }
  if (entry.status !== 'ported' && entry.status !== 'unported') {
    throw new Error(`fixture ${entry.id} status 必须是 ported 或 unported。`);
  }
}
