/**
 * Official API DTO 映射：domain endpoint state → contracts wire DTO。
 */

import type { OfficialEndpointStateDto } from '@coc-helper/contracts';
import {
  encodeClanAPIStateWire,
  encodeClanCapitalAPIStateWire,
  encodeClanWarAPIStateWire,
  encodeClanWarLogAPIStateWire,
  encodePlayerAPIStateWire,
  isCapReached,
  MAX_CAPITAL_SEASONS_PER_TAG,
  MAX_WAR_LOG_ITEMS_PER_TAG,
  type ClanAPIState,
  type ClanCapitalAPIState,
  type ClanWarAPIState,
  type ClanWarLogAPIState,
  type OfficialAPIState,
} from '@coc-helper/domain';

export function toPlayerEndpointDto(
  state: OfficialAPIState,
): OfficialEndpointStateDto {
  return encodePlayerAPIStateWire(state) as OfficialEndpointStateDto;
}

export function toClanEndpointDto(state: ClanAPIState): OfficialEndpointStateDto {
  return encodeClanAPIStateWire(state) as OfficialEndpointStateDto;
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
    hasMore:
      after !== undefined && !isCapReached(items, MAX_WAR_LOG_ITEMS_PER_TAG) ? true : false,
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
