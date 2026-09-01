import {
  catalogAssetUrl,
  createCatalogBundleCache,
  DEFAULT_BUNDLED_CATALOG_VERSION,
  isCatalogAssetRenderable,
  renderedPathFormatOk,
  resolveCatalogAssetPath,
  resolveCatalogBundleRoot,
  type CatalogAssetRef,
  type CatalogBundle,
  type CatalogBundleCache,
} from '@coc-helper/domain';
import { app } from 'electron';
import { join } from 'node:path';

import { APP_PROTOCOL, CATALOG_HOST } from './security-policy';

export type CatalogService = {
  readonly getBundle: () => Promise<CatalogBundle>;
  readonly peekBundle: () => CatalogBundle | null;
  readonly assetUrl: (version: string, renderedPath: string) => string | null;
  readonly resolveAssetPath: (version: string, pathname: string) => string | null;
  readonly preload: () => void;
};

let service: CatalogService | null = null;

export function resolvePackagedCatalogRoot(): string {
  if (process.env.COCHELPER_CATALOG_ROOT) {
    return process.env.COCHELPER_CATALOG_ROOT;
  }
  if (app.isPackaged) {
    return join(process.resourcesPath, 'GameCatalog');
  }
  const devRoot = resolveCatalogBundleRoot(process.cwd());
  if (devRoot === null) {
    throw new Error('找不到 bundled GameCatalog 目录。');
  }
  return devRoot;
}

export function createCatalogService(input?: {
  readonly root?: string;
  readonly version?: string;
}): CatalogService {
  const root = input?.root ?? resolvePackagedCatalogRoot();
  const version = input?.version ?? DEFAULT_BUNDLED_CATALOG_VERSION;
  const cache: CatalogBundleCache = createCatalogBundleCache({ root, version });

  return {
    getBundle: () => cache.get(),
    peekBundle: () => cache.peek(),
    assetUrl(catalogVersion, renderedPath) {
      if (!renderedPathFormatOk(renderedPath)) {
        return null;
      }
      return catalogAssetUrl(APP_PROTOCOL, CATALOG_HOST, catalogVersion, renderedPath);
    },
    resolveAssetPath(catalogVersion, pathname) {
      return resolveCatalogAssetPath(root, catalogVersion, pathname);
    },
    preload() {
      setImmediate(() => {
        void cache.get().catch(() => undefined);
      });
    },
  };
}

export function getCatalogService(): CatalogService {
  if (service === null) {
    service = createCatalogService();
  }
  return service;
}

export function assetUrlForRef(
  catalogService: CatalogService,
  version: string,
  ref: CatalogAssetRef | null | undefined,
): string | null {
  if (ref === null || ref === undefined || !isCatalogAssetRenderable(ref)) {
    return null;
  }
  return catalogService.assetUrl(version, ref.renderedPath!);
}

export function resetCatalogServiceForTests(): void {
  service = null;
}
