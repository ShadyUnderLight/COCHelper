import { generateUuid, type UuidString } from '@coc-helper/wire';

import { isValidTag, normalizedTag } from '../tag/validator';
import type { SnapshotLineageContext, SnapshotLineageResolution } from './types';

type TagStatus =
  | { readonly kind: 'missing' }
  | { readonly kind: 'invalid' }
  | { readonly kind: 'valid'; readonly tag: string };

function tagStatus(rawTag: string | null | undefined): TagStatus {
  const normalized = normalizedTag(rawTag);
  if (normalized === undefined) {
    return { kind: 'missing' };
  }
  if (!isValidTag(normalized)) {
    return { kind: 'invalid' };
  }
  return { kind: 'valid', tag: normalized };
}

function reasonForTagStatus(status: TagStatus): SnapshotLineageResolution['reason'] {
  switch (status.kind) {
    case 'missing':
      return 'missingTag';
    case 'invalid':
      return 'invalidTag';
    case 'valid':
      return 'sameVillageAndTag';
  }
}

export function resolveSnapshotLineage(input: {
  readonly villageID: UuidString;
  readonly normalizedPlayerTag: string | null | undefined;
  readonly previous: SnapshotLineageContext | null;
}): SnapshotLineageResolution {
  const current = tagStatus(input.normalizedPlayerTag);
  if (current.kind !== 'valid') {
    return {
      lineageID: generateUuid(),
      outcome: 'unknown',
      reason: reasonForTagStatus(current),
      isBaseline: true,
      comparisonAllowed: false,
    };
  }

  if (input.previous === null) {
    return {
      lineageID: generateUuid(),
      outcome: 'initial',
      reason: 'initial',
      isBaseline: true,
      comparisonAllowed: false,
    };
  }

  if (input.previous.villageID !== input.villageID) {
    return {
      lineageID: generateUuid(),
      outcome: 'unknown',
      reason: 'villageChanged',
      isBaseline: true,
      comparisonAllowed: false,
    };
  }

  if (input.previous.hasConflict) {
    return {
      lineageID: generateUuid(),
      outcome: 'unknown',
      reason: 'previousConflict',
      isBaseline: true,
      comparisonAllowed: false,
    };
  }

  const previousTag = tagStatus(input.previous.normalizedPlayerTag);
  if (previousTag.kind !== 'valid' || current.kind !== 'valid') {
    return {
      lineageID: generateUuid(),
      outcome: 'unknown',
      reason: reasonForTagStatus(previousTag),
      isBaseline: true,
      comparisonAllowed: false,
    };
  }

  if (current.tag === previousTag.tag) {
    return {
      lineageID: input.previous.lineageID,
      outcome: 'continued',
      reason: 'sameVillageAndTag',
      isBaseline: false,
      comparisonAllowed: true,
    };
  }

  return {
    lineageID: generateUuid(),
    outcome: 'newLineage',
    reason: 'tagChanged',
    isBaseline: true,
    comparisonAllowed: false,
  };
}
