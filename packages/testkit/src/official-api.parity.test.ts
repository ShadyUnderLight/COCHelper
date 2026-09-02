import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import {
  decodeOfficialCapitalRaidPageJson,
  decodeOfficialClanSnapshotJson,
  decodeOfficialClanWarSnapshotJson,
  decodeOfficialPlayerSnapshotJson,
  decodeOfficialWarLogPageJson,
} from '@coc-helper/domain';
import { describe, expect, it } from 'vitest';

const ROOT = process.cwd();

function fixture(name: string): string {
  return readFileSync(resolve(ROOT, 'Tests/COCHelperCoreTests/Fixtures', name), 'utf8');
}

describe('official api parity harness', () => {
  it('player fixture 关键字段', () => {
    const snapshot = decodeOfficialPlayerSnapshotJson(fixture('official_player_full.json'));
    expect(snapshot.tag).toBe('#ANONYMIZED');
    expect(snapshot.townHallLevel).toBe(14);
    expect(snapshot.clan?.tag).toBe('#CLANANON');
  });

  it('clan fixture 关键字段', () => {
    const snapshot = decodeOfficialClanSnapshotJson(fixture('official_clan_full.json'));
    expect(snapshot.tag).toBe('#CLANANONYMIZED');
    expect(snapshot.members).toBe(48);
    expect(snapshot.isWarLogPublic).toBe(true);
  });

  it('war fixture 关键字段', () => {
    const snapshot = decodeOfficialClanWarSnapshotJson(fixture('official_clan_war_full.json'));
    expect(snapshot.state).toBe('inWar');
    expect(snapshot.teamSize).toBe(30);
  });

  it('war log fixture 关键字段', () => {
    const page = decodeOfficialWarLogPageJson(fixture('official_war_log_page.json'));
    expect(page.page.items[0]?.clan?.stars).toBe(95);
    expect(page.page.items[1]?.result).toBe('lose');
  });

  it('capital raid fixture 关键字段', () => {
    const page = decodeOfficialCapitalRaidPageJson(fixture('official_capital_raid_page.json'));
    expect(page.page.items[0]?.raidsCompleted).toBe(6);
    expect(page.page.items[1]?.state).toBe('ended');
  });
});
