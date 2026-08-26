export type ParityDiffKind = 'wire' | 'projection' | 'error' | 'ordering' | 'time';

export type ParityDiff = {
  readonly kind: ParityDiffKind;
  readonly path: string;
  readonly expected: string;
  readonly actual: string;
};

export type CompareParityOptions = {
  readonly expected: unknown;
  readonly actual: unknown;
  readonly path?: string;
  readonly defaultKind?: ParityDiffKind;
};

const TIME_KEY =
  /(?:Time|Timestamp|At)$|^(?:timestamp|ageSeconds|utcMs|epoch|appliedAt|capturedAt|importedAt|fetchedAt|startedAt|completedAt|recordedAt|lastSeenAt|lastAppliedAt|sourceTimestamp)$/i;
const ERROR_KEY =
  /^(?:failureKind|error|errors|diagnostic|diagnostics|message|code|kind|reason|lastErrorReason)$/i;
const HEX_STRING = /^[0-9a-f]{8,}$/;

export class ParityMismatchError extends Error {
  readonly diffs: readonly ParityDiff[];

  constructor(diffs: readonly ParityDiff[]) {
    super(formatDiffs(diffs));
    this.name = 'ParityMismatchError';
    this.diffs = diffs;
  }
}

/** 比较 Swift 参考输出与 TypeScript 实际输出；失败时按层分类。 */
export function compareParity(options: CompareParityOptions): void {
  const diffs: ParityDiff[] = [];
  walk(options.expected, options.actual, options.path ?? '$', options.defaultKind ?? 'wire', diffs);
  if (diffs.length > 0) {
    throw new ParityMismatchError(diffs);
  }
}

function walk(
  expected: unknown,
  actual: unknown,
  path: string,
  defaultKind: ParityDiffKind,
  diffs: ParityDiff[],
): void {
  if (Object.is(expected, actual)) {
    return;
  }

  if (isHexString(expected) && isHexString(actual) && expected !== actual) {
    diffs.push(diff('wire', path, expected, actual));
    return;
  }

  if (isPlainObject(expected) && isPlainObject(actual)) {
    if (sameNormalizedContent(expected, actual) && stringify(expected) !== stringify(actual)) {
      diffs.push(diff('ordering', path, expected, actual));
      return;
    }
    const keys = uniqueSorted([...Object.keys(expected), ...Object.keys(actual)]);
    for (const key of keys) {
      walk(expected[key], actual[key], joinPath(path, key), defaultKind, diffs);
    }
    return;
  }

  if (Array.isArray(expected) && Array.isArray(actual)) {
    if (arrayMultisetEqual(expected, actual) && stringify(expected) !== stringify(actual)) {
      diffs.push(diff('ordering', path, expected, actual));
      return;
    }
    const length = Math.max(expected.length, actual.length);
    for (let index = 0; index < length; index += 1) {
      walk(expected[index], actual[index], `${path}[${index}]`, defaultKind, diffs);
    }
    return;
  }

  diffs.push(diff(classifyPath(path, defaultKind), path, expected, actual));
}

function classifyPath(path: string, defaultKind: ParityDiffKind): ParityDiffKind {
  const leaf =
    path
      .split('.')
      .pop()
      ?.replace(/\[\d+\]/g, '') ?? '';
  if (TIME_KEY.test(leaf)) {
    return 'time';
  }
  if (ERROR_KEY.test(leaf)) {
    return 'error';
  }
  return defaultKind;
}

function isHexString(value: unknown): value is string {
  return typeof value === 'string' && HEX_STRING.test(value);
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function arrayMultisetEqual(left: readonly unknown[], right: readonly unknown[]): boolean {
  if (left.length !== right.length) {
    return false;
  }
  const keysLeft = left.map((item) => stringify(normalize(item))).sort();
  const keysRight = right.map((item) => stringify(normalize(item))).sort();
  return keysLeft.every((key, index) => key === keysRight[index]);
}

function sameNormalizedContent(left: unknown, right: unknown): boolean {
  return stringify(normalize(left)) === stringify(normalize(right));
}

function normalize(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(normalize);
  }
  if (isPlainObject(value)) {
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(value).sort()) {
      out[key] = normalize(value[key]);
    }
    return out;
  }
  if (typeof value === 'bigint') {
    return value.toString();
  }
  return value;
}

function uniqueSorted(values: readonly string[]): string[] {
  return [...new Set(values)].sort();
}

function joinPath(parent: string, key: string): string {
  return parent === '$' ? `$.${key}` : `${parent}.${key}`;
}

function stringify(value: unknown): string {
  if (typeof value === 'bigint') {
    return value.toString();
  }
  if (typeof value === 'string') {
    return value;
  }
  if (value === undefined) {
    return 'undefined';
  }
  return JSON.stringify(value);
}

function dump(value: unknown): string {
  const text = stringify(value);
  return text.length > 240 ? `${text.slice(0, 239)}…` : text;
}

function diff(kind: ParityDiffKind, path: string, expected: unknown, actual: unknown): ParityDiff {
  return {
    kind,
    path,
    expected: dump(expected),
    actual: dump(actual),
  };
}

function formatDiffs(diffs: readonly ParityDiff[]): string {
  return diffs
    .map(
      (item) =>
        `parity 失败：${item.kind} @ ${item.path} expected=${item.expected} actual=${item.actual}`,
    )
    .join('\n');
}
