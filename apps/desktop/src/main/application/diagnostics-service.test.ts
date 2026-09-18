import { describe, expect, it } from 'vitest';

import type { ApplicationServices } from './application-services';
import { AppServiceError } from './app-authoritative-state';
import { DiagnosticsService } from './diagnostics-service';
import { TokenSettingsService } from './token-settings-service';
import { InMemoryTokenStore } from '../persistence/secret-store';

const applicationSnapshot = {
  sessionId: 'session-1',
  generation: 7,
  availability: 'recovery' as const,
  villageStatus: 'corrupt' as const,
  villageError: 'internal stack and token should not be copied',
  canWrite: false,
  hasPendingJournal: true,
  recoveryNotice: '需要恢复',
  selectedVillageId: 'v1',
  villages: [{ id: 'v1', name: '主村', tag: '#AAA', hasImportedData: true }],
  pendingImport: null,
};

describe('DiagnosticsService', () => {
  it('聚合安全诊断字段，不复制原始错误或 token', async () => {
    const tokenStore = new InMemoryTokenStore();
    tokenStore.saveToken('secret-token');
    const tokenSettings = new TokenSettingsService(tokenStore);
    const services = {
      lifecycle: { snapshot: () => applicationSnapshot },
      manual: { storageStatus: () => 'empty' as const },
    } as unknown as ApplicationServices;
    const catalog = {
      peekBundle: () => ({
        version: '18.400.13',
        root: '/private/catalog',
        gameCatalog: {} as never,
        craftTableCatalog: null,
        leagueTierCatalog: null,
        seasonalPhaseTable: {},
        accountNameCatalog: {},
      }),
      getBundle: async () => {
        throw new AppServiceError('unavailable', 'catalog unavailable');
      },
    };
    const service = new DiagnosticsService({
      services,
      tokenSettings,
      catalog: catalog as never,
      appName: 'COCHelper',
      appVersion: '0.0.0',
      runtime: {
        electron: '44.0.0',
        node: '24.18.1',
        chrome: '136.0.0',
        platform: 'darwin',
        arch: 'arm64',
      },
    });

    const result = await service.snapshot();

    expect(result.application).toEqual({
      availability: 'recovery',
      villageStatus: 'corrupt',
      generation: 7,
      selectedVillageId: 'v1',
      selectedVillageName: '主村',
      canWrite: false,
      hasPendingJournal: true,
    });
    expect(result.catalog).toEqual({ status: 'available', version: '18.400.13' });
    expect(result.token).toEqual({
      configured: true,
      storage: 'available',
      message: null,
    });
    expect(JSON.stringify(result)).not.toContain('secret-token');
    expect(JSON.stringify(result)).not.toContain('internal stack');
    expect(JSON.stringify(result)).not.toContain('/private/catalog');
  });

  it('没有可用服务时报告 Manual 不可用', async () => {
    const service = new DiagnosticsService({
      services: {
        lifecycle: { snapshot: () => ({ ...applicationSnapshot, villages: [] }) },
        manual: null,
      } as unknown as ApplicationServices,
      tokenSettings: new TokenSettingsService(null),
      catalog: {
        peekBundle: () => null,
        getBundle: async () => {
          throw new Error('catalog unavailable');
        },
      },
      appName: 'COCHelper',
      appVersion: '0.0.0',
      runtime: {
        electron: '44.0.0',
        node: '24.18.1',
        chrome: '136.0.0',
        platform: 'darwin',
        arch: 'arm64',
      },
    });

    const result = await service.snapshot();
    expect(result.manual.status).toBe('unavailable');
    expect(result.catalog).toEqual({ status: 'unavailable', version: null });
  });
});
