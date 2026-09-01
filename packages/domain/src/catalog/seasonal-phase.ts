import { refSecondsToUnixSeconds } from '@coc-helper/wire';

import type { CatalogLifecycle } from './types';

export type SeasonalPhase = {
  readonly phaseID: string;
  readonly name: string | null;
  readonly fromMs: number;
  readonly untilMs: number;
  readonly itemKeys: readonly string[];
  readonly sourceURL: string | null;
};

export type SeasonalStatus = 'active' | 'notStarted' | 'ended';

export type CatalogAvailability =
  | { readonly kind: 'permanent' }
  | {
      readonly kind: 'seasonal';
      readonly phaseID: string;
      readonly phaseName: string | null;
      readonly status: SeasonalStatus;
    }
  | { readonly kind: 'unconfigured' }
  | {
      readonly kind: 'conflict';
      readonly phaseID: string;
      readonly phaseName: string | null;
      readonly lifecycle: CatalogLifecycle;
      readonly sourceURL: string | null;
    };

export type SeasonalPhaseTable = {
  readonly schemaVersion: number;
  readonly phases: readonly SeasonalPhase[];
  readonly phaseForItemKey: (key: string, atMs: number) => SeasonalPhase | undefined;
  readonly availability: (
    key: string,
    lifecycle: CatalogLifecycle | null | undefined,
    atMs: number,
  ) => CatalogAvailability;
  readonly bucket: (atMs: number) => PhaseBucket;
};

export type PhaseBucket = {
  readonly tableIdentity: string;
  readonly startMs: number;
  readonly endMs: number;
};

export const EMPTY_SEASONAL_PHASE_TABLE: SeasonalPhaseTable = createSeasonalPhaseTable({
  schemaVersion: 1,
  phases: [],
});

export function createSeasonalPhaseTable(input: {
  readonly schemaVersion: number;
  readonly phases: readonly SeasonalPhase[];
}): SeasonalPhaseTable {
  const tableIdentity = `${input.schemaVersion}:${input.phases.map((phase) => phase.phaseID).join('|')}`;

  function validPhases(): readonly SeasonalPhase[] {
    return input.phases.filter((phase) => phase.fromMs < phase.untilMs);
  }

  function phaseForItemKey(key: string, atMs: number): SeasonalPhase | undefined {
    const phases = validPhases().filter((phase) => phase.itemKeys.includes(key));
    const active = phases
      .filter((phase) => phase.fromMs <= atMs && atMs < phase.untilMs)
      .sort((left, right) => right.fromMs - left.fromMs)[0];
    if (active !== undefined) {
      return active;
    }
    const future = phases
      .filter((phase) => phase.fromMs > atMs)
      .sort((left, right) => left.fromMs - right.fromMs)[0];
    if (future !== undefined) {
      return future;
    }
    return phases.sort((left, right) => right.untilMs - left.untilMs)[0];
  }

  return {
    schemaVersion: input.schemaVersion,
    phases: input.phases,
    phaseForItemKey,
    availability(key, lifecycle, atMs) {
      const phase = phaseForItemKey(key, atMs);
      if (phase === undefined) {
        return lifecycle === 'permanent' ? { kind: 'permanent' } : { kind: 'unconfigured' };
      }
      if (lifecycle === 'permanent') {
        return {
          kind: 'conflict',
          phaseID: phase.phaseID,
          phaseName: phase.name,
          lifecycle: 'permanent',
          sourceURL: phase.sourceURL,
        };
      }
      let status: SeasonalStatus;
      if (atMs < phase.fromMs) {
        status = 'notStarted';
      } else if (atMs < phase.untilMs) {
        status = 'active';
      } else {
        status = 'ended';
      }
      return {
        kind: 'seasonal',
        phaseID: phase.phaseID,
        phaseName: phase.name,
        status,
      };
    },
    bucket(atMs) {
      const boundaries = validPhases()
        .flatMap((phase) => [phase.fromMs, phase.untilMs])
        .sort((left, right) => left - right);
      const startMs = [...boundaries].reverse().find((value) => value <= atMs) ?? Number.NEGATIVE_INFINITY;
      const endMs = boundaries.find((value) => value > atMs) ?? Number.POSITIVE_INFINITY;
      return { tableIdentity, startMs, endMs };
    },
  };
}

export function decodeSeasonalPhaseTable(value: {
  readonly schemaVersion: number;
  readonly phases: readonly {
    readonly phaseID: string;
    readonly name?: string | null;
    readonly from: number;
    readonly until: number;
    readonly itemKeys: readonly string[];
    readonly sourceURL?: string | null;
  }[];
}): SeasonalPhaseTable {
  if (value.schemaVersion !== 1) {
    return EMPTY_SEASONAL_PHASE_TABLE;
  }
  return createSeasonalPhaseTable({
    schemaVersion: value.schemaVersion,
    phases: value.phases.map((phase) => ({
      phaseID: phase.phaseID,
      name: phase.name ?? null,
      fromMs: refSecondsToUnixSeconds(phase.from) * 1000,
      untilMs: refSecondsToUnixSeconds(phase.until) * 1000,
      itemKeys: phase.itemKeys,
      sourceURL: phase.sourceURL ?? null,
    })),
  });
}

export function catalogAvailabilityLabel(availability: CatalogAvailability): string | null {
  switch (availability.kind) {
    case 'permanent':
      return null;
    case 'seasonal': {
      const name = availability.phaseName ?? availability.phaseID;
      switch (availability.status) {
        case 'active':
          return `限时内容：${name}（活动）`;
        case 'notStarted':
          return `限时内容：${name}（未开始）`;
        case 'ended':
          return `限时内容：${name}（已结束，仅历史数据）`;
      }
      break;
    }
    case 'unconfigured':
      return '阶段信息未配置';
    case 'conflict':
      return `限时内容声明冲突：${availability.phaseName ?? availability.phaseID}（声明为永久内容）`;
  }
}
