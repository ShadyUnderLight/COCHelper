import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { decodeOfficialCapitalRaidPageJson } from './capital-raid';
import { decodeOfficialClanSnapshotJson } from './clan';
import { decodeOfficialClanWarSnapshotJson } from './clan-war';
import { decodeOfficialPlayerSnapshotJson } from './player';
import { decodeOfficialWarLogPageJson } from './war-log';
import { describe, expect, it } from 'vitest';

const ROOT = process.cwd();

function fixture(name: string): string {
  return readFileSync(resolve(ROOT, 'Tests/COCHelperCoreTests/Fixtures', name), 'utf8');
}

describe('official decode fixtures', () => {
  it('official_player_full.json', () => {
    const snapshot = decodeOfficialPlayerSnapshotJson(fixture('official_player_full.json'));
    expect(snapshot.tag).toBe('#ANONYMIZED');
    expect(snapshot.heroes?.length).toBeGreaterThan(0);
  });

  it('official_clan_minimal.json', () => {
    const snapshot = decodeOfficialClanSnapshotJson(fixture('official_clan_minimal.json'));
    expect(snapshot.tag).toBe('#MINIMALCLAN');
    expect(snapshot.unrecognizedKeys).toEqual([]);
  });

  it('official_clan_war_ended.json', () => {
    const snapshot = decodeOfficialClanWarSnapshotJson(fixture('official_clan_war_ended.json'));
    expect(snapshot.state).toBe('warEnded');
    expect(snapshot.warStartTime).toBeDefined();
  });

  it('official_war_log_page.json 成员明细', () => {
    const page = decodeOfficialWarLogPageJson(fixture('official_war_log_page.json'));
    const members = page.page.items[0]?.clan?.members;
    expect(members).toHaveLength(1);
    expect(members?.[0]?.townhallLevel).toBe(14);
  });

  it('official_capital_raid_page.json', () => {
    const page = decodeOfficialCapitalRaidPageJson(fixture('official_capital_raid_page.json'));
    expect(page.page.items[0]?.totalAttacks).toBe(60);
    expect(page.unrecognizedKeys).toEqual([]);
  });

  it('缺失 items 必须失败', () => {
    expect(() => decodeOfficialWarLogPageJson('{}')).toThrow();
  });
});
