import { parseUuid, type UuidString } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { calculateSnapshotHistoryStatistics, confirmedWallLevelGrowth } from './diff-statistics';
import { SnapshotDiffEngine, createSnapshotObservationItem } from './diff-engine';
import { SNAPSHOT_HISTORY_SCHEMA } from './schema';
import {
  hydrateVerifiedCoverageOnEntry,
  type HydratedSnapshotHistoryEntry,
} from './trust-hydration';
import {
  createSnapshotItemIdentity,
  issueTestCoverageProof,
  snapshotHistoryBaseFromSection,
  type SnapshotCoverageField,
  type SnapshotCoverageProof,
  type SnapshotCoverageState,
  type SnapshotObservationCoverage,
  type SnapshotObservationItem,
  type SnapshotSectionCoverage,
  type SnapshotSectionPresence,
} from './types';

const VILLAGE_A = parseUuid('11111111-1111-1111-1111-111111111111')!;
const VILLAGE_B = parseUuid('44444444-4444-4444-4444-444444444444')!;
const LINEAGE_A = parseUuid('22222222-2222-2222-2222-222222222222')!;
const LINEAGE_B = parseUuid('33333333-3333-3333-3333-333333333333')!;
const UTC = 'UTC';

type MetricTestSectionCoverage = {
  section: string;
  states?: Record<string, SnapshotCoverageState>;
  proof?: SnapshotCoverageProof;
  presence?: SnapshotSectionPresence;
};

function makeIdentity(section: string, dataID: number) {
  return createSnapshotItemIdentity(section, dataID);
}

function makeItem(
  identity: ReturnType<typeof makeIdentity>,
  level?: number,
  count?: number,
  display: { displayName?: string; category?: string; displayCategory?: string } = {},
  timer?: number,
) {
  return createSnapshotObservationItem({ identity, level, count, display, timer });
}

function wallBinding() {
  return { displayName: '城墙', category: 'buildings', displayCategory: 'walls' as const };
}

function notApplicable(section: string): MetricTestSectionCoverage {
  return {
    section,
    states: {},
    proof: issueTestCoverageProof('test-export', 0),
    presence: 'presentEmpty',
  };
}

const buildingUniverseNotApplicable = [
  notApplicable('traps'),
  notApplicable('buildings2'),
  notApplicable('traps2'),
];

const wallUniverseNotApplicable = [notApplicable('buildings2')];

function makeEntry(input: {
  id: string;
  date: number;
  items: SnapshotObservationItem[];
  section: string | null;
  states?: Record<string, SnapshotCoverageState>;
  proof?: SnapshotCoverageProof;
  presence?: SnapshotSectionPresence;
  additionalSections?: MetricTestSectionCoverage[];
  villageID?: UuidString;
  lineageID?: UuidString;
}): HydratedSnapshotHistoryEntry {
  const snapshotID = parseUuid(input.id)!;
  let coverage: SnapshotObservationCoverage;
  if (input.section) {
    const defaults: Record<string, SnapshotCoverageState> = {
      presence: 'complete',
      data: 'complete',
      lvl: 'complete',
    };
    const sectionCoverages: SnapshotSectionCoverage[] = [];
    const fields: SnapshotCoverageField[] = [];

    const appendSection = (spec: MetricTestSectionCoverage) => {
      const merged = { ...defaults, ...spec.states };
      const observedCount = input.items.filter(
        (item) => item.identity.rawSection === spec.section,
      ).length;
      const presence = observedCount === 0 ? (spec.presence ?? 'presentEmpty') : 'presentNonEmpty';
      const base = snapshotHistoryBaseFromSection(spec.section);
      sectionCoverages.push({
        base,
        rawSection: spec.section,
        presence,
        completeness: 'complete',
        proof: spec.proof ?? issueTestCoverageProof(),
        observedCount,
      });
      for (const [field, state] of Object.entries(merged)) {
        fields.push({
          base,
          rawSection: spec.section,
          field,
          state,
        });
      }
    };

    appendSection({
      section: input.section,
      states: input.states,
      proof: input.proof ?? issueTestCoverageProof(),
      presence:
        input.presence ??
        (input.items.filter((item) => item.identity.rawSection === input.section).length
          ? 'presentNonEmpty'
          : 'presentEmpty'),
    });
    for (const spec of input.additionalSections ?? []) {
      appendSection(spec);
    }
    coverage = {
      schemaVersion: SNAPSHOT_HISTORY_SCHEMA.observation,
      fields,
      sections: sectionCoverages,
      diagnostics: [],
      sourceUniverse: null,
    };
  } else {
    coverage = {
      schemaVersion: SNAPSHOT_HISTORY_SCHEMA.observation,
      fields: [],
      sections: [],
      diagnostics: [],
      sourceUniverse: null,
    };
  }

  const entry = {
    schemaVersion: SNAPSHOT_HISTORY_SCHEMA.entry,
    observationVersion: SNAPSHOT_HISTORY_SCHEMA.observation,
    snapshotID,
    villageID: input.villageID ?? VILLAGE_A,
    lineageID: input.lineageID ?? LINEAGE_A,
    normalizedPlayerTag: '#TEST',
    appliedAtRefSeconds: input.date,
    sourceTimestampRefSeconds: null,
    parserVersion: 'test',
    rawJSON: '{}',
    observation: {
      schemaVersion: SNAPSHOT_HISTORY_SCHEMA.observation,
      rawTopLevelFields: {},
      unknownTopLevelFields: {},
      items: input.items,
    },
    coverage,
    isBaseline: false,
    baselineReason: null,
    timerSchema: null,
  };

  const hydrated = hydrateVerifiedCoverageOnEntry({
    entry,
    policy: 'testsAllowTestFixture',
  });
  return {
    ...hydrated,
    coverage: {
      ...hydrated.coverage,
      sections: hydrated.coverage.sections.map((section) => ({
        ...section,
        runtimeTrust:
          section.proof.kind === 'verified' ? { kind: 'trusted' } : section.runtimeTrust,
      })),
    },
  };
}

describe('calculateSnapshotHistoryStatistics', () => {
  it('empty diffs report insufficient metrics and diagnostics', () => {
    const statistics = calculateSnapshotHistoryStatistics([], 200, UTC);
    expect(statistics.today.heroLevelGrowth.state).toBe('insufficientData');
    expect(statistics.diagnostics).toEqual(['没有可比较的相邻 diff。']);
  });

  it('multi-lineage input emits diagnostic and skips aggregation', () => {
    const identity = makeIdentity('heroes', 1);
    const heroBinding = { displayName: '英雄', category: 'heroes' };
    const oldA = makeEntry({
      id: 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',
      date: 100,
      items: [makeItem(identity, 1, undefined, heroBinding)],
      section: 'heroes',
      villageID: VILLAGE_A,
      lineageID: LINEAGE_A,
    });
    const newA = makeEntry({
      id: 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB',
      date: 200,
      items: [makeItem(identity, 2, undefined, heroBinding)],
      section: 'heroes',
      villageID: VILLAGE_A,
      lineageID: LINEAGE_A,
    });
    const oldB = makeEntry({
      id: 'CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC',
      date: 100,
      items: [makeItem(identity, 1, undefined, heroBinding)],
      section: 'heroes',
      villageID: VILLAGE_B,
      lineageID: LINEAGE_B,
    });
    const newB = makeEntry({
      id: 'DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD',
      date: 200,
      items: [makeItem(identity, 2, undefined, heroBinding)],
      section: 'heroes',
      villageID: VILLAGE_B,
      lineageID: LINEAGE_B,
    });
    const diffA = SnapshotDiffEngine.compare(oldA, newA);
    const diffB = SnapshotDiffEngine.compare(oldB, newB);

    const statistics = calculateSnapshotHistoryStatistics([diffA, diffB], 200, UTC);
    expect(statistics.diagnostics).toEqual([
      '统计输入包含多个 village/lineage；必须先按同一 village/lineage 分组。',
    ]);
    expect(statistics.today.heroLevelGrowth.state).toBe('insufficientData');
  });

  it('histogram timer completion keeps confirmed and aggregate metrics separate', () => {
    const identity = makeIdentity('buildings', 1);
    const binding = { displayName: '加农炮', category: 'buildings' };
    const old = makeEntry({
      id: 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',
      date: 100,
      items: [makeItem(identity, 14, 2, binding, 90)],
      section: 'buildings',
      states: { cnt: 'complete', timer: 'complete' },
      additionalSections: buildingUniverseNotApplicable,
    });
    const newEntry = makeEntry({
      id: 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB',
      date: 200,
      items: [makeItem(identity, 15, 2, binding)],
      section: 'buildings',
      states: { cnt: 'complete', timer: 'complete' },
      additionalSections: buildingUniverseNotApplicable,
    });
    const diff = SnapshotDiffEngine.compare(old, newEntry);
    expect(diff.changes.some((change) => change.changeKind === 'upgradeCompleted')).toBe(true);

    const statistics = calculateSnapshotHistoryStatistics([diff], 200, UTC);
    expect(statistics.today.buildingUpgradeCompletions).toEqual({
      state: 'available',
      value: 0,
    });
    expect(statistics.today.aggregateInferredBuildingUpgradeCompletions.value).toBe(1);
    expect(statistics.today.aggregateInferredEventCount.value).toBe(2);
    expect(statistics.today.aggregateInferredBuildingLevelGrowth.value).toBe(2);
  });

  it('wall histogram keeps aggregate evidence separate and partitions confirmed growth', () => {
    const identity = makeIdentity('buildings', 8);
    const old = makeEntry({
      id: 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',
      date: 100,
      items: [
        makeItem(identity, 12, 100, wallBinding()),
        makeItem(identity, 13, 50, wallBinding()),
      ],
      section: 'buildings',
      states: { cnt: 'complete' },
      additionalSections: wallUniverseNotApplicable,
    });
    const newEntry = makeEntry({
      id: 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB',
      date: 200,
      items: [makeItem(identity, 12, 80, wallBinding()), makeItem(identity, 13, 70, wallBinding())],
      section: 'buildings',
      states: { cnt: 'complete' },
      additionalSections: wallUniverseNotApplicable,
    });
    const diff = SnapshotDiffEngine.compare(old, newEntry);
    const statistics = calculateSnapshotHistoryStatistics([diff], 200, UTC);

    expect(statistics.today.wallLevelGrowth.value).toBe(20);
    expect(statistics.today.aggregateInferredWallLevelGrowth.value).toBe(20);
    expect(statistics.today.aggregateInferredEventCount.value).toBe(1);
    expect(statistics.today.buildingLevelGrowth.state).toBe('insufficientData');
    expect(confirmedWallLevelGrowth(statistics.today)).toEqual({
      state: 'available',
      value: 0,
    });
  });

  it('confirmed wall partition subtracts aggregate inferred from total growth', () => {
    const wallIdentity = makeIdentity('buildings', 8);
    const buildingIdentity = makeIdentity('buildings', 1);
    const buildingBinding = { displayName: '加农炮', category: 'buildings' };
    const old = makeEntry({
      id: 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',
      date: 100,
      items: [
        makeItem(wallIdentity, 12, 1, wallBinding()),
        makeItem(buildingIdentity, 1, 1, buildingBinding),
      ],
      section: 'buildings',
      states: { cnt: 'complete' },
      additionalSections: buildingUniverseNotApplicable,
    });
    const newEntry = makeEntry({
      id: 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB',
      date: 200,
      items: [
        makeItem(wallIdentity, 13, 1, wallBinding()),
        makeItem(buildingIdentity, 2, 1, buildingBinding),
      ],
      section: 'buildings',
      states: { cnt: 'complete' },
      additionalSections: buildingUniverseNotApplicable,
    });
    const diff = SnapshotDiffEngine.compare(old, newEntry);
    const statistics = calculateSnapshotHistoryStatistics([diff], 200, UTC);

    expect(statistics.today.wallLevelGrowth.value).toBe(1);
    expect(statistics.today.aggregateInferredWallLevelGrowth.value).toBe(1);
    expect(confirmedWallLevelGrowth(statistics.today)).toEqual({
      state: 'available',
      value: 0,
    });
  });
});
