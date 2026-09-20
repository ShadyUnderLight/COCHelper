import { FuseV1Options, FuseVersion } from '@electron/fuses';
import { MakerZIP } from '@electron-forge/maker-zip';
import { AutoUnpackNativesPlugin } from '@electron-forge/plugin-auto-unpack-natives';
import { FusesPlugin } from '@electron-forge/plugin-fuses';
import { WebpackPlugin } from '@electron-forge/plugin-webpack';
import { writeFileSync } from 'node:fs';
import type { ForgeConfig } from '@electron-forge/shared-types';
import path from 'node:path';

import { DEV_CONTENT_SECURITY_POLICY } from './src/main/security-policy';
import { mainConfig } from './webpack.main.config';
import { rendererConfig } from './webpack.renderer.config';
import { readGitProvenance } from '../../scripts/perf-provenance.mjs';

const repoRoot = path.resolve(__dirname, '../..');

const config: ForgeConfig = {
  packagerConfig: {
    asar: true,
    name: 'COCHelper',
    appBundleId: 'com.local.coc-helper.electron',
    extraResource: [
      path.join(repoRoot, 'Sources/COCHelperCore/GameCatalog'),
      path.join(repoRoot, 'Sources/COCHelperCore/Resources/account_name_catalog.json'),
    ],
  },
  hooks: {
    postPackage: async (_config, packageResult) => {
      const provenance = {
        ...readGitProvenance(repoRoot),
        generatedAt: new Date().toISOString(),
      };
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
      }
    },
  },
  rebuildConfig: {},
  makers: [new MakerZIP({}, ['darwin'])],
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

export default config;
