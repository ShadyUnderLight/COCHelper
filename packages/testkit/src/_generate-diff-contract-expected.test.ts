import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

import {
  SnapshotDiffEngine,
  canonicalizeSnapshotHistory,
  encodeHistoryEntryWire,
  historyEntryWireHex,
  hydrateVerifiedCoverageOnEntry,
  parseAccountSnapshot,
  snapshotDiffWireHex,
} from '@coc-helper/domain';
import { bytesToHex, canonicalBytes, canonicalize, parseJson, parseUuid } from '@coc-helper/wire';
import { describe, it } from 'vitest';

import { loadGoldenManifest, readGoldenFixture } from './manifest';
import { createSwiftOracleRunner, SWIFT_ORACLE_PROTOCOL_VERSION } from './oracle';

type DiffContractEntry = {
  readonly text: string;
  readonly appliedAtRefSeconds: number;
  readonly snapshotID: string;
  readonly lineageID?: string;
};

type DiffContract = {
  readonly importedAtRefSeconds: number;
  readonly villageID: string;
  readonly lineageID: string;
  readonly canonicalizeCase: {
    readonly id: string;
    readonly snapshotFixture: string;
    readonly snapshotID: string;
    readonly appliedAtRefSeconds: number;
    readonly importedAtRefSeconds: number;
  };
  readonly diffCases: readonly {
    readonly id: string;
    readonly from: DiffContractEntry;
    readonly to: DiffContractEntry;
  }[];
};

function manualParityHex(value: Record<string, string>): string {
  const bytes = canonicalBytes(canonicalize(parseJson(JSON.stringify(value))));
  return bytesToHex(bytes);
}

const shouldGenerate = process.env.GENERATE_DIFF_CONTRACT === '1';

describe.skipIf(!shouldGenerate)('_generate diff contract expected (run once)', () => {
  it('从 Swift oracle 生成 fixture expected 并写回', async () => {
    const root = process.cwd();
    const manifest = loadGoldenManifest(root);
    const entry = manifest.cases.find((item) => item.id === 'diff/snapshot-history-contract');
    if (entry === undefined) {
      throw new Error('missing diff contract manifest entry');
    }
    const contract = readGoldenFixture(root, entry) as DiffContract;
    const oracle = createSwiftOracleRunner({ root });
    const villageID = parseUuid(contract.villageID)!;
    const lineageID = parseUuid(contract.lineageID)!;

    class GoldenClock {
      constructor(private readonly importedAtRefSeconds: number) {}

      nowMs(): number {
        return (this.importedAtRefSeconds + 978_307_200) * 1000;
      }
    }

    function buildEntry(input: DiffContractEntry) {
      const parsed = parseAccountSnapshot(input.text, {
        clock: new GoldenClock(contract.importedAtRefSeconds),
      });
      if (!parsed.ok) {
        throw new Error(`parse failed: ${input.text}`);
      }
      return canonicalizeSnapshotHistory(parsed.value, {
        villageID,
        lineageID: input.lineageID === undefined ? lineageID : parseUuid(input.lineageID)!,
        appliedAtRefSeconds: input.appliedAtRefSeconds,
        snapshotID: parseUuid(input.snapshotID)!,
      });
    }

    const goldenText = readFileSync(
      resolve(root, contract.canonicalizeCase.snapshotFixture),
      'utf8',
    );
    const canonicalizeSource = JSON.stringify({
      kind: 'canonicalize',
      snapshotText: goldenText,
      villageID: contract.villageID,
      lineageID: contract.lineageID,
      snapshotID: contract.canonicalizeCase.snapshotID,
      appliedAtRefSeconds: contract.canonicalizeCase.appliedAtRefSeconds,
      importedAtRefSeconds: contract.canonicalizeCase.importedAtRefSeconds,
    });
    const canonicalizeSwift = await oracle({
      protocolVersion: SWIFT_ORACLE_PROTOCOL_VERSION,
      caseId: 'generate-canonicalize',
      operation: 'snapshot-history-canonicalize',
      source: canonicalizeSource,
    });
    if (!canonicalizeSwift.ok) {
      throw new Error('canonicalize oracle failed');
    }

    const parsed = parseAccountSnapshot(goldenText, {
      clock: new GoldenClock(contract.canonicalizeCase.importedAtRefSeconds),
    });
    if (!parsed.ok) {
      throw new Error('golden parse failed');
    }
    const historyEntry = canonicalizeSnapshotHistory(parsed.value, {
      villageID,
      lineageID,
      appliedAtRefSeconds: contract.canonicalizeCase.appliedAtRefSeconds,
      snapshotID: parseUuid(contract.canonicalizeCase.snapshotID)!,
    });
    const typescriptCanonicalHex = manualParityHex({
      encodedJSONHex: historyEntryWireHex(historyEntry),
    });
    if (typescriptCanonicalHex !== canonicalizeSwift.value.canonicalHex) {
      throw new Error('TS/Swift canonicalize mismatch before freeze');
    }

    const diffCases = [];
    for (const contractCase of contract.diffCases) {
      const from = buildEntry(contractCase.from);
      const to = buildEntry(contractCase.to);
      const fromHydrated = hydrateVerifiedCoverageOnEntry({
        entry: from as Parameters<typeof hydrateVerifiedCoverageOnEntry>[0]['entry'],
        policy: 'testsAllowTestFixture',
      });
      const toHydrated = hydrateVerifiedCoverageOnEntry({
        entry: to as Parameters<typeof hydrateVerifiedCoverageOnEntry>[0]['entry'],
        policy: 'testsAllowTestFixture',
      });
      const diff = SnapshotDiffEngine.compare(fromHydrated, toHydrated);
      const source = JSON.stringify({
        kind: 'diff',
        fromEntryJSON: encodeHistoryEntryWire(from),
        toEntryJSON: encodeHistoryEntryWire(to),
      });
      const swift = await oracle({
        protocolVersion: SWIFT_ORACLE_PROTOCOL_VERSION,
        caseId: `generate-${contractCase.id}`,
        operation: 'snapshot-history-diff',
        source,
      });
      if (!swift.ok) {
        throw new Error(`diff oracle failed: ${contractCase.id}`);
      }
      const canonicalHex = manualParityHex({
        comparisonState: diff.comparisonState,
        changeCount: String(diff.changes.length),
        encodedJSONHex: snapshotDiffWireHex(diff, from.appliedAtRefSeconds, to.appliedAtRefSeconds),
      });
      if (canonicalHex !== swift.value.canonicalHex) {
        throw new Error(`TS/Swift diff mismatch: ${contractCase.id}`);
      }
      diffCases.push({
        ...contractCase,
        expected: {
          comparisonState: diff.comparisonState,
          changeCount: String(diff.changes.length),
          encodedJSONHex: snapshotDiffWireHex(
            diff,
            from.appliedAtRefSeconds,
            to.appliedAtRefSeconds,
          ),
          outputFingerprint: swift.outputFingerprint,
          canonicalHex,
        },
      });
    }

    const updated = {
      ...contract,
      canonicalizeCase: {
        ...contract.canonicalizeCase,
        expected: {
          outputFingerprint: canonicalizeSwift.outputFingerprint,
          canonicalHex: canonicalizeSwift.value.canonicalHex,
        },
      },
      diffCases,
    };

    const fixturePath = resolve(root, entry.fixture);
    writeFileSync(fixturePath, `${JSON.stringify(updated, null, 2)}\n`, 'utf8');
    console.log(`updated ${fixturePath}`);
  });
});
