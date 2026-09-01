import type { CraftTableCatalog } from '../catalog/craft-table';
import type { CatalogCompatibility } from '../catalog/types';
import type { GameCatalog } from '../catalog/game-catalog';
import type { ManualUpgradeCore } from '../manual/types';
import { projectVillageCatalog } from './catalog-projection';
import { instanceWeight, progressUniverseCoverageIsComplete } from './types';
import { instanceCountAndOverflow, isKnown, needsReimport } from './village-detail-projection';
import type { TrackerBase, TrackerCategory } from './tracker';
import { trackerCategoryFromSection, trackerCategoryTitle } from './tracker';
import type { ProgressUniverseCoverage, VillageItemState } from './types';
import type { VillageProfile } from '../import/types';
import type { VillageProjectionProvider } from './types';

const INT_MAX = Number.MAX_SAFE_INTEGER;

export type ProgressMetricState = 'ready' | 'partial' | 'unavailable' | 'unknown';

export type ProgressMetricKind =
  | 'currentStageProgress'
  | 'globalProgress'
  | 'snapshotCoverage'
  | 'instanceProgress'
  | 'effectiveTrackerProgress';

export type ProgressMetric = {
  readonly kind: ProgressMetricKind;
  readonly numerator: number;
  readonly denominator: number;
  readonly state: ProgressMetricState;
  readonly saturated: boolean;
  readonly units: string;
  readonly degradedReason: string | null;
  readonly ratio: number | null;
};

export type VillageProgressMetrics = {
  readonly currentStageProgress: ProgressMetric;
  readonly globalProgress: ProgressMetric;
  readonly snapshotCoverage: ProgressMetric;
  readonly instanceProgress: ProgressMetric;
  readonly effectiveTrackerProgress: ProgressMetric;
};

export type AggregateCoverage = {
  readonly numerator: number;
  readonly denominator: number;
  readonly coverage: ProgressUniverseCoverage;
  readonly diagnostics: readonly string[];
  readonly helpText: string;
};

export type VillageProgressMetricsInput = {
  readonly items: readonly VillageItemState[];
  readonly catalogIsUsable: boolean;
  readonly compatibility: CatalogCompatibility | null | undefined;
  readonly coverage?: ProgressUniverseCoverage;
};

export function villageProgressMetrics(input: VillageProgressMetricsInput): VillageProgressMetrics {
  const { items, catalogIsUsable, compatibility, coverage = { kind: 'unavailable' } } = input;
  if (!catalogIsUsable) {
    return unavailableMetrics();
  }

  const known = items.filter((item) => isKnown(item) && !needsReimport(item));
  const unknownWeightInfo = instanceCountAndOverflow(
    items.filter((item) => item.status !== 'available' && (!isKnown(item) || needsReimport(item))),
  );

  const completeDenominator = progressUniverseCoverageIsComplete(coverage);
  const coverageDiagnostic = coverageDiagnosticFor(coverage);
  const available = completeDenominator ? items.filter((item) => item.status === 'available') : [];

  const stageEligible = [
    ...known.filter((item) => (item.currentStageMaxLevel ?? 0) > 0),
    ...available.filter((item) => (item.currentStageMaxLevel ?? 0) > 0),
  ];
  const stageMissingWeightInfo = instanceCountAndOverflow(
    known.filter((item) => (item.currentStageMaxLevel ?? 0) <= 0),
  );
  const stageDen = weightedCappedSum(stageEligible, (item) =>
    Math.max(0, item.currentStageMaxLevel ?? 0),
  );
  const stageNum = weightedCappedSum(stageEligible, (item) =>
    Math.min(Math.max(0, item.currentLevel ?? 0), Math.max(0, item.currentStageMaxLevel ?? 0)),
  );

  const globalEligible = [
    ...known.filter((item) => (item.maxLevel ?? 0) > 0),
    ...available.filter((item) => (item.maxLevel ?? 0) > 0),
  ];
  const globalMissingWeightInfo = instanceCountAndOverflow(
    known.filter((item) => (item.maxLevel ?? 0) <= 0),
  );
  const globalDen = weightedCappedSum(globalEligible, (item) => Math.max(0, item.maxLevel ?? 0));
  const globalNum = weightedCappedSum(globalEligible, (item) =>
    Math.min(Math.max(0, item.currentLevel ?? 0), Math.max(0, item.maxLevel ?? 0)),
  );

  const coverageDen = instanceCountAndOverflow(items);
  const coverageNum = instanceCountAndOverflow(known);
  const availableWeightInfo = completeDenominator
    ? instanceCountAndOverflow(available)
    : { count: 0, didOverflow: false };
  const unverifiedCatalog = compatibility?.kind === 'unverified';

  const currentStageProgress = makeMetric({
    kind: 'currentStageProgress',
    numerator: stageNum.value,
    denominator: stageDen.value,
    saturated: stageNum.saturated || stageDen.saturated,
    unknownWeight: unknownWeightInfo.count,
    availableWeight: availableWeightInfo.count,
    unverifiedCatalog,
    denominatorIsComplete: completeDenominator,
    units: '级',
    emptyReason: '无可确认项目，暂无法计算',
    extraReason:
      stageMissingWeightInfo.count > 0
        ? `${stageMissingWeightInfo.count} 项缺少阶段上限，未计入阶段进度。`
        : null,
    coverageDiagnostic,
  });
  const globalProgress = makeMetric({
    kind: 'globalProgress',
    numerator: globalNum.value,
    denominator: globalDen.value,
    saturated: globalNum.saturated || globalDen.saturated,
    unknownWeight: unknownWeightInfo.count,
    availableWeight: availableWeightInfo.count,
    unverifiedCatalog,
    denominatorIsComplete: completeDenominator,
    units: '级',
    emptyReason: '无可确认项目，暂无法计算',
    extraReason:
      globalMissingWeightInfo.count > 0
        ? `${globalMissingWeightInfo.count} 项缺少或异常全局上限，未计入全局进度。`
        : null,
    coverageDiagnostic,
  });
  const snapshotCoverage = makeMetric({
    kind: 'snapshotCoverage',
    numerator: coverageNum.count,
    denominator: coverageDen.count,
    saturated: coverageNum.didOverflow || coverageDen.didOverflow,
    unknownWeight: unknownWeightInfo.count,
    availableWeight: availableWeightInfo.count,
    unverifiedCatalog,
    denominatorIsComplete: true,
    units: '实例',
    emptyReason: '尚未导入快照',
    coverageDiagnostic,
  });
  const instanceDenominator = instanceCountAndOverflow(items);
  const instanceNumerator = instanceCountAndOverflow(
    known.filter((item) => item.status === 'maxed'),
  );
  const instanceProgress = makeMetric({
    kind: 'instanceProgress',
    numerator: instanceNumerator.count,
    denominator: instanceDenominator.count,
    saturated: instanceNumerator.didOverflow || instanceDenominator.didOverflow,
    unknownWeight: unknownWeightInfo.count,
    availableWeight: availableWeightInfo.count,
    unverifiedCatalog,
    denominatorIsComplete: completeDenominator,
    units: '实例',
    emptyReason: '无可确认项目，暂无法计算',
    coverageDiagnostic,
  });
  const effectiveTrackerProgress: ProgressMetric = {
    kind: 'effectiveTrackerProgress',
    numerator: globalProgress.numerator,
    denominator: globalProgress.denominator,
    state: globalProgress.state,
    saturated: globalProgress.saturated,
    units: globalProgress.units,
    degradedReason: globalProgress.degradedReason,
    ratio: globalProgress.ratio,
  };

  return {
    currentStageProgress,
    globalProgress,
    snapshotCoverage,
    instanceProgress,
    effectiveTrackerProgress,
  };
}

export function aggregateCoverage(input: {
  readonly villages: readonly VillageProfile[];
  readonly catalog: GameCatalog | null | undefined;
  readonly seasonalPhases?: import('../catalog/seasonal-phase').SeasonalPhaseTable;
  readonly nowMs?: number;
  readonly projectionProvider?: VillageProjectionProvider;
  readonly craftTableCatalog?: CraftTableCatalog | null;
  readonly manualUpgradeCores?: Readonly<Record<string, ManualUpgradeCore>> | null;
}): AggregateCoverage | null {
  const {
    villages,
    catalog,
    seasonalPhases,
    nowMs = Date.now(),
    projectionProvider,
    craftTableCatalog,
    manualUpgradeCores,
  } = input;

  let known = 0;
  let observed = 0;
  const homeCoverages: ProgressUniverseCoverage[] = [];
  let bbHasObservations = false;
  const bases: TrackerBase[] = ['home', 'builder'];

  for (const village of villages) {
    if (village.accountSnapshot === null || village.accountSnapshot === undefined) {
      continue;
    }
    for (const base of bases) {
      const projection =
        projectionProvider?.(village, base, nowMs) ??
        projectVillageCatalog({
          village,
          catalog,
          seasonalPhases,
          craftTableCatalog,
          base,
          nowMs,
          manualUpgradeCore: manualUpgradeCores?.[village.id] ?? null,
        });
      if (base === 'home') {
        homeCoverages.push(projection.progressCoverage);
      }
      const coverage = (projection.progressMetrics as VillageProgressMetrics).snapshotCoverage;
      if (coverage.saturated) {
        return null;
      }
      const nextKnown = known + coverage.numerator;
      const nextObserved = observed + coverage.denominator;
      if (
        !Number.isFinite(nextKnown) ||
        !Number.isFinite(nextObserved) ||
        nextKnown > INT_MAX ||
        nextObserved > INT_MAX
      ) {
        return null;
      }
      known = nextKnown;
      observed = nextObserved;
      if (base !== 'home' && coverage.denominator > 0) {
        bbHasObservations = true;
      }
    }
  }

  if (observed <= 0) {
    return null;
  }

  let merged = mergedCoverage(homeCoverages);
  if (bbHasObservations && merged.kind === 'complete') {
    merged = { kind: 'partial', missingSections: new Set(), unmodeledCategories: new Set() };
  }

  return {
    numerator: known,
    denominator: observed,
    coverage: merged,
    diagnostics: aggregateCoverageDiagnostics({
      merged,
      unavailableHomeCount: homeCoverages.filter((coverage) => coverage.kind === 'unavailable')
        .length,
      includesBuilderBaseData: bbHasObservations,
    }),
    helpText: aggregateCoverageHelpText(merged),
  };
}

export function replacingTrackerMetrics(
  metrics: VillageProgressMetrics,
  instanceProgress: ProgressMetric,
  effectiveTrackerProgress: ProgressMetric,
): VillageProgressMetrics {
  return {
    currentStageProgress: metrics.currentStageProgress,
    globalProgress: metrics.globalProgress,
    snapshotCoverage: metrics.snapshotCoverage,
    instanceProgress,
    effectiveTrackerProgress,
  };
}

export function mergedCoverage(
  coverages: readonly ProgressUniverseCoverage[],
): ProgressUniverseCoverage {
  const missing = new Set<string>();
  const unmodeled = new Set<TrackerCategory>();
  let sawComplete = false;
  let sawPartial = false;
  let sawUnavailable = false;

  for (const coverage of coverages) {
    switch (coverage.kind) {
      case 'complete':
        sawComplete = true;
        break;
      case 'partial':
        sawPartial = true;
        for (const section of coverage.missingSections) {
          missing.add(section);
        }
        for (const category of coverage.unmodeledCategories) {
          unmodeled.add(category);
        }
        break;
      case 'unavailable':
        sawUnavailable = true;
        break;
    }
  }

  if (sawPartial) {
    const deduped = [...missing].filter((section) => {
      const category = trackerCategoryFromSection(section);
      return category === undefined || !unmodeled.has(category);
    });
    return {
      kind: 'partial',
      missingSections: new Set(deduped),
      unmodeledCategories: unmodeled,
    };
  }
  if (!sawComplete) {
    return { kind: 'unavailable' };
  }
  if (sawUnavailable) {
    return { kind: 'partial', missingSections: new Set(), unmodeledCategories: new Set() };
  }
  return { kind: 'complete' };
}

export function aggregateCoverageDiagnostics(input: {
  readonly merged: ProgressUniverseCoverage;
  readonly unavailableHomeCount: number;
  readonly includesBuilderBaseData?: boolean;
}): readonly string[] {
  const { merged, unavailableHomeCount, includesBuilderBaseData = false } = input;
  if (merged.kind !== 'partial') {
    return [];
  }
  const parts: string[] = [];
  if (merged.missingSections.size > 0) {
    const titles = [...merged.missingSections]
      .map((section) => {
        const category = trackerCategoryFromSection(section);
        return category === undefined ? section : trackerCategoryTitle(category);
      })
      .sort()
      .join('、');
    parts.push(`部分村庄快照缺少类别数据（${titles}），无法确认完整村庄进度。`);
  }
  if (merged.unmodeledCategories.size > 0) {
    parts.push(
      `目录未对${[...merged.unmodeledCategories]
        .map((category) => trackerCategoryTitle(category))
        .sort()
        .join('、')}的实例数量建模，无法确认完整村庄进度。`,
    );
  }
  if (unavailableHomeCount > 0) {
    parts.push(`${unavailableHomeCount} 个村庄覆盖状态不可用，无法确认完整村庄进度。`);
  }
  if (includesBuilderBaseData) {
    parts.push(
      '聚合含建筑大师基地已观测数据（数据源不可靠，未纳入完整宇宙口径），无法确认完整村庄进度。',
    );
  }
  return parts;
}

function aggregateCoverageHelpText(coverage: ProgressUniverseCoverage): string {
  switch (coverage.kind) {
    case 'complete':
      return '已观测实例占村庄全部可建造数量';
    case 'partial':
      return '聚合分母为各村庄/基地已观测实例与可用宇宙差集之和，非统一完整宇宙口径';
    case 'unavailable':
      return '分母为已观测实例，非全部可能建筑';
  }
}

function coverageDiagnosticFor(coverage: ProgressUniverseCoverage): string | null {
  if (coverage.kind !== 'partial') {
    return null;
  }
  const parts: string[] = [];
  if (coverage.missingSections.size > 0) {
    const titles = [...coverage.missingSections]
      .map((section) => {
        const category = trackerCategoryFromSection(section);
        return category === undefined ? section : trackerCategoryTitle(category);
      })
      .sort()
      .join('、');
    parts.push(`快照缺少类别数据（${titles}），无法确认完整村庄进度。`);
  }
  if (coverage.unmodeledCategories.size > 0) {
    parts.push(
      `目录未对${[...coverage.unmodeledCategories]
        .map((category) => trackerCategoryTitle(category))
        .sort()
        .join('、')}的实例数量建模，无法确认完整村庄进度。`,
    );
  }
  return parts.length === 0 ? null : parts.join(' ');
}

function unavailableMetrics(): VillageProgressMetrics {
  const reason = '目录不可用或版本不匹配，暂无法计算该指标。';
  const metric = (kind: ProgressMetricKind, units: string): ProgressMetric => ({
    kind,
    numerator: 0,
    denominator: 0,
    state: 'unavailable',
    saturated: false,
    units,
    degradedReason: reason,
    ratio: null,
  });
  return {
    currentStageProgress: metric('currentStageProgress', '级'),
    globalProgress: metric('globalProgress', '级'),
    snapshotCoverage: metric('snapshotCoverage', '实例'),
    instanceProgress: metric('instanceProgress', '实例'),
    effectiveTrackerProgress: metric('effectiveTrackerProgress', '级'),
  };
}

function makeMetric(input: {
  readonly kind: ProgressMetricKind;
  readonly numerator: number;
  readonly denominator: number;
  readonly saturated: boolean;
  readonly unknownWeight: number;
  readonly availableWeight: number;
  readonly unverifiedCatalog: boolean;
  readonly denominatorIsComplete: boolean;
  readonly units: string;
  readonly emptyReason: string;
  readonly extraReason?: string | null;
  readonly coverageDiagnostic?: string | null;
}): ProgressMetric {
  const reasons: string[] = [];
  let state: ProgressMetricState;
  if (input.denominator === 0) {
    state = 'unknown';
    reasons.push(input.emptyReason);
    if (input.extraReason) {
      reasons.push(input.extraReason);
    }
    if (input.coverageDiagnostic) {
      reasons.push(input.coverageDiagnostic);
    }
  } else {
    if (!input.denominatorIsComplete) {
      reasons.push('分母为已观测项目，非村庄全部实例，无法计算完整村庄进度。');
    }
    if (input.unknownWeight > 0) {
      reasons.push(`${input.unknownWeight} 项未知或待重新导入，结果仅为已观测项目。`);
    }
    if (input.availableWeight > 0) {
      reasons.push(
        `${input.availableWeight} 项宇宙差集未观测（可建造未导入），进度为完整分母下的保守估计。`,
      );
    }
    if (input.extraReason) {
      reasons.push(input.extraReason);
    }
    if (input.coverageDiagnostic) {
      reasons.push(input.coverageDiagnostic);
    }
    if (input.unverifiedCatalog) {
      reasons.push('目录与玩家版本未验证，百分比可能过时。');
    }
    state = reasons.length === 0 ? 'ready' : 'partial';
  }

  const degradedReason = reasons.length === 0 ? null : reasons.join(' ');
  const ratio =
    !input.saturated && input.denominator > 0 && (state === 'ready' || state === 'partial')
      ? input.numerator / input.denominator
      : null;

  return {
    kind: input.kind,
    numerator: input.numerator,
    denominator: input.denominator,
    state,
    saturated: input.saturated,
    units: input.units,
    degradedReason,
    ratio,
  };
}

function weightedCappedSum(
  items: readonly VillageItemState[],
  value: (item: VillageItemState) => number,
): { readonly value: number; readonly saturated: boolean } {
  let saturated = false;
  const total = items.reduce((accumulator, item) => {
    if (item.countOverflowed) {
      saturated = true;
    }
    const scaled = value(item) * instanceWeight(item);
    const next = accumulator + scaled;
    if (!Number.isFinite(next) || next > INT_MAX) {
      saturated = true;
      return INT_MAX;
    }
    return next;
  }, 0);
  return { value: total, saturated };
}
