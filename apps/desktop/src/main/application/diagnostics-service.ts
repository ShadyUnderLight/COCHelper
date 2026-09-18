import type { DiagnosticsRuntimeDto, DiagnosticsSnapshotPayload } from '@coc-helper/contracts';
import type { CatalogBundle } from '@coc-helper/domain';

import type { CatalogService } from '../catalog-service';
import type { ApplicationServices } from './application-services';
import { TokenSettingsService } from './token-settings-service';

export type DiagnosticsServiceOptions = {
  readonly services: ApplicationServices;
  readonly tokenSettings: TokenSettingsService;
  readonly catalog: Pick<CatalogService, 'getBundle' | 'peekBundle'>;
  readonly appName: string;
  readonly appVersion: string;
  readonly runtime: DiagnosticsRuntimeDto;
};

export class DiagnosticsService {
  private readonly services: ApplicationServices;
  private readonly tokenSettings: TokenSettingsService;
  private readonly catalog: Pick<CatalogService, 'getBundle' | 'peekBundle'>;
  private readonly appName: string;
  private readonly appVersion: string;
  private readonly runtime: DiagnosticsRuntimeDto;

  constructor(options: DiagnosticsServiceOptions) {
    this.services = options.services;
    this.tokenSettings = options.tokenSettings;
    this.catalog = options.catalog;
    this.appName = options.appName;
    this.appVersion = options.appVersion;
    this.runtime = options.runtime;
  }

  async snapshot(): Promise<DiagnosticsSnapshotPayload> {
    const snapshot = this.services.lifecycle.snapshot();
    const token = this.tokenSettings.status();
    const bundle = await this.loadCatalog();
    const selectedVillage = snapshot.villages.find(
      (village) => village.id === snapshot.selectedVillageId,
    );

    return {
      sessionId: snapshot.sessionId,
      app: {
        name: this.appName,
        version: this.appVersion,
      },
      runtime: this.runtime,
      application: {
        availability: snapshot.availability,
        villageStatus: snapshot.villageStatus,
        generation: snapshot.generation,
        selectedVillageId: snapshot.selectedVillageId,
        selectedVillageName: selectedVillage?.name ?? null,
        canWrite: snapshot.canWrite,
        hasPendingJournal: snapshot.hasPendingJournal,
      },
      catalog: {
        status: bundle?.gameCatalog === null || bundle === null ? 'unavailable' : 'available',
        version: bundle?.version ?? null,
      },
      official: {
        endpointAccess: 'mainOnly',
        authorization: 'mainOnly',
        credentialStorage: token.storage,
        rawResponseExposure: 'notExposed',
      },
      manual: {
        status: this.services.manual?.storageStatus() ?? 'unavailable',
      },
      token,
    };
  }

  private async loadCatalog(): Promise<CatalogBundle | null> {
    const cached = this.catalog.peekBundle();
    if (cached !== null) {
      return cached;
    }
    try {
      return await this.catalog.getBundle();
    } catch {
      return null;
    }
  }
}
