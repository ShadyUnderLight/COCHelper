import { parseUuid, type UuidString } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { SNAPSHOT_DIFF_ALGORITHM_VERSION } from './diff-types';
import { compareSnapshotChanges } from './diff-ordering';
import { SnapshotDiffEngine, createSnapshotObservationItem } from './diff-engine';
import { SNAPSHOT_HISTORY_SCHEMA } from './schema';
import {
  hydrateVerifiedCoverageOnEntry,
  type HydratedSnapshotHistoryEntry,
} from './trust-hydration';
import {
  createSnapshotItemIdentity,
  snapshotHistoryBaseFromSection,
  snapshotItemIdentityKey,
  type SnapshotCoverageField,
  type SnapshotCoverageProof,
  type SnapshotCoverageState,
  type SnapshotObservationCoverage,
  type SnapshotObservationItem,
  type SnapshotSectionCoverage,
  type SnapshotSectionPresence,
  type SnapshotTimerSchema,
} from './types';

const VILLAGE_ID = parseUuid('11111111-1111-1111-1111-111111111111')!;
const LINEAGE_ID = parseUuid('22222222-2222-2222-2222-222222222222')!;

function issueTestCoverageProof(
  source = 'test-export',
  expectedCount: number | null = null,
): SnapshotCoverageProof {
  return {
    kind: 'verified',
    source,
    adapterID: 'test-fixture',
    protocolVersion: '1',
    expectedCount,
    verificationReason: 'test injection',
    verificationRuleVersion: '1',
  };
}

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
) {
  return createSnapshotObservationItem({ identity, level, count, display });
}

function wallBinding() {
  return { displayName: '城墙', category: 'buildings', displayCategory: 'walls' };
}

function makeEntry(input: {
  id: string;
  date: number;
  items: SnapshotObservationItem[];
  section: string | null;
  states?: Record<string, SnapshotCoverageState>;
  proof?: SnapshotCoverageProof;
  presence?: SnapshotSectionPresence;
  additionalSections?: MetricTestSectionCoverage[];
  diagnostics?: string[];
  villageID?: UuidString;
  lineageID?: UuidString;
  sourceTimestampRefSeconds?: number | null;
  isBaseline?: boolean;
  timerSchema?: SnapshotTimerSchema;
  observationVersion?: number;
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
      diagnostics: input.diagnostics ?? [],
      sourceUniverse: null,
    };
  } else {
    coverage = {
      schemaVersion: SNAPSHOT_HISTORY_SCHEMA.observation,
      fields: [],
      sections: [],
      diagnostics: input.diagnostics ?? [],
      sourceUniverse: null,
    };
  }

  const entry = {
    schemaVersion: SNAPSHOT_HISTORY_SCHEMA.entry,
    observationVersion: input.observationVersion ?? SNAPSHOT_HISTORY_SCHEMA.observation,
    snapshotID,
    villageID: input.villageID ?? VILLAGE_ID,
    lineageID: input.lineageID ?? LINEAGE_ID,
    normalizedPlayerTag: '#TEST',
    appliedAtRefSeconds: input.date,
    sourceTimestampRefSeconds: input.sourceTimestampRefSeconds ?? null,
    parserVersion: 'test',
    rawJSON: '{}',
    observation: {
      schemaVersion: SNAPSHOT_HISTORY_SCHEMA.observation,
      rawTopLevelFields: {},
      unknownTopLevelFields: {},
      items: input.items,
    },
    coverage,
    isBaseline: input.isBaseline ?? false,
    baselineReason: null,
    timerSchema: input.timerSchema ?? null,
  };

  return trustTestEntry(entry);
}

function trustTestEntry(
  entry: Omit<HydratedSnapshotHistoryEntry, 'coverage'> & {
    coverage: SnapshotObservationCoverage;
  },
): HydratedSnapshotHistoryEntry {
  const hydrated = hydrateVerifiedCoverageOnEntry({
    entry: entry as HydratedSnapshotHistoryEntry,
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

function single<T>(values: readonly T[]): T | undefined {
  return values.length === 1 ? values[0] : undefined;
}

describe('SnapshotDiffEngine', () => {
  it('partial coverage must not produce noLongerObserved', () => {
    const firstIdentity = makeIdentity('heroes', 1);
    const secondIdentity = makeIdentity('heroes', 2);
    const oldEntry = makeEntry({
      id: 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',
      date: 100,
      items: [makeItem(firstIdentity, 1)],
      section: 'heroes',
    });
    const newEntry = makeEntry({
      id: 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB',
      date: 200,
      items: [makeItem(firstIdentity, 1), makeItem(secondIdentity, 2)],
      section: 'heroes',
    });

    const missingDiff = SnapshotDiffEngine.compare(oldEntry, newEntry);
    const missingChange = missingDiff.changes.find(
      (change) =>
        snapshotItemIdentityKey(change.identity) === snapshotItemIdentityKey(secondIdentity),
    );
    expect(missingChange?.changeKind).toBe('newlyObserved');
    expect(missingChange?.evidence).toBe('confirmed');

    const missingSectionEntry = makeEntry({
      id: 'CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC',
      date: 300,
      items: [],
      section: null,
    });
    const insufficient = SnapshotDiffEngine.compare(missingSectionEntry, newEntry);
    const unknown = insufficient.changes.find(
      (change) =>
        snapshotItemIdentityKey(change.identity) === snapshotItemIdentityKey(firstIdentity),
    );
    expect(unknown?.changeKind).toBe('unknown');
    expect(unknown?.evidence).toBe('unknown');
    expect(unknown?.coverage.state).toBe('insufficient');
    expect(insufficient.comparisonState).toBe('insufficientCoverage');
    expect(insufficient.changes.some((change) => change.changeKind === 'noLongerObserved')).toBe(
      false,
    );
  });

  it('histogram residual fail-closed does not emit noLongerObserved', () => {
    const identity = makeIdentity('buildings', 8);
    const diff = SnapshotDiffEngine.compare(
      makeEntry({
        id: 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',
        date: 100,
        items: [makeItem(identity, 10, 1, wallBinding()), makeItem(identity, 12, 1, wallBinding())],
        section: 'buildings',
        states: { cnt: 'complete' },
      }),
      makeEntry({
        id: 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB',
        date: 200,
        items: [makeItem(identity, 11, 1, wallBinding())],
        section: 'buildings',
        states: { cnt: 'complete' },
      }),
    );

    expect(diff.changes).toHaveLength(1);
    expect(single(diff.changes)?.changeKind).toBe('unknown');
    expect(diff.changes.some((change) => change.changeKind === 'noLongerObserved')).toBe(false);
  });

  it('partial buildings coverage keeps missing unique identity as unknown', () => {
    const first = makeIdentity('buildings', 1000013);
    const second = makeIdentity('buildings', 1000016);
    const diff = SnapshotDiffEngine.compare(
      makeEntry({
        id: 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',
        date: 100,
        items: [makeItem(first, 1), makeItem(second, 1)],
        section: 'buildings',
        states: { lvl: 'complete' },
      }),
      makeEntry({
        id: 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB',
        date: 200,
        items: [makeItem(first, 2)],
        section: 'buildings',
        states: { lvl: 'complete' },
      }),
    );

    expect(diff.changes).toHaveLength(2);
    expect(diff.changes.every((change) => change.changeKind === 'unknown')).toBe(true);
    expect(diff.changes.some((change) => change.changeKind === 'noLongerObserved')).toBe(false);
  });

  it('provenance-only compatible schema version keeps empty diff', () => {
    const identity = makeIdentity('heroes', 1);
    const item = createSnapshotObservationItem({
      identity,
      level: 1,
      timer: 90,
      display: { displayName: '英雄', category: 'heroes' },
    });
    const schema = (version: string): SnapshotTimerSchema => ({
      version,
      fields: {
        timer: { unit: 'seconds', semantics: 'remaining', minValue: 0 },
      },
    });
    const diff = SnapshotDiffEngine.compare(
      makeEntry({
        id: 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',
        date: 100,
        items: [item],
        section: 'heroes',
        states: { timer: 'complete' },
        sourceTimestampRefSeconds: 100,
        timerSchema: schema('timer-1'),
      }),
      makeEntry({
        id: 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB',
        date: 105,
        items: [item],
        section: 'heroes',
        states: { timer: 'complete' },
        sourceTimestampRefSeconds: 105,
        timerSchema: schema('timer-2'),
      }),
    );

    expect(diff.changes).toHaveLength(0);
    expect(diff.comparisonState).toBe('provenanceOnly');
    expect(diff.contentState).toBe('provenanceOnly');
    expect(
      diff.diagnostics.some((diagnostic) => diagnostic.kind === 'incomparableTimerSchema'),
    ).toBe(false);
  });

  it('provenance-only incompatible schema records incomparable timer diagnostic', () => {
    const identity = makeIdentity('heroes', 1);
    const item = createSnapshotObservationItem({
      identity,
      level: 1,
      timer: 90,
      display: { displayName: '英雄', category: 'heroes' },
    });
    const seconds: SnapshotTimerSchema = {
      version: 'seconds-schema',
      fields: { timer: { unit: 'seconds', semantics: 'remaining' } },
    };
    const millis: SnapshotTimerSchema = {
      version: 'millis-schema',
      fields: { timer: { unit: 'milliseconds', semantics: 'remaining' } },
    };
    const diff = SnapshotDiffEngine.compare(
      makeEntry({
        id: 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',
        date: 100,
        items: [item],
        section: 'heroes',
        states: { timer: 'complete' },
        sourceTimestampRefSeconds: 100,
        timerSchema: seconds,
      }),
      makeEntry({
        id: 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB',
        date: 105,
        items: [item],
        section: 'heroes',
        states: { timer: 'complete' },
        sourceTimestampRefSeconds: 105,
        timerSchema: millis,
      }),
    );

    expect(diff.changes).toHaveLength(0);
    expect(diff.comparisonState).toBe('provenanceOnly');
    expect(diff.contentState).toBe('provenanceOnly');
    expect(
      diff.diagnostics.filter((diagnostic) => diagnostic.kind === 'incomparableTimerSchema'),
    ).toHaveLength(1);
  });

  it('missing section coverage does not confirm disappearance', () => {
    const identity = makeIdentity('heroes', 1);
    const unavailableProof = { kind: 'unavailable' as const, reason: 'no proof' };
    const oldEntry = makeEntry({
      id: 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',
      date: 100,
      items: [makeItem(identity, 1)],
      section: 'heroes',
      proof: unavailableProof,
    });
    const emptyEntry = makeEntry({
      id: 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB',
      date: 200,
      items: [],
      section: 'heroes',
      proof: unavailableProof,
      presence: 'presentEmpty',
    });

    const diff = SnapshotDiffEngine.compare(oldEntry, emptyEntry);
    expect(single(diff.changes)?.changeKind).toBe('unknown');
    expect(single(diff.changes)?.evidence).toBe('unknown');
    expect(single(diff.changes)?.coverage.state).toBe('insufficient');
    expect(diff.diagnostics.some((diagnostic) => diagnostic.kind === 'insufficientCoverage')).toBe(
      true,
    );
  });

  it('verified section proof allows confirmed disappearance', () => {
    const identity = makeIdentity('heroes', 1);
    const oldEntry = makeEntry({
      id: 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',
      date: 100,
      items: [makeItem(identity, 1)],
      section: 'heroes',
      proof: issueTestCoverageProof('test-export', 1),
      presence: 'presentNonEmpty',
    });
    const emptyEntry = makeEntry({
      id: 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB',
      date: 200,
      items: [],
      section: 'heroes',
      proof: issueTestCoverageProof('test-export', 0),
      presence: 'presentEmpty',
    });

    const diff = SnapshotDiffEngine.compare(oldEntry, emptyEntry);
    expect(single(diff.changes)?.changeKind).toBe('noLongerObserved');
    expect(single(diff.changes)?.evidence).toBe('confirmed');
    expect(diff.comparisonState).toBe('comparable');
  });

  it('present non-empty without proof does not confirm newly observed', () => {
    const identity = makeIdentity('heroes', 1);
    const emptyEntry = makeEntry({
      id: 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',
      date: 100,
      items: [],
      section: 'heroes',
      presence: 'presentEmpty',
      proof: { kind: 'unavailable', reason: 'no proof' },
    });
    const nonEmptyEntry = makeEntry({
      id: 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB',
      date: 200,
      items: [makeItem(identity, 2)],
      section: 'heroes',
      presence: 'presentNonEmpty',
      proof: { kind: 'unavailable', reason: 'no proof' },
    });

    const diff = SnapshotDiffEngine.compare(emptyEntry, nonEmptyEntry);
    expect(single(diff.changes)?.changeKind).toBe('unknown');
    expect(single(diff.changes)?.evidence).toBe('unknown');
    expect(single(diff.changes)?.coverage.state).toBe('insufficient');
  });

  it('histogram migration is stable under item reordering', () => {
    const identity = makeIdentity('buildings', 8);
    const oldItems = [
      makeItem(identity, 12, 100, wallBinding()),
      makeItem(identity, 13, 50, wallBinding()),
    ];
    const newItems = [
      makeItem(identity, 13, 70, wallBinding()),
      makeItem(identity, 12, 80, wallBinding()),
    ];
    const oldEntry = makeEntry({
      id: 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',
      date: 100,
      items: oldItems,
      section: 'buildings',
      states: { cnt: 'complete' },
    });
    const newEntry = makeEntry({
      id: 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB',
      date: 200,
      items: newItems,
      section: 'buildings',
      states: { cnt: 'complete' },
    });

    const diff = SnapshotDiffEngine.compare(oldEntry, newEntry);
    const reordered = SnapshotDiffEngine.compare(
      oldEntry,
      makeEntry({
        id: 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB',
        date: 200,
        items: [...newItems].reverse(),
        section: 'buildings',
        states: { cnt: 'complete' },
      }),
    );

    expect(reordered.changes).toEqual(diff.changes);
    expect(single(diff.changes)?.changeKind).toBe('levelIncreased');
    expect(single(diff.changes)?.evidence).toBe('aggregateInferred');
    expect(diff.algorithmVersion).toBe(SNAPSHOT_DIFF_ALGORITHM_VERSION);
  });

  it('sorts changes with stable ordering', () => {
    const left = {
      identity: makeIdentity('heroes', 2),
      displayName: 'B',
      base: 'home' as const,
      changeKind: 'levelIncreased' as const,
      relatedChangeKinds: [],
      evidence: 'confirmed' as const,
      coverage: { state: 'complete' as const, fields: [], reasons: [] },
      oldLevel: 1,
      newLevel: 2,
    };
    const right = {
      ...left,
      identity: makeIdentity('heroes', 1),
      displayName: 'A',
    };
    expect(compareSnapshotChanges(right, left)).toBeLessThan(0);
  });

  it('adjacentDiffs 仅比较相邻同 lineage entry', () => {
    const first = makeEntry({
      id: 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',
      date: 100,
      items: [makeItem(makeIdentity('heroes', 1), 1)],
      section: 'heroes',
    });
    const second = makeEntry({
      id: 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB',
      date: 200,
      items: [makeItem(makeIdentity('heroes', 1), 2)],
      section: 'heroes',
    });
    const otherLineage = makeEntry({
      id: 'CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC',
      date: 150,
      items: [makeItem(makeIdentity('heroes', 1), 1)],
      section: 'heroes',
      lineageID: parseUuid('33333333-3333-3333-3333-333333333333')!,
    });

    expect(SnapshotDiffEngine.adjacentDiffs([first])).toHaveLength(0);
    expect(SnapshotDiffEngine.adjacentDiffs([first, second])).toHaveLength(1);
    expect(SnapshotDiffEngine.adjacentDiffs([first, otherLineage, second])).toHaveLength(0);
    expect(SnapshotDiffEngine.adjacentDiffs([second, first])).toHaveLength(1);
  });

  it('adjacentDiffs A→B→A 保留 +1/-1 levelDelta', () => {
    const identity = makeIdentity('heroes', 1);
    const first = makeEntry({
      id: 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',
      date: 100,
      items: [makeItem(identity, 1)],
      section: 'heroes',
    });
    const second = makeEntry({
      id: 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB',
      date: 200,
      items: [makeItem(identity, 2)],
      section: 'heroes',
    });
    const third = makeEntry({
      id: 'CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC',
      date: 300,
      items: [makeItem(identity, 1)],
      section: 'heroes',
    });

    const diffs = SnapshotDiffEngine.adjacentDiffs([first, second, third]);
    expect(diffs).toHaveLength(2);
    expect(diffs.map((diff) => diff.changes[0]?.levelDelta)).toEqual([1, -1]);
  });

  it('跨 lineage compare 被 suppressed', () => {
    const identity = makeIdentity('heroes', 1);
    const third = makeEntry({
      id: 'CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC',
      date: 300,
      items: [makeItem(identity, 1)],
      section: 'heroes',
    });
    const otherLineage = makeEntry({
      id: 'DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD',
      date: 400,
      items: [makeItem(identity, 3)],
      section: 'heroes',
      lineageID: parseUuid('33333333-3333-3333-3333-333333333333')!,
    });

    const suppressed = SnapshotDiffEngine.compare(third, otherLineage);
    expect(suppressed.comparisonState).toBe('suppressed');
    expect(suppressed.changes).toHaveLength(0);
    expect(suppressed.diagnostics.some((item) => item.kind === 'lineageMismatch')).toBe(true);
  });
});
