import { readFileSync } from 'node:fs';
import { isAbsolute, relative, resolve, sep } from 'node:path';

import { isSha256Fingerprint, sha256Fingerprint, type Sha256Fingerprint } from '@coc-helper/wire';

export const PARITY_CATEGORIES = [
  'fixture',
  'wire',
  'parser',
  'projection',
  'error',
  'ordering',
  'time',
] as const;

export type ParityCategory = (typeof PARITY_CATEGORIES)[number];

export type GoldenCase = {
  readonly id: string;
  readonly category: ParityCategory;
  readonly operation: 'canonical-json';
  readonly fixture: string;
  readonly fixtureSha256: Sha256Fingerprint;
  readonly swiftOwner: string;
  readonly typescriptOwner: string;
};

export type GoldenManifest = {
  readonly protocolVersion: 1;
  readonly fixtureVersion: string;
  readonly cases: readonly GoldenCase[];
};

export function loadGoldenManifest(root = process.cwd()): GoldenManifest {
  const manifestPath = resolve(root, 'Tests/Golden/manifest.json');
  return parseGoldenManifest(JSON.parse(readFileSync(manifestPath, 'utf8')) as unknown);
}

export function parseGoldenManifest(value: unknown): GoldenManifest {
  const object = asRecord(value, 'manifest');
  if (object.protocolVersion !== 1) {
    throw new Error('golden manifest protocolVersion 必须为 1。');
  }
  const fixtureVersion = requireString(object.fixtureVersion, 'manifest.fixtureVersion');
  if (!Array.isArray(object.cases) || object.cases.length === 0) {
    throw new Error('golden manifest.cases 不能为空。');
  }

  const ids = new Set<string>();
  const cases = object.cases.map((item, index) => {
    const entry = parseGoldenCase(item, `manifest.cases[${index}]`);
    if (!ids.add(entry.id)) {
      throw new Error(`golden manifest 存在重复 case id：${entry.id}`);
    }
    return entry;
  });

  return { protocolVersion: 1, fixtureVersion, cases };
}

export function fixturePath(root: string, entry: GoldenCase): string {
  if (isAbsolute(entry.fixture)) {
    throw new Error(`fixture 路径必须是相对路径：${entry.id}`);
  }
  const absolute = resolve(root, entry.fixture);
  const relativePath = relative(root, absolute);
  if (
    relativePath === '' ||
    relativePath === '..' ||
    relativePath.startsWith(`..${sep}`) ||
    isAbsolute(relativePath)
  ) {
    throw new Error(`fixture 路径必须位于仓库根目录内：${entry.id}`);
  }
  return absolute;
}

export function readGoldenFixture(root: string, entry: GoldenCase): unknown {
  const path = fixturePath(root, entry);
  const data = readFileSync(path);
  const actual = sha256Fingerprint(data);
  if (actual !== entry.fixtureSha256) {
    throw new Error(`fixture fingerprint 不匹配：${entry.id}`);
  }
  return JSON.parse(data.toString('utf8')) as unknown;
}

function parseGoldenCase(value: unknown, label: string): GoldenCase {
  const object = asRecord(value, label);
  const category = requireString(object.category, `${label}.category`);
  if (!(PARITY_CATEGORIES as readonly string[]).includes(category)) {
    throw new Error(`${label}.category 不受支持。`);
  }
  if (object.operation !== 'canonical-json') {
    throw new Error(`${label}.operation 必须为 canonical-json。`);
  }
  const fixtureSha256 = requireString(object.fixtureSha256, `${label}.fixtureSha256`);
  if (!isSha256Fingerprint(fixtureSha256)) {
    throw new Error(`${label}.fixtureSha256 不是合法 SHA-256 fingerprint。`);
  }
  return {
    id: requireString(object.id, `${label}.id`),
    category: category as ParityCategory,
    operation: 'canonical-json',
    fixture: requireString(object.fixture, `${label}.fixture`),
    fixtureSha256,
    swiftOwner: requireString(object.swiftOwner, `${label}.swiftOwner`),
    typescriptOwner: requireString(object.typescriptOwner, `${label}.typescriptOwner`),
  };
}

function asRecord(value: unknown, label: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new Error(`${label} 必须是对象。`);
  }
  return value as Record<string, unknown>;
}

function requireString(value: unknown, label: string): string {
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(`${label} 必须是非空字符串。`);
  }
  return value;
}
