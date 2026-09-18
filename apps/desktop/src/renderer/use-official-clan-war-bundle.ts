import type { AppSnapshotPayload, DesktopBridge } from '@coc-helper/contracts';

import type { ClanAffiliation, WarLogPublicity } from './official-session';
import { warLogPublicityOf } from './official-session';
import { useOfficialCapitalRaid, type OfficialCapitalRaidApi } from './use-official-capital-raid';
import { useOfficialClanWar, type OfficialClanWarApi } from './use-official-clan-war';
import { type BridgeOfficialClient } from './use-official-village';
import { useOfficialWarLog, type OfficialWarLogApi } from './use-official-war-log';

export type BridgeOfficialClanWarClient = Pick<
  DesktopBridge,
  | 'clanWarState'
  | 'warLogState'
  | 'capitalRaidState'
  | 'apiRefresh'
  | 'warLogLoadMore'
  | 'capitalRaidLoadMore'
  | 'onOperationProgress'
  | 'cancel'
>;

/** 村庄详情页 Official 卡片所需的完整 bridge（Player/Clan + War 族）。 */
export type BridgeOfficialVillageClient = BridgeOfficialClient & BridgeOfficialClanWarClient;

export type OfficialClanWarBundleApi = {
  readonly clanWar: OfficialClanWarApi;
  readonly warLog: OfficialWarLogApi;
  readonly capitalRaid: OfficialCapitalRaidApi;
};

export { warLogPublicityOf };

export function useOfficialClanWarBundle(
  bridge: BridgeOfficialClanWarClient,
  snapshot: AppSnapshotPayload | null,
  affiliation: ClanAffiliation,
  clanTag: string | null,
  villageId: string | null,
  warLogPublicity: WarLogPublicity,
): OfficialClanWarBundleApi {
  const clanWar = useOfficialClanWar(bridge, snapshot, affiliation, clanTag, villageId);
  const warLog = useOfficialWarLog(
    bridge,
    snapshot,
    affiliation,
    clanTag,
    villageId,
    warLogPublicity,
  );
  const capitalRaid = useOfficialCapitalRaid(bridge, snapshot, affiliation, clanTag, villageId);
  return { clanWar, warLog, capitalRaid };
}
