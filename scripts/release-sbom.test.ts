import { describe, expect, it } from 'vitest';

import { buildCycloneDxBom } from './release-sbom.mjs';

const metadata = {
  app: { productName: 'COCHelper', version: '1.2.3' },
};

describe('release SBOM', () => {
  it('生成稳定排序的 CycloneDX production dependency 清单', () => {
    const bom = buildCycloneDxBom({
      metadata,
      resolvedElectronVersion: '44.0.0',
      dependencyTree: {
        dependencies: {
          zod: { version: '4.4.3', dependencies: {} },
          '@coc-helper/wire': { version: 'link:../../packages/wire', dependencies: {} },
          react: { version: '19.2.8', dependencies: { scheduler: { version: '0.27.0' } } },
        },
        unsavedDependencies: {
          vitest: { version: '3.2.7' },
        },
      },
    });

    expect(bom).toMatchObject({ bomFormat: 'CycloneDX', specVersion: '1.5', version: 1 });
    expect(bom.components.map((component) => `${component.name}@${component.version}`)).toEqual([
      'electron@44.0.0',
      'react@19.2.8',
      'scheduler@0.27.0',
      'zod@4.4.3',
      'wire@0.0.0',
    ]);
    expect(bom.components.some((component) => component.name === 'vitest')).toBe(false);
  });
});
