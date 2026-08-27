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

/** 明确的时间字段；不用 /i + At$ 去匹配 format/stat。 */
const TIME_KEYS = new Set([
  'timestamp',
  'ageSeconds',
  'utcMs',
  'epoch',
  'appliedAt',
  'capturedAt',
  'importedAt',
  'fetchedAt',
  'startedAt',
  'completedAt',
  'recordedAt',
  'lastSeenAt',
  'lastAppliedAt',
  'sourceTimestamp',
  'createdAt',
  'updatedAt',
  'stateUpdatedAt',
]);

/** 对象上不存在的字段；与显式 undefined 区分。 */
const MISSING = Symbol('missing');

/** 只覆盖错误协议字段；kind/code/reason/message 是普通 discriminator，走 defaultKind。 */
const ERROR_KEYS = new Set(['failureKind', 'lastErrorReason']);

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

  if (expected instanceof Date || actual instanceof Date) {
    if (
      !(expected instanceof Date) ||
      !(actual instanceof Date) ||
      expected.getTime() !== actual.getTime()
    ) {
      diffs.push(diff(classifyPath(path, defaultKind), path, expected, actual));
    }
    return;
  }

  if (isPlainObject(expected) && isPlainObject(actual)) {
    if (sameContent(expected, actual) && !sameOrder(expected, actual)) {
      diffs.push(diff('ordering', path, expected, actual));
      return;
    }
    const keys = uniqueSorted([...Object.keys(expected), ...Object.keys(actual)]);
    for (const key of keys) {
      const expectedHas = hasOwn(expected, key);
      const actualHas = hasOwn(actual, key);
      const childPath = joinPath(path, key);
      if (!expectedHas || !actualHas) {
        diffs.push(
          diff(
            classifyPath(childPath, defaultKind),
            childPath,
            expectedHas ? expected[key] : MISSING,
            actualHas ? actual[key] : MISSING,
          ),
        );
        continue;
      }
      walk(expected[key], actual[key], childPath, defaultKind, diffs);
    }
    return;
  }

  if (Array.isArray(expected) && Array.isArray(actual)) {
    if (sameContent(expected, actual) && !sameOrder(expected, actual)) {
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
  if (TIME_KEYS.has(leaf) || /(?:Time|Timestamp|At)$/.test(leaf)) {
    return 'time';
  }
  if (ERROR_KEYS.has(leaf)) {
    return 'error';
  }
  return defaultKind;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    return false;
  }
  const proto = Object.getPrototypeOf(value);
  return proto === Object.prototype || proto === null;
}

function hasOwn(value: Record<string, unknown>, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(value, key);
}

function sameContent(left: unknown, right: unknown): boolean {
  return encode(canonicalize(left)) === encode(canonicalize(right));
}

function sameOrder(left: unknown, right: unknown): boolean {
  return encode(preserveOrder(left)) === encode(preserveOrder(right));
}

/** 带 type tag 的稳定编码；object 用 entries，避免 `__proto__` 被当成 setter。 */
function canonicalize(value: unknown): unknown {
  return tag(value, { sortKeys: true, sortArray: true });
}

function preserveOrder(value: unknown): unknown {
  return tag(value, { sortKeys: false, sortArray: false });
}

function tag(
  value: unknown,
  options: { readonly sortKeys: boolean; readonly sortArray: boolean },
): unknown {
  if (value === null) {
    return ['null'];
  }
  if (typeof value === 'undefined') {
    return ['undefined'];
  }
  if (typeof value === 'boolean') {
    return ['boolean', value];
  }
  if (typeof value === 'number') {
    return ['number', Object.is(value, -0) ? '-0' : String(value)];
  }
  if (typeof value === 'string') {
    return ['string', value];
  }
  if (typeof value === 'bigint') {
    return ['bigint', value.toString()];
  }
  if (value instanceof Date) {
    return ['date', String(value.getTime())];
  }
  if (Array.isArray(value)) {
    const items = value.map((item) => tag(item, options));
    if (options.sortArray) {
      items.sort(compareEncoded);
    }
    return ['array', items];
  }
  if (isPlainObject(value)) {
    const keys = Object.keys(value);
    if (options.sortKeys) {
      keys.sort();
    }
    return ['object', keys.map((key) => [key, tag(value[key], options)])];
  }
  return [typeof value, String(value)];
}

function encode(value: unknown): string {
  return JSON.stringify(value);
}

function compareEncoded(left: unknown, right: unknown): number {
  const a = encode(left);
  const b = encode(right);
  if (a === b) {
    return 0;
  }
  return a < b ? -1 : 1;
}

function uniqueSorted(values: readonly string[]): string[] {
  return [...new Set(values)].sort();
}

function joinPath(parent: string, key: string): string {
  return parent === '$' ? `$.${key}` : `${parent}.${key}`;
}

function dump(value: unknown): string {
  const text = stringifyForDump(value);
  return text.length > 240 ? `${text.slice(0, 239)}…` : text;
}

function stringifyForDump(value: unknown): string {
  if (value === MISSING) {
    return '<missing>';
  }
  if (typeof value === 'bigint') {
    return `${value}n`;
  }
  if (typeof value === 'string') {
    return value;
  }
  if (value === undefined) {
    return 'undefined';
  }
  if (value instanceof Date) {
    return value.toISOString();
  }
  return JSON.stringify(jsonReady(value));
}

function jsonReady(value: unknown): unknown {
  if (typeof value === 'bigint') {
    return `${value}n`;
  }
  if (Array.isArray(value)) {
    return value.map(jsonReady);
  }
  if (isPlainObject(value)) {
    const out = Object.create(null) as Record<string, unknown>;
    for (const key of Object.keys(value)) {
      out[key] = jsonReady(value[key]);
    }
    return out;
  }
  return value;
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
