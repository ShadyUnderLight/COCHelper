import type {
  HydratedSnapshotHistoryEntry,
  HydratedSnapshotSectionCoverage,
} from './trust-hydration';
import { sectionTrustOpensGates } from './store-types';
import type { SnapshotCoverageState, SnapshotItemIdentity } from './types';

export function snapshotCoverageProofHasVerifiedWireMetadata(
  proof: HydratedSnapshotSectionCoverage['proof'],
): boolean {
  return proof.kind === 'verified';
}

export function hydratedSectionOpensTrustGates(section: HydratedSnapshotSectionCoverage): boolean {
  return (
    snapshotCoverageProofHasVerifiedWireMetadata(section.proof) &&
    sectionTrustOpensGates(section.runtimeTrust)
  );
}

export function hydratedSectionIsComplete(section: HydratedSnapshotSectionCoverage): boolean {
  return section.completeness === 'complete' && hydratedSectionOpensTrustGates(section);
}

export function observationCoverageState(
  entry: HydratedSnapshotHistoryEntry,
  base: SnapshotItemIdentity['base'],
  rawSection: string,
  field: string,
): SnapshotCoverageState | undefined {
  return entry.coverage.fields.find(
    (coverageField) =>
      coverageField.base === base &&
      coverageField.rawSection === rawSection &&
      coverageField.field === field,
  )?.state;
}

export function observationCoverageSection(
  entry: HydratedSnapshotHistoryEntry,
  base: SnapshotItemIdentity['base'],
  rawSection: string,
): HydratedSnapshotSectionCoverage | undefined {
  return entry.coverage.sections.find(
    (section) => section.base === base && section.rawSection === rawSection,
  );
}

export function sectionCoverageIsComplete(
  entry: HydratedSnapshotHistoryEntry,
  identity: SnapshotItemIdentity,
): boolean {
  const section = observationCoverageSection(entry, identity.base, identity.rawSection);
  return section !== undefined && hydratedSectionIsComplete(section);
}
