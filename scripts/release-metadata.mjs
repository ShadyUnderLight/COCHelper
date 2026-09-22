import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import semver from 'semver';

import { readGitProvenance } from './perf-provenance.mjs';

export const RELEASE_MANIFEST_PROTOCOL = 'cochelper-release-manifest-v1';
export const RELEASE_CHANNELS = Object.freeze(['dev', 'pre-cutover', 'candidate']);

const CATALOG_MANIFEST_SCHEMA_VERSION = 3;

export function readReleaseMetadata(repoRoot, environment = process.env, provenanceReader = readGitProvenance) {
  const rootPackage = readJson(path.join(repoRoot, 'package.json'), '根 package.json');
  const desktopPackage = readJson(
    path.join(repoRoot, 'apps/desktop/package.json'),
    'desktop package.json',
  );
  const channel = environment.COCHELPER_RELEASE_CHANNEL?.trim() || 'dev';
  if (!RELEASE_CHANNELS.includes(channel)) {
    throw new Error(`不支持的 release channel：${channel}`);
  }

  const version = validateSemver(
    environment.COCHELPER_RELEASE_VERSION?.trim() || desktopPackage.version,
  );
  const buildNumber = parseBuildNumber(
    environment.COCHELPER_BUILD_NUMBER?.trim() || (channel === 'dev' ? '0' : ''),
    channel,
  );
  const catalog = readCatalogManifest(
    repoRoot,
    environment.COCHELPER_CATALOG_VERSION?.trim() || null,
  );
  const source = provenanceReader(repoRoot);

  return {
    schemaVersion: 1,
    protocol: RELEASE_MANIFEST_PROTOCOL,
    release: {
      channel,
      version,
      buildNumber,
    },
    app: {
      name: desktopPackage.name,
      productName: desktopPackage.productName,
      version,
      buildNumber,
    },
    source: {
      commitSha: source.commitSha,
      dirty: source.dirty,
      untrackedInputs: [...source.untrackedInputs],
    },
    catalog,
    toolchain: {
      node: process.version,
      packageManager: rootPackage.packageManager ?? 'unknown',
      electron: desktopPackage.devDependencies?.electron ?? 'unknown',
    },
  };
}

export function validateSemver(value) {
  const parsed = typeof value === 'string' ? semver.parse(value) : null;
  if (parsed === null || parsed.raw !== value || !/^\d/.test(value)) {
    throw new Error(`release version 必须是 SemVer：${String(value)}`);
  }
  return value;
}

export function parseBuildNumber(value, channel = 'dev') {
  if (typeof value !== 'string' || !/^\d+$/.test(value)) {
    throw new Error(`${channel} release 必须提供纯数字 build number：${String(value)}`);
  }
  if (channel !== 'dev' && Number(value) <= 0) {
    throw new Error(`${channel} release 的 build number 必须大于 0：${value}`);
  }
  return value;
}

export function assertReleaseSourceClean(metadata) {
  if (metadata.release.channel !== 'dev' && metadata.source.dirty) {
    const details = metadata.source.untrackedInputs.length > 0
      ? `；未跟踪输入：${metadata.source.untrackedInputs.join(', ')}`
      : '';
    throw new Error(`候选 release 必须来自 clean checkout，当前 source dirty${details}`);
  }
  return metadata;
}

export function readCatalogManifest(repoRoot, requestedVersion = null) {
  const catalogRoot = path.join(repoRoot, 'apps/desktop/resources/GameCatalog');
  if (!existsSync(catalogRoot)) {
    throw new Error(`找不到 GameCatalog 根目录：${catalogRoot}`);
  }
  const versions = readdirSync(catalogRoot)
    .filter((entry) => {
      const versionRoot = path.join(catalogRoot, entry);
      return statSync(versionRoot).isDirectory() && existsSync(path.join(versionRoot, 'manifest.json'));
    })
    .sort();
  const version = requestedVersion ?? (versions.length === 1 ? versions[0] : null);
  if (version === null || !versions.includes(version)) {
    throw new Error(
      requestedVersion === null
        ? `GameCatalog 必须有且只有一个可注入版本，实际：${versions.join(', ') || 'none'}`
        : `指定的 catalog version 不存在：${requestedVersion}`,
    );
  }
  const manifest = readJson(path.join(catalogRoot, version, 'manifest.json'), 'catalog manifest');
  if (
    manifest.schemaVersion !== CATALOG_MANIFEST_SCHEMA_VERSION ||
    typeof manifest.gameVersion !== 'string' ||
    typeof manifest.buildTag !== 'string' ||
    typeof manifest.locale !== 'string'
  ) {
    throw new Error('catalog manifest 必须符合 CatalogManifestV3 四字段契约。');
  }
  return {
    version,
    schemaVersion: manifest.schemaVersion,
    gameVersion: manifest.gameVersion,
    buildTag: manifest.buildTag,
    locale: manifest.locale,
  };
}

export function readJson(filePath, label) {
  try {
    return JSON.parse(readFileSync(filePath, 'utf8'));
  } catch (error) {
    throw new Error(`${label} 读取失败：${filePath}`, { cause: error });
  }
}

export function readResolvedElectronVersion(repoRoot) {
  try {
    const packageJson = readJson(
      path.join(repoRoot, 'node_modules/electron/package.json'),
      '已安装 Electron package.json',
    );
    return typeof packageJson.version === 'string' ? packageJson.version : 'unknown';
  } catch {
    return null;
  }
}
