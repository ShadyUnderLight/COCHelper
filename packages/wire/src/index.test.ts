import { describe, expect, it } from 'vitest';

import * as wire from './index';

describe('@coc-helper/wire 导出面', () => {
  it('导出 lossless JSON / canonical / SHA-256 / 时间 / UUID 原语', () => {
    expect(typeof wire.parseJson).toBe('function');
    expect(typeof wire.canonicalBytes).toBe('function');
    expect(typeof wire.sha256Fingerprint).toBe('function');
    expect(typeof wire.unixSecondsToRefSeconds).toBe('function');
    expect(typeof wire.parseUuid).toBe('function');
    expect(typeof wire.parseCatalogDataIdKey).toBe('function');
    expect(wire.schemaVersions.snapshotHistory.observation).toBe(6);
  });
});
