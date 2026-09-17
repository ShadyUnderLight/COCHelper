import type { AppSnapshotPayload, DesktopBridge } from '@coc-helper/contracts';

import type { OfficialClanView } from './official-session';
import { useOfficialCapitalRaid, type OfficialCapitalRaidApi } from './use-official-capital-raid';
import { useOfficialClanWar, type OfficialClanWarApi } from './use-official-clan-war';
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

export type OfficialClanWarBundleApi = {
  readonly clanWar: OfficialClanWarApi;
  readonly warLog: OfficialWarLogApi;
  readonly capitalRaid: OfficialCapitalRaidApi;
};

export function warLogKnownNotPublic(clan: OfficialClanView): boolean {
  return clan.summary?.isWarLogPublic === false;
}

export function useOfficialClanWarBundle(
  bridge: BridgeOfficialClanWarClient,
  snapshot: AppSnapshotPayload | null,
  clanTag: string | null,
  villageId: string | null,
  knownNotPublic: boolean,
): OfficialClanWarBundleApi {
  const clanWar = useOfficialClanWar(bridge, snapshot, clanTag, villageId);
  const warLog = useOfficialWarLog(bridge, snapshot, clanTag, villageId, knownNotPublic);
  const capitalRaid = useOfficialCapitalRaid(bridge, snapshot, clanTag, villageId);
  return { clanWar, warLog, capitalRaid };
}
