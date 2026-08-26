import { describe, expect, it } from 'vitest';

import { parserVersions, schemaVersions } from './schema-versions';

describe('schemaVersion / parserVersion 注册表（WA-7）', () => {
  it('冻结当前 schema 常量', () => {
    expect(schemaVersions.villageStore.current).toBe(1);
    expect(schemaVersions.snapshotHistory).toMatchObject({
      envelope: 1,
      entry: 1,
      observation: 6,
      fingerprint: 1,
      integrity: 1,
    });
    expect(schemaVersions.manualTracker).toEqual({ envelope: 1, store: 1, village: 1 });
    expect(schemaVersions.gameCatalogManifest).toEqual({ min: 1, max: 2 });
  });

  it('冻结当前 parserVersion 字符串', () => {
    expect(parserVersions.accountSnapshot).toBe('account-json-0.1');
    expect(parserVersions.playerSnapshot).toBe('player-snapshot-0.2');
    expect(parserVersions.clanSnapshot).toBe('clan-snapshot-0.4');
    expect(parserVersions.clanWar).toBe('clan-war-0.3');
    expect(parserVersions.clanWarLog).toBe('clan-war-log-0.4');
    expect(parserVersions.clanCapital).toBe('clan-capital-0.3');
  });
});
