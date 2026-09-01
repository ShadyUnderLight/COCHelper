import type { CatalogAssetRef } from './types';

export function isCatalogAssetRenderable(ref: CatalogAssetRef | null | undefined): boolean {
  if (ref === null || ref === undefined) {
    return false;
  }
  if (ref.renderedPath === null || ref.renderedPath === '') {
    return false;
  }
  return ref.missingReason === null;
}

export function collectCatalogIconRefs(
  items: readonly { readonly icon: CatalogAssetRef | null; readonly levelVisual: CatalogAssetRef | null; readonly levels: readonly { readonly icon: CatalogAssetRef | null; readonly levelVisual: CatalogAssetRef | null }[] }[],
): readonly string[] {
  const paths = new Set<string>();
  for (const item of items) {
    for (const ref of [item.icon, item.levelVisual]) {
      if (ref?.renderedPath) {
        paths.add(ref.renderedPath);
      }
    }
    for (const level of item.levels) {
      for (const ref of [level.icon, level.levelVisual]) {
        if (ref?.renderedPath) {
          paths.add(ref.renderedPath);
        }
      }
    }
  }
  return [...paths];
}
