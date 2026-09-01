import type { CatalogAssetRef, CatalogItem } from './types';

/** 契约 R-B / 语义 invariant：renderedPath 与 missingReason 互斥且不可双空。 */
export function isCatalogAssetRefSemanticallyValid(ref: CatalogAssetRef): boolean {
  const hasPath = ref.renderedPath !== null && ref.renderedPath !== '';
  const hasReason = ref.missingReason !== null && ref.missingReason !== '';
  if (hasPath && hasReason) {
    return false;
  }
  if (!hasPath && !hasReason) {
    return false;
  }
  if (ref.renderedPath === '') {
    return false;
  }
  return true;
}

export function validateCatalogItemsAssetRefs(items: readonly CatalogItem[]): boolean {
  for (const item of items) {
    for (const ref of collectItemAssetRefs(item)) {
      if (!isCatalogAssetRefSemanticallyValid(ref)) {
        return false;
      }
    }
  }
  return true;
}

export function isCatalogAssetRenderable(ref: CatalogAssetRef | null | undefined): boolean {
  if (ref === null || ref === undefined) {
    return false;
  }
  if (!isCatalogAssetRefSemanticallyValid(ref)) {
    return false;
  }
  return ref.renderedPath !== null && ref.missingReason === null;
}

export function collectCatalogIconRefs(
  items: readonly {
    readonly icon: CatalogAssetRef | null;
    readonly levelVisual: CatalogAssetRef | null;
    readonly levels: readonly {
      readonly icon: CatalogAssetRef | null;
      readonly levelVisual: CatalogAssetRef | null;
    }[];
  }[],
): readonly string[] {
  const paths = new Set<string>();
  for (const item of items) {
    for (const ref of collectItemAssetRefs(item)) {
      if (ref.renderedPath !== null && ref.renderedPath !== '' && ref.missingReason === null) {
        paths.add(ref.renderedPath);
      }
    }
  }
  return [...paths];
}

function collectItemAssetRefs(item: {
  readonly icon: CatalogAssetRef | null;
  readonly levelVisual: CatalogAssetRef | null;
  readonly levels: readonly {
    readonly icon: CatalogAssetRef | null;
    readonly levelVisual: CatalogAssetRef | null;
  }[];
}): readonly CatalogAssetRef[] {
  const refs: CatalogAssetRef[] = [];
  for (const ref of [item.icon, item.levelVisual]) {
    if (ref !== null) {
      refs.push(ref);
    }
  }
  for (const level of item.levels) {
    for (const ref of [level.icon, level.levelVisual]) {
      if (ref !== null) {
        refs.push(ref);
      }
    }
  }
  return refs;
}
