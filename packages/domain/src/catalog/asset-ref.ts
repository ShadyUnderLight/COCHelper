import type { CatalogAssetRef, CatalogItem } from './types';
import { renderedPathFormatOk } from './asset-path';

/** R-A：无 renderedPath 引用，合法 no-reference 状态（不要求 missingReason）。 */
export function isCatalogAssetRefNoReference(ref: CatalogAssetRef): boolean {
  return ref.renderedPath === null;
}

/**
 * 契约 R-A/R-B/R-D 语义校验（不含 R-C 登记与文件存在性）。
 * 对齐 Tools/game_catalog/contract.py：renderedPath is None → 通过；
 * missingReason 按 is not None 判定（空串同样违反 R-B）。
 */
export function isCatalogAssetRefSemanticallyValid(ref: CatalogAssetRef): boolean {
  if (ref.renderedPath === null) {
    return true;
  }
  if (ref.renderedPath === '') {
    return false;
  }
  if (ref.missingReason !== null) {
    return false;
  }
  return renderedPathFormatOk(ref.renderedPath);
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
  return (
    ref.renderedPath !== null &&
    ref.missingReason === null &&
    renderedPathFormatOk(ref.renderedPath)
  );
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
      if (isCatalogAssetRenderable(ref)) {
        paths.add(ref.renderedPath!);
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
