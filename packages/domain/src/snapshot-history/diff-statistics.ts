import {
  INT64_BOUNDS,
  refSecondsToUnixSeconds,
  saturatingAdd,
  saturatingMultiply,
  saturatingSubtract,
} from '@coc-helper/wire';

import type { SnapshotChange, SnapshotDiff, SnapshotDiffSectionCoverage } from './diff-types';
import { coverageProofExpectedCount } from './types';
import { snapshotItemIdentityKey } from './types';

export type SnapshotStatisticValueState = 'available' | 'insufficientData';

export type SnapshotStatisticValue = {
  readonly state: SnapshotStatisticValueState;
  readonly value?: number;
  readonly reason?: string;
};

export function snapshotStatisticValueAvailable(value: number): SnapshotStatisticValue {
  return { state: 'available', value };
}

export function snapshotStatisticValueInsufficientData(reason: string): SnapshotStatisticValue {
  return { state: 'insufficientData', reason };
}

export type SnapshotHistoryStatisticsWindow = {
  readonly startRefSeconds: number;
  readonly endRefSeconds: number;
  readonly buildingUpgradeCompletions: SnapshotStatisticValue;
  readonly aggregateInferredBuildingUpgradeCompletions: SnapshotStatisticValue;
  readonly buildingLevelGrowth: SnapshotStatisticValue;
  readonly aggregateInferredBuildingLevelGrowth: SnapshotStatisticValue;
  readonly wallLevelGrowth: SnapshotStatisticValue;
  readonly aggregateInferredWallLevelGrowth: SnapshotStatisticValue;
  readonly heroLevelGrowth: SnapshotStatisticValue;
  readonly troopLevelGrowth: SnapshotStatisticValue;
  readonly spellLevelGrowth: SnapshotStatisticValue;
  readonly petLevelGrowth: SnapshotStatisticValue;
  readonly heroEquipmentLevelGrowth: SnapshotStatisticValue;
  readonly aggregateInferredEventCount: SnapshotStatisticValue;
};

export function confirmedWallLevelGrowth(
  window: SnapshotHistoryStatisticsWindow,
): SnapshotStatisticValue {
  const { wallLevelGrowth, aggregateInferredWallLevelGrowth } = window;
  if (
    wallLevelGrowth.state !== 'available' ||
    aggregateInferredWallLevelGrowth.state !== 'available' ||
    wallLevelGrowth.value === undefined ||
    aggregateInferredWallLevelGrowth.value === undefined
  ) {
    const reasons = [wallLevelGrowth.reason, aggregateInferredWallLevelGrowth.reason].filter(
      (reason): reason is string => reason !== undefined,
    );
    return snapshotStatisticValueInsufficientData(
      reasons[0] ?? '城墙总增长或聚合推断增长数据不足，无法拆分已确认部分。',
    );
  }
  const result = saturatingSubtract(
    BigInt(wallLevelGrowth.value),
    BigInt(aggregateInferredWallLevelGrowth.value),
    INT64_BOUNDS,
  );
  if (result.overflowed || result.value < 0n) {
    return snapshotStatisticValueInsufficientData('城墙增长证据分区不一致，无法安全拆分。');
  }
  return snapshotStatisticValueAvailable(Number(result.value));
}

export type SnapshotHistoryStatistics = {
  readonly referenceDateRefSeconds: number;
  readonly timeZoneIdentifier: string;
  readonly today: SnapshotHistoryStatisticsWindow;
  readonly last7Days: SnapshotHistoryStatisticsWindow;
  readonly last30Days: SnapshotHistoryStatisticsWindow;
  readonly diagnostics: readonly string[];
};

type MetricUniverseState = 'complete' | 'notApplicable' | 'insufficient' | 'irrelevant';

type MetricSectionApplicability = 'complete' | 'notApplicable' | 'insufficient';

type SnapshotMetricCategory =
  'building' | 'wall' | 'hero' | 'troop' | 'spell' | 'pet' | 'equipment';

type ZonedParts = {
  readonly year: number;
  readonly month: number;
  readonly day: number;
  readonly hour: number;
  readonly minute: number;
  readonly second: number;
};

function intAddReportingOverflow(left: number, right: number): { sum: number; overflow: boolean } {
  const result = saturatingAdd(BigInt(left), BigInt(right), INT64_BOUNDS);
  return { sum: Number(result.value), overflow: result.overflowed };
}

function intMultiplyReportingOverflow(
  left: number,
  right: number,
): {
  product: number;
  overflow: boolean;
} {
  const result = saturatingMultiply(BigInt(left), BigInt(right), INT64_BOUNDS);
  return { product: Number(result.value), overflow: result.overflowed };
}

function refSecondsToDate(refSeconds: number): Date {
  return new Date(refSecondsToUnixSeconds(refSeconds) * 1000);
}

function dateToRefSeconds(date: Date): number {
  return date.getTime() / 1000 - 978_307_200;
}

function resolvedTimeZoneIdentifier(timeZoneIdentifier?: string): string {
  return timeZoneIdentifier ?? Intl.DateTimeFormat().resolvedOptions().timeZone;
}

function getZonedParts(date: Date, timeZone: string): ZonedParts {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false,
  }).formatToParts(date);
  const read = (type: string): number =>
    Number(parts.find((part) => part.type === type)?.value ?? '0');
  return {
    year: read('year'),
    month: read('month'),
    day: read('day'),
    hour: read('hour') % 24,
    minute: read('minute'),
    second: read('second'),
  };
}

function getTimeZoneOffsetMs(date: Date, timeZone: string): number {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    timeZoneName: 'longOffset',
    hour: 'numeric',
  }).formatToParts(date);
  const tzName = parts.find((part) => part.type === 'timeZoneName')?.value ?? 'GMT';
  const match = /GMT([+-])(\d{1,2})(?::(\d{2}))?/.exec(tzName);
  if (!match) {
    return 0;
  }
  const sign = match[1] === '+' ? 1 : -1;
  const hours = Number(match[2]);
  const minutes = Number(match[3] ?? '0');
  return sign * (hours * 3600 + minutes * 60) * 1000;
}

function zonedTimeToUtc(parts: ZonedParts, timeZone: string): Date {
  const utcGuess = Date.UTC(
    parts.year,
    parts.month - 1,
    parts.day,
    parts.hour,
    parts.minute,
    parts.second,
  );
  const offset = getTimeZoneOffsetMs(new Date(utcGuess), timeZone);
  return new Date(utcGuess - offset);
}

function startOfDayInTimeZone(date: Date, timeZone: string): Date {
  const parts = getZonedParts(date, timeZone);
  return zonedTimeToUtc({ ...parts, hour: 0, minute: 0, second: 0 }, timeZone);
}

function addCalendarDays(date: Date, days: number, timeZone: string): Date {
  const parts = getZonedParts(date, timeZone);
  const shifted = new Date(Date.UTC(parts.year, parts.month - 1, parts.day + days));
  return zonedTimeToUtc(
    {
      year: shifted.getUTCFullYear(),
      month: shifted.getUTCMonth() + 1,
      day: shifted.getUTCDate(),
      hour: 0,
      minute: 0,
      second: 0,
    },
    timeZone,
  );
}

function fieldIsComplete(field: string, state: string, observedItemCount: number): boolean {
  if (state === 'complete') {
    return true;
  }
  return (
    observedItemCount === 0 && state === 'unavailable' && field !== 'presence' && field !== 'data'
  );
}

function snapshotDiffSectionCoverageIsCompleteForFields(
  coverage: SnapshotDiffSectionCoverage,
  fields: ReadonlySet<string>,
): boolean {
  if (
    coverage.fromSectionCompleteness !== 'complete' ||
    coverage.toSectionCompleteness !== 'complete' ||
    !coverage.fromTrustTrusted ||
    !coverage.toTrustTrusted
  ) {
    return false;
  }
  for (const field of fields) {
    if (
      !fieldIsComplete(
        field,
        coverage.fromFieldStates[field] ?? 'unavailable',
        coverage.fromObservedItemCount,
      ) ||
      !fieldIsComplete(
        field,
        coverage.toFieldStates[field] ?? 'unavailable',
        coverage.toObservedItemCount,
      )
    ) {
      return false;
    }
  }
  return true;
}

function snapshotDiffSectionCoverageIsNotApplicableForMetrics(
  coverage: SnapshotDiffSectionCoverage,
): boolean {
  if (
    coverage.fromSectionCompleteness !== 'complete' ||
    coverage.toSectionCompleteness !== 'complete' ||
    !coverage.fromTrustTrusted ||
    !coverage.toTrustTrusted ||
    coverage.fromObservedItemCount !== 0 ||
    coverage.toObservedItemCount !== 0 ||
    coverage.fromProof === undefined ||
    coverage.toProof === undefined
  ) {
    return false;
  }
  return (
    coverageProofExpectedCount(coverage.fromProof) === 0 &&
    coverageProofExpectedCount(coverage.toProof) === 0
  );
}

function isSectionRelevant(coverage: SnapshotDiffSectionCoverage): boolean {
  if (coverage.fromObservedItemCount > 0 || coverage.toObservedItemCount > 0) {
    return true;
  }
  if (coverage.fromState !== 'unavailable' || coverage.toState !== 'unavailable') {
    return true;
  }
  if (
    coverage.fromSectionCompleteness !== 'unavailable' ||
    coverage.toSectionCompleteness !== 'unavailable'
  ) {
    return true;
  }
  return false;
}

class MetricApplicabilityEvaluator {
  constructor(private readonly sectionCoverage: readonly SnapshotDiffSectionCoverage[]) {}

  applicability(section: string, fields: ReadonlySet<string>): MetricSectionApplicability {
    const coverage = this.sectionCoverage.find((entry) => entry.rawSection === section);
    if (!coverage) {
      return 'insufficient';
    }
    if (snapshotDiffSectionCoverageIsNotApplicableForMetrics(coverage)) {
      return 'notApplicable';
    }
    if (snapshotDiffSectionCoverageIsCompleteForFields(coverage, fields)) {
      return 'complete';
    }
    return 'insufficient';
  }

  universeState(sections: ReadonlySet<string>, fields: ReadonlySet<string>): MetricUniverseState {
    if (sections.size === 0) {
      return 'insufficient';
    }
    let sawComplete = false;
    for (const section of [...sections].sort()) {
      switch (this.applicability(section, fields)) {
        case 'complete':
          sawComplete = true;
          break;
        case 'notApplicable':
          break;
        case 'insufficient':
          return 'insufficient';
      }
    }
    return sawComplete ? 'complete' : 'notApplicable';
  }

  provenanceOnlyState(
    sections: ReadonlySet<string>,
    fields: ReadonlySet<string>,
  ): MetricUniverseState {
    if (sections.size === 0) {
      return 'insufficient';
    }
    let sawRelevant = false;
    let sawComplete = false;
    for (const section of [...sections].sort()) {
      const coverage = this.sectionCoverage.find((entry) => entry.rawSection === section);
      if (!coverage || !isSectionRelevant(coverage)) {
        continue;
      }
      sawRelevant = true;
      switch (this.applicability(section, fields)) {
        case 'complete':
          sawComplete = true;
          break;
        case 'notApplicable':
          break;
        case 'insufficient':
          return 'insufficient';
      }
    }
    if (sawComplete) {
      return 'complete';
    }
    return sawRelevant ? 'notApplicable' : 'irrelevant';
  }

  isUniverseRelevant(sections: ReadonlySet<string>, diff: SnapshotDiff): boolean {
    for (const section of sections) {
      const coverage = this.sectionCoverage.find((entry) => entry.rawSection === section);
      if (coverage && isSectionRelevant(coverage)) {
        return true;
      }
    }
    const normalizedSections = new Set(
      [...sections].map((section) => (section.endsWith('2') ? section.slice(0, -1) : section)),
    );
    for (const change of diff.changes) {
      const section = change.identity.rawSection.endsWith('2')
        ? change.identity.rawSection.slice(0, -1)
        : change.identity.rawSection;
      if (normalizedSections.has(section)) {
        return true;
      }
    }
    return false;
  }

  neutralMetricEligibility(
    sections: ReadonlySet<string>,
    fields: ReadonlySet<string>,
    diff: SnapshotDiff,
  ): MetricUniverseState {
    if (!this.isUniverseRelevant(sections, diff)) {
      return 'irrelevant';
    }
    let sawComplete = false;
    for (const section of [...sections].sort()) {
      const coverage = this.sectionCoverage.find((entry) => entry.rawSection === section);
      if (!coverage) {
        continue;
      }
      if (snapshotDiffSectionCoverageIsNotApplicableForMetrics(coverage)) {
        continue;
      }
      if (!isSectionRelevant(coverage)) {
        continue;
      }
      if (snapshotDiffSectionCoverageIsCompleteForFields(coverage, fields)) {
        sawComplete = true;
      } else {
        return 'insufficient';
      }
    }
    return sawComplete ? 'complete' : 'notApplicable';
  }
}

type DiffMetricApplicability = {
  readonly building: MetricUniverseState;
  readonly wall: MetricUniverseState;
  readonly hero: MetricUniverseState;
  readonly troop: MetricUniverseState;
  readonly spell: MetricUniverseState;
  readonly pet: MetricUniverseState;
  readonly equipment: MetricUniverseState;
  readonly hasSectionCoverage: boolean;
  readonly hasChanges: boolean;
};

const LEVEL_FIELDS = new Set(['presence', 'data', 'lvl']);
const HISTOGRAM_FIELDS = new Set(['presence', 'data', 'lvl', 'cnt']);
const BUILDING_SECTIONS = new Set(['buildings', 'buildings2', 'traps', 'traps2']);
const WALL_SECTIONS = new Set(['buildings', 'buildings2']);
const HERO_SECTIONS = new Set(['heroes', 'heroes2']);
const TROOP_SECTIONS = new Set(['units', 'units2']);

function createDiffMetricApplicability(diff: SnapshotDiff): DiffMetricApplicability {
  const evaluator = new MetricApplicabilityEvaluator(diff.sectionCoverage);
  const state = (
    sections: ReadonlySet<string>,
    fields: ReadonlySet<string>,
  ): MetricUniverseState => {
    if (diff.contentState === 'provenanceOnly') {
      return evaluator.provenanceOnlyState(sections, fields);
    }
    return evaluator.isUniverseRelevant(sections, diff)
      ? evaluator.universeState(sections, fields)
      : 'irrelevant';
  };
  return {
    building: state(BUILDING_SECTIONS, HISTOGRAM_FIELDS),
    wall: state(WALL_SECTIONS, HISTOGRAM_FIELDS),
    hero: state(HERO_SECTIONS, LEVEL_FIELDS),
    troop: state(TROOP_SECTIONS, LEVEL_FIELDS),
    spell: state(new Set(['spells']), LEVEL_FIELDS),
    pet: state(new Set(['pets']), LEVEL_FIELDS),
    equipment: state(new Set(['equipment']), LEVEL_FIELDS),
    hasSectionCoverage: diff.sectionCoverage.length > 0,
    hasChanges: diff.changes.length > 0,
  };
}

class MetricAccumulator {
  value = 0;
  hasComparableDiff = false;
  hasUnknown = false;
  overflowed = false;

  markComparable(): void {
    this.hasComparableDiff = true;
  }

  add(delta: number): void {
    const { sum, overflow } = intAddReportingOverflow(this.value, delta);
    if (overflow) {
      this.overflowed = true;
    } else {
      this.value = sum;
    }
  }

  markUnknown(): void {
    this.hasUnknown = true;
  }

  result(): SnapshotStatisticValue {
    if (this.overflowed) {
      return snapshotStatisticValueInsufficientData('统计值溢出，无法安全汇总。');
    }
    if (this.hasUnknown) {
      return snapshotStatisticValueInsufficientData('相关历史变化存在 unknown 或 coverage 不足。');
    }
    if (!this.hasComparableDiff) {
      return snapshotStatisticValueInsufficientData('窗口内没有可比较的相邻 diff。');
    }
    return snapshotStatisticValueAvailable(this.value);
  }
}

class MetricAccumulators {
  buildingCompletions = new MetricAccumulator();
  aggregateBuildingCompletions = new MetricAccumulator();
  buildingGrowth = new MetricAccumulator();
  aggregateBuildingGrowth = new MetricAccumulator();
  wallGrowth = new MetricAccumulator();
  aggregateWallGrowth = new MetricAccumulator();
  heroGrowth = new MetricAccumulator();
  troopGrowth = new MetricAccumulator();
  spellGrowth = new MetricAccumulator();
  petGrowth = new MetricAccumulator();
  equipmentGrowth = new MetricAccumulator();
  aggregateEvents = new MetricAccumulator();

  constructor(diffs: readonly SnapshotDiff[]) {
    for (const diff of diffs) {
      switch (diff.comparisonState) {
        case 'provenanceOnly':
          this.applyProvenanceOnlyContribution(diff);
          this.markUnknownForDiagnostics(diff);
          break;
        case 'comparable': {
          const diffApplicability = createDiffMetricApplicability(diff);
          this.applyDiffApplicability(diffApplicability);
          for (const change of diff.changes) {
            this.apply(change, diffApplicability);
          }
          this.markUnknownForUnclassified(diff.changes);
          this.markUnknownForUnknownCategories(diff.changes);
          this.markUnknownForDiagnostics(diff);
          break;
        }
        case 'insufficientCoverage':
        case 'suppressed':
          this.markUnknownForDiagnostics(diff);
          break;
      }
    }
  }

  private applyProvenanceOnlyContribution(diff: SnapshotDiff): void {
    const evaluator = new MetricApplicabilityEvaluator(diff.sectionCoverage);
    const apply = (
      sections: ReadonlySet<string>,
      fields: ReadonlySet<string>,
      growth: MetricAccumulator,
      aggregateGrowth?: MetricAccumulator,
    ) => {
      switch (evaluator.neutralMetricEligibility(sections, fields, diff)) {
        case 'complete':
          growth.markComparable();
          aggregateGrowth?.markComparable();
          break;
        case 'insufficient':
          growth.markUnknown();
          aggregateGrowth?.markUnknown();
          break;
        case 'notApplicable':
        case 'irrelevant':
          break;
      }
    };
    apply(BUILDING_SECTIONS, HISTOGRAM_FIELDS, this.buildingGrowth, this.aggregateBuildingGrowth);
    apply(WALL_SECTIONS, HISTOGRAM_FIELDS, this.wallGrowth, this.aggregateWallGrowth);
    apply(HERO_SECTIONS, LEVEL_FIELDS, this.heroGrowth);
    apply(TROOP_SECTIONS, LEVEL_FIELDS, this.troopGrowth);
    apply(new Set(['spells']), LEVEL_FIELDS, this.spellGrowth);
    apply(new Set(['pets']), LEVEL_FIELDS, this.petGrowth);
    apply(new Set(['equipment']), LEVEL_FIELDS, this.equipmentGrowth);
  }

  private applyDiffApplicability(applicability: DiffMetricApplicability): void {
    switch (applicability.building) {
      case 'complete':
        this.buildingCompletions.markComparable();
        this.aggregateBuildingCompletions.markComparable();
        this.buildingGrowth.markComparable();
        this.aggregateBuildingGrowth.markComparable();
        break;
      case 'insufficient':
        this.buildingCompletions.markUnknown();
        this.aggregateBuildingCompletions.markUnknown();
        this.buildingGrowth.markUnknown();
        this.aggregateBuildingGrowth.markUnknown();
        break;
      case 'notApplicable':
      case 'irrelevant':
        break;
    }
    switch (applicability.wall) {
      case 'complete':
        this.wallGrowth.markComparable();
        this.aggregateWallGrowth.markComparable();
        break;
      case 'insufficient':
        this.wallGrowth.markUnknown();
        this.aggregateWallGrowth.markUnknown();
        break;
      case 'notApplicable':
      case 'irrelevant':
        break;
    }
    switch (applicability.hero) {
      case 'complete':
        this.heroGrowth.markComparable();
        break;
      case 'insufficient':
        this.heroGrowth.markUnknown();
        break;
      case 'notApplicable':
      case 'irrelevant':
        break;
    }
    switch (applicability.troop) {
      case 'complete':
        this.troopGrowth.markComparable();
        break;
      case 'insufficient':
        this.troopGrowth.markUnknown();
        break;
      case 'notApplicable':
      case 'irrelevant':
        break;
    }
    switch (applicability.spell) {
      case 'complete':
        this.spellGrowth.markComparable();
        break;
      case 'insufficient':
        this.spellGrowth.markUnknown();
        break;
      case 'notApplicable':
      case 'irrelevant':
        break;
    }
    switch (applicability.pet) {
      case 'complete':
        this.petGrowth.markComparable();
        break;
      case 'insufficient':
        this.petGrowth.markUnknown();
        break;
      case 'notApplicable':
      case 'irrelevant':
        break;
    }
    switch (applicability.equipment) {
      case 'complete':
        this.equipmentGrowth.markComparable();
        break;
      case 'insufficient':
        this.equipmentGrowth.markUnknown();
        break;
      case 'notApplicable':
      case 'irrelevant':
        break;
    }
    if (applicability.hasSectionCoverage || applicability.hasChanges) {
      this.aggregateEvents.markComparable();
    }
  }

  private universeState(
    category: SnapshotMetricCategory,
    applicability: DiffMetricApplicability,
  ): MetricUniverseState {
    switch (category) {
      case 'building':
        return applicability.building;
      case 'wall':
        return applicability.wall;
      case 'hero':
        return applicability.hero;
      case 'troop':
        return applicability.troop;
      case 'spell':
        return applicability.spell;
      case 'pet':
        return applicability.pet;
      case 'equipment':
        return applicability.equipment;
    }
  }

  private apply(change: SnapshotChange, diffApplicability: DiffMetricApplicability): void {
    const category = metricCategoryForChange(change);
    if (!category) {
      return;
    }

    const positiveLevelDelta =
      change.levelDelta !== undefined && change.levelDelta > 0 ? change.levelDelta : undefined;

    if (change.evidence === 'aggregateInferred') {
      this.aggregateEvents.add(1);
      if (this.universeState(category, diffApplicability) !== 'complete') {
        return;
      }
      if (category === 'building' && change.changeKind === 'upgradeCompleted') {
        this.aggregateBuildingCompletions.add(1);
      }
      if (positiveLevelDelta === undefined || change.movedQuantity === undefined) {
        return;
      }
      const { product, overflow } = intMultiplyReportingOverflow(
        positiveLevelDelta,
        change.movedQuantity,
      );
      if (overflow) {
        switch (category) {
          case 'building':
            this.aggregateBuildingGrowth.overflowed = true;
            break;
          case 'wall':
            this.aggregateWallGrowth.overflowed = true;
            break;
          case 'hero':
          case 'troop':
          case 'spell':
          case 'pet':
          case 'equipment':
            break;
        }
        return;
      }
      switch (category) {
        case 'building':
          this.aggregateBuildingGrowth.add(product);
          break;
        case 'wall':
          this.aggregateWallGrowth.add(product);
          this.wallGrowth.add(product);
          break;
        case 'hero':
        case 'troop':
        case 'spell':
        case 'pet':
        case 'equipment':
          break;
      }
      return;
    }

    if (change.evidence !== 'confirmed') {
      if (change.changeKind === 'unknown' || change.levelDelta !== undefined) {
        this.markUnknown(category);
      }
      return;
    }

    if (this.universeState(category, diffApplicability) !== 'complete') {
      return;
    }

    if (positiveLevelDelta === undefined) {
      return;
    }

    switch (category) {
      case 'building':
        this.buildingGrowth.add(positiveLevelDelta);
        if (change.changeKind === 'levelIncreased' || change.changeKind === 'upgradeCompleted') {
          this.buildingCompletions.add(1);
        }
        break;
      case 'wall':
        this.wallGrowth.add(positiveLevelDelta);
        break;
      case 'hero':
        this.heroGrowth.add(positiveLevelDelta);
        break;
      case 'troop':
        this.troopGrowth.add(positiveLevelDelta);
        break;
      case 'spell':
        this.spellGrowth.add(positiveLevelDelta);
        break;
      case 'pet':
        this.petGrowth.add(positiveLevelDelta);
        break;
      case 'equipment':
        this.equipmentGrowth.add(positiveLevelDelta);
        break;
    }
  }

  private markUnknownForUnknownCategories(changes: readonly SnapshotChange[]): void {
    for (const change of changes) {
      if (change.evidence !== 'unknown' && change.coverage.state === 'complete') {
        continue;
      }
      const category = metricCategoryForChange(change);
      if (!category) {
        continue;
      }
      if (
        change.changeKind === 'unknown' ||
        change.levelDelta !== undefined ||
        change.relatedChangeKinds.includes('levelIncreased')
      ) {
        this.markUnknown(category);
        this.aggregateEvents.markUnknown();
      }
    }
  }

  private markUnknownForUnclassified(changes: readonly SnapshotChange[]): void {
    for (const change of changes) {
      if (metricCategoryForChange(change)) {
        continue;
      }
      const section = change.identity.rawSection.endsWith('2')
        ? change.identity.rawSection.slice(0, -1)
        : change.identity.rawSection;
      this.markUnknownForSection(section);
    }
  }

  private markUnknownForDiagnostics(diff: SnapshotDiff): void {
    const relevant = diff.diagnostics.filter((diagnostic) => {
      switch (diagnostic.kind) {
        case 'insufficientCoverage':
        case 'unknownIdentity':
        case 'malformedObservation':
          return true;
        case 'baseline':
        case 'villageMismatch':
        case 'lineageMismatch':
        case 'duplicateSnapshotID':
        case 'mixedLineageInput':
        case 'incomparableTimerSchema':
          return false;
      }
    });
    if (relevant.length === 0) {
      return;
    }

    for (const diagnostic of relevant) {
      if (diagnostic.identity) {
        const matched = diff.changes.find(
          (change) =>
            snapshotItemIdentityKey(change.identity) ===
            snapshotItemIdentityKey(diagnostic.identity!),
        );
        if (matched) {
          const category = metricCategoryForChange(matched);
          if (category) {
            this.markUnknown(category);
            continue;
          }
        }
      }
      if (diagnostic.rawSection ?? diagnostic.identity?.rawSection) {
        this.markUnknownForSection(diagnostic.rawSection ?? diagnostic.identity!.rawSection);
      } else {
        this.markAllUnknown();
      }
    }
  }

  private markUnknownForSection(section: string): void {
    const normalized = section.endsWith('2') ? section.slice(0, -1) : section;
    switch (normalized) {
      case 'buildings':
        this.buildingCompletions.markUnknown();
        this.aggregateBuildingCompletions.markUnknown();
        this.buildingGrowth.markUnknown();
        this.aggregateBuildingGrowth.markUnknown();
        this.wallGrowth.markUnknown();
        this.aggregateWallGrowth.markUnknown();
        break;
      case 'traps':
        this.buildingCompletions.markUnknown();
        this.aggregateBuildingCompletions.markUnknown();
        this.buildingGrowth.markUnknown();
        this.aggregateBuildingGrowth.markUnknown();
        break;
      case 'heroes':
        this.heroGrowth.markUnknown();
        break;
      case 'units':
        this.troopGrowth.markUnknown();
        break;
      case 'spells':
        this.spellGrowth.markUnknown();
        break;
      case 'pets':
        this.petGrowth.markUnknown();
        break;
      case 'equipment':
        this.equipmentGrowth.markUnknown();
        break;
    }
  }

  private markAllUnknown(): void {
    this.buildingCompletions.markUnknown();
    this.aggregateBuildingCompletions.markUnknown();
    this.buildingGrowth.markUnknown();
    this.aggregateBuildingGrowth.markUnknown();
    this.wallGrowth.markUnknown();
    this.aggregateWallGrowth.markUnknown();
    this.heroGrowth.markUnknown();
    this.troopGrowth.markUnknown();
    this.spellGrowth.markUnknown();
    this.petGrowth.markUnknown();
    this.equipmentGrowth.markUnknown();
  }

  private markUnknown(category: SnapshotMetricCategory): void {
    switch (category) {
      case 'building':
        this.buildingGrowth.markUnknown();
        this.buildingCompletions.markUnknown();
        this.aggregateBuildingCompletions.markUnknown();
        this.aggregateBuildingGrowth.markUnknown();
        break;
      case 'wall':
        this.wallGrowth.markUnknown();
        this.aggregateWallGrowth.markUnknown();
        break;
      case 'hero':
        this.heroGrowth.markUnknown();
        break;
      case 'troop':
        this.troopGrowth.markUnknown();
        break;
      case 'spell':
        this.spellGrowth.markUnknown();
        break;
      case 'pet':
        this.petGrowth.markUnknown();
        break;
      case 'equipment':
        this.equipmentGrowth.markUnknown();
        break;
    }
  }
}

function metricCategoryForChange(change: SnapshotChange): SnapshotMetricCategory | null {
  if (!change.category) {
    return null;
  }
  const section = change.identity.rawSection.endsWith('2')
    ? change.identity.rawSection.slice(0, -1)
    : change.identity.rawSection;
  switch (section) {
    case 'buildings':
    case 'traps':
      if (change.category !== section || change.identity.nestedKind !== 'root') {
        return null;
      }
      if (section === 'buildings' && change.displayCategory === 'walls') {
        return 'wall';
      }
      return 'building';
    case 'heroes':
      return change.category === 'heroes' && change.identity.nestedKind === 'root' ? 'hero' : null;
    case 'units':
      return change.category === 'troops' && change.identity.nestedKind === 'root' ? 'troop' : null;
    case 'spells':
      return change.category === 'spells' && change.identity.nestedKind === 'root' ? 'spell' : null;
    case 'pets':
      return change.category === 'pets' && change.identity.nestedKind === 'root' ? 'pet' : null;
    case 'equipment':
      return change.category === 'equipment' && change.identity.nestedKind === 'root'
        ? 'equipment'
        : null;
    default:
      return null;
  }
}

function makeWindow(
  diffs: readonly SnapshotDiff[],
  start: Date,
  end: Date,
): SnapshotHistoryStatisticsWindow {
  const windowDiffs = diffs.filter((diff) => diff.toAppliedAt >= start && diff.toAppliedAt <= end);
  const accumulators = new MetricAccumulators(windowDiffs);
  return {
    startRefSeconds: dateToRefSeconds(start),
    endRefSeconds: dateToRefSeconds(end),
    buildingUpgradeCompletions: accumulators.buildingCompletions.result(),
    aggregateInferredBuildingUpgradeCompletions: accumulators.aggregateBuildingCompletions.result(),
    buildingLevelGrowth: accumulators.buildingGrowth.result(),
    aggregateInferredBuildingLevelGrowth: accumulators.aggregateBuildingGrowth.result(),
    wallLevelGrowth: accumulators.wallGrowth.result(),
    aggregateInferredWallLevelGrowth: accumulators.aggregateWallGrowth.result(),
    heroLevelGrowth: accumulators.heroGrowth.result(),
    troopLevelGrowth: accumulators.troopGrowth.result(),
    spellLevelGrowth: accumulators.spellGrowth.result(),
    petLevelGrowth: accumulators.petGrowth.result(),
    heroEquipmentLevelGrowth: accumulators.equipmentGrowth.result(),
    aggregateInferredEventCount: accumulators.aggregateEvents.result(),
  };
}

export function calculateSnapshotHistoryStatistics(
  diffs: readonly SnapshotDiff[],
  referenceDateRefSeconds: number,
  timeZoneIdentifier?: string,
): SnapshotHistoryStatistics {
  const timeZone = resolvedTimeZoneIdentifier(timeZoneIdentifier);
  const referenceDate = refSecondsToDate(referenceDateRefSeconds);
  const startOfToday = startOfDayInTimeZone(referenceDate, timeZone);
  const sevenStart = addCalendarDays(startOfToday, -6, timeZone);
  const thirtyStart = addCalendarDays(startOfToday, -29, timeZone);

  const diagnostics: string[] = [];
  const identities = new Set(diffs.map((diff) => `${diff.villageID}|${diff.lineageID}`));
  const inputIsSingleLineage = identities.size <= 1;
  if (!inputIsSingleLineage) {
    diagnostics.push('统计输入包含多个 village/lineage；必须先按同一 village/lineage 分组。');
  }
  if (diffs.length === 0) {
    diagnostics.push('没有可比较的相邻 diff。');
  }
  const usableDiffs = inputIsSingleLineage ? diffs : [];

  return {
    referenceDateRefSeconds,
    timeZoneIdentifier: timeZone,
    today: makeWindow(usableDiffs, startOfToday, referenceDate),
    last7Days: makeWindow(usableDiffs, sevenStart, referenceDate),
    last30Days: makeWindow(usableDiffs, thirtyStart, referenceDate),
    diagnostics: [...new Set(diagnostics)].sort(),
  };
}
