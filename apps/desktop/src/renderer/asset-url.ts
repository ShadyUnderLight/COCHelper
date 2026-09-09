/**
 * Catalog 静态资源 URL（#277-C2）：URL 形状与 main `catalog-service.assetUrl`
 * 一致（`cochelper://catalog/<version>/<renderedPath>`），但路径严格校验
 * （`icons/<group>/<file>.png` 格式门）仍由 main protocol + domain 承担；
 * renderer 只做第一层防御（空值/穿越），不拼文件系统路径。
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
