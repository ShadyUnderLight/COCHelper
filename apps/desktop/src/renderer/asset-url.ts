/**
 * Catalog 静态资源 URL（#277-C2）：与 main `catalog-service.assetUrl` 同构。
 * renderer 只产 `cochelper://catalog/...` URL 字符串，不拼文件系统路径；
 * 越界/缺失由 main `protocol.ts` 兜底，本函数做第一层防御。
 */
import type { CatalogAssetRefDto } from '@coc-helper/contracts';

export function overviewAssetUrl(
  catalogVersion: string | null,
  ref: CatalogAssetRefDto | null,
): string | null {
  if (catalogVersion === null || catalogVersion.length === 0 || ref === null) {
    return null;
  }
  const path = ref.renderedPath;
  if (path === null || path.length === 0 || ref.missingReason !== null) {
    return null;
  }
  if (path.startsWith('/') || path.split('/').includes('..')) {
    return null;
  }
  return `cochelper://catalog/${catalogVersion}/${path}`;
}
