import { FuseV1Options, FuseVersion } from '@electron/fuses';
import { MakerZIP } from '@electron-forge/maker-zip';
import { MakerDMG } from '@electron-forge/maker-dmg';
import { AutoUnpackNativesPlugin } from '@electron-forge/plugin-auto-unpack-natives';
import { FusesPlugin } from '@electron-forge/plugin-fuses';
import { WebpackPlugin } from '@electron-forge/plugin-webpack';
import { existsSync, renameSync, writeFileSync } from 'node:fs';
import type { ForgeConfig } from '@electron-forge/shared-types';
import path from 'node:path';

import { DEV_CONTENT_SECURITY_POLICY } from './src/main/security-policy';
import { mainConfig } from './webpack.main.config';
import { rendererConfig } from './webpack.renderer.config';
import { readGitProvenance } from '../../scripts/perf-provenance.mjs';
import {
  readReleaseMetadata,
  readResolvedElectronVersion,
} from '../../scripts/release-metadata.mjs';
import { buildCycloneDxBom, readProductionDependencyTree } from '../../scripts/release-sbom.mjs';

const repoRoot = path.resolve(__dirname, '../..');
const releaseMetadata = readReleaseMetadata(repoRoot);

const config: ForgeConfig = {
  packagerConfig: {
    asar: true,
    name: 'COCHelper',
    appVersion: releaseMetadata.app.version,
    buildVersion: releaseMetadata.app.buildNumber,
    appBundleId: 'com.local.coc-helper.electron',
    extraResource: [
      path.join(repoRoot, 'apps/desktop/resources/GameCatalog'),
      path.join(repoRoot, 'apps/desktop/resources/account_name_catalog.json'),
    ],
  },
  hooks: {
    postPackage: async (_config, packageResult) => {
      const provenance = {
        ...readGitProvenance(repoRoot),
        generatedAt: new Date().toISOString(),
      };
      const sbom = buildCycloneDxBom({
        metadata: releaseMetadata,
        dependencyTree: readProductionDependencyTree(repoRoot),
        resolvedElectronVersion: readResolvedElectronVersion(repoRoot),
      });
      for (const outputPath of packageResult.outputPaths) {
        const appPath =
          packageResult.platform === 'darwin' && !outputPath.endsWith('.app')
            ? path.join(outputPath, 'COCHelper.app')
            : outputPath;
        const resourcesPath =
          packageResult.platform === 'darwin'
            ? path.join(appPath, 'Contents', 'Resources')
            : path.join(appPath, 'resources');
        writeFileSync(
          path.join(resourcesPath, 'perf-build-provenance.json'),
          `${JSON.stringify(provenance, null, 2)}\n`,
        );
        writeFileSync(
          path.join(resourcesPath, 'release-manifest.json'),
          `${JSON.stringify(releaseMetadata, null, 2)}\n`,
        );
        writeFileSync(
          path.join(resourcesPath, 'sbom.cdx.json'),
          `${JSON.stringify(sbom, null, 2)}\n`,
        );
      }
    },
    postMake: async (_config, makeResults) =>
      makeResults.map((result) => ({
        ...result,
        artifacts: result.artifacts.map((artifact) =>
          renameReleaseArtifact(artifact, result.packageJSON?.version ?? '0.0.0'),
        ),
      })),
  },
  rebuildConfig: {},
  makers: [new MakerZIP({}, ['darwin']), new MakerDMG({}, ['darwin'])],
  plugins: [
    new AutoUnpackNativesPlugin({}),
    new WebpackPlugin({
      mainConfig,
      devContentSecurityPolicy: DEV_CONTENT_SECURITY_POLICY,
      renderer: {
        config: rendererConfig,
        nodeIntegration: false,
        entryPoints: [
          {
            html: './src/renderer/index.html',
            js: './src/renderer/index.tsx',
            name: 'main_window',
            preload: {
              js: './src/preload/index.ts',
            },
          },
        ],
      },
    }),
    new FusesPlugin({
      version: FuseVersion.V1,
      [FuseV1Options.RunAsNode]: false,
      [FuseV1Options.EnableCookieEncryption]: true,
      [FuseV1Options.EnableNodeOptionsEnvironmentVariable]: false,
      [FuseV1Options.EnableNodeCliInspectArguments]: false,
      [FuseV1Options.EnableEmbeddedAsarIntegrityValidation]: true,
      [FuseV1Options.OnlyLoadAppFromAsar]: true,
    }),
  ],
};

function renameReleaseArtifact(artifactPath: string, sourceVersion: string): string {
  const targetVersion = releaseMetadata.app.version;
  if (sourceVersion === targetVersion || !artifactPath.includes(`-${sourceVersion}`)) {
    return artifactPath;
  }
  const targetPath = artifactPath.replace(`-${sourceVersion}`, `-${targetVersion}`);
  if (!existsSync(artifactPath)) {
    throw new Error(`Forge make artifact 不存在：${artifactPath}`);
  }
  renameSync(artifactPath, targetPath);
  return targetPath;
}

export default config;
