/**
 * Official API DTO 映射：domain endpoint state → contracts wire DTO。
 */

import type {
  OfficialClanSummaryDto,
  OfficialEndpointStateDto,
  OfficialPlayerSummaryDto,
} from '@coc-helper/contracts';
import {
  encodeClanAPIStateWire,
  encodeClanCapitalAPIStateWire,
  encodeClanWarAPIStateWire,
  encodeClanWarLogAPIStateWire,
  encodePlayerAPIStateWire,
  isCapReached,
  MAX_CAPITAL_SEASONS_PER_TAG,
  MAX_WAR_LOG_ITEMS_PER_TAG,
  officialAPICurrentClanTag,
  type ClanAPIState,
  type ClanCapitalAPIState,
  type ClanWarAPIState,
  type ClanWarLogAPIState,
  type OfficialAPIState,
} from '@coc-helper/domain';

export function toPlayerEndpointDto(state: OfficialAPIState): OfficialEndpointStateDto {
  return encodePlayerAPIStateWire(state) as OfficialEndpointStateDto;
}

export function toPlayerSummaryDto(state: OfficialAPIState): OfficialPlayerSummaryDto | null {
  const snapshot = state.lastGood;
  if (snapshot === undefined) {
    return null;
  }
  return {
    name: snapshot.name ?? null,
    tag: snapshot.tag ?? null,
    townHallLevel: snapshot.townHallLevel ?? null,
    builderHallLevel: snapshot.builderHallLevel ?? null,
    expLevel: snapshot.expLevel ?? null,
    trophies: snapshot.trophies ?? null,
    bestTrophies: snapshot.bestTrophies ?? null,
    clanName: snapshot.clan?.name ?? null,
    clanTag: snapshot.clan?.tag ?? null,
  };
}

export function toCurrentClanTagDto(state: OfficialAPIState | null): string | null {
  if (state === null) {
    return null;
  }
  return officialAPICurrentClanTag(state) ?? null;
}

export function toClanEndpointDto(state: ClanAPIState): OfficialEndpointStateDto {
  return encodeClanAPIStateWire(state) as OfficialEndpointStateDto;
}

export function toClanSummaryDto(state: ClanAPIState): OfficialClanSummaryDto | null {
  const snapshot = state.lastGood;
  if (snapshot === undefined) {
    return null;
  }
  return {
    name: snapshot.name ?? null,
    tag: snapshot.tag ?? null,
    clanLevel: snapshot.clanLevel ?? null,
    members: snapshot.members ?? null,
    type: snapshot.type ?? null,
    isWarLogPublic: snapshot.isWarLogPublic ?? null,
    warWins: snapshot.warWins ?? null,
  };
}

export function toClanWarEndpointDto(state: ClanWarAPIState): OfficialEndpointStateDto {
  return encodeClanWarAPIStateWire(state) as OfficialEndpointStateDto;
}

export function toWarLogEndpointDto(state: ClanWarLogAPIState): OfficialEndpointStateDto {
  const wire = encodeClanWarLogAPIStateWire(state) as OfficialEndpointStateDto;
  const items = state.lastGood?.page.items.length ?? 0;
  const after = state.lastGood?.page.after;
  return {
    ...wire,
    hasMore: after !== undefined && !isCapReached(items, MAX_WAR_LOG_ITEMS_PER_TAG) ? true : false,
  };
}

export function toCapitalRaidEndpointDto(state: ClanCapitalAPIState): OfficialEndpointStateDto {
  const wire = encodeClanCapitalAPIStateWire(state) as OfficialEndpointStateDto;
  const items = state.lastGood?.page.items.length ?? 0;
  const after = state.lastGood?.page.after;
  return {
    ...wire,
    hasMore:
      after !== undefined && !isCapReached(items, MAX_CAPITAL_SEASONS_PER_TAG) ? true : false,
  };
}
