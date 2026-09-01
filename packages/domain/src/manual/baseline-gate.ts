import { baselineReferencesEqual } from './equality';
import type { ManualBaselineReference, ManualUpgradeCore } from './types';

export function isBaselineReconciled(input: {
  readonly core: ManualUpgradeCore;
  readonly currentBaseline: ManualBaselineReference | null;
}): boolean {
  if (input.core.itemStates.length === 0 && input.core.records.length === 0) {
    return true;
  }
  const storedBaseline = coreBaselineReference(input.core);
  if (storedBaseline === null || input.currentBaseline === null) {
    return false;
  }
  return baselineReferencesEqual(storedBaseline, input.currentBaseline);
}

export function coreBaselineReference(core: ManualUpgradeCore): ManualBaselineReference | null {
  const references = [
    ...core.itemStates.map((state) => state.baselineReference),
    ...core.records.map((record) => record.baselineReference),
  ];
  if (references.length === 0) {
    return null;
  }
  const first = references[0]!;
  if (references.every((reference) => baselineReferencesEqual(reference, first))) {
    return first;
  }
  return null;
}

export function coreBaselineLineageID(core: ManualUpgradeCore): string | null {
  return coreBaselineReference(core)?.lineageID ?? null;
}
