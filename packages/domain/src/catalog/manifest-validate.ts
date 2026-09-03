import { validateCatalogItemsAssetRefs } from './asset-ref';
import type { CatalogItem, CatalogManifest } from './types';

/** 新契约 manifest 消费侧校验（E0-03/Issue #303）：只剩版本门 + 资源语义校验。
 * counts 重算、hash/size、文件存在性、generatedFiles 登记门整体撤销。 */
export function validateCatalogManifest(
  manifest: CatalogManifest,
  items: readonly CatalogItem[],
): boolean {
  if (manifest.schemaVersion !== 3) {
    return false;
  }
  if (!validateCatalogItemsAssetRefs(items)) {
    return false;
  }
  return true;
}
