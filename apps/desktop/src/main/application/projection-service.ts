/**
 * ProjectionService（#276-S2）：Upgrade Overview / Village Detail 只读 query。
 * - 不写盘、不 bump generation；
 * - village.detail 必须显式 villageId + base；
 * - 读 manual cores 仅供投影，不 reconcile / 不改写。
 */

import {
  upgradeOverviewPayloadSchema,
  villageDetailPayloadSchema,
  type UpgradeOverviewPayload,
  type VillageDetailPayload,
  type VillageDetailRequest,
} from '@coc-helper/contracts';
import {
  buildVillageDetailFlatRows,
  projectBuildingGroupsFromProjection,
  projectVillageCatalog,
  upgradeOverviewRender,
  villageDetailCompletionStats,
  villageDetailGroups,
  villageDetailTotalCompletion,
  type CatalogBundle,
  type Clock,
  type ManualTrackerStore,
  type ManualUpgradeCore,
  type VillageProgressMetrics,
  type VillageProfile,
} from '@coc-helper/domain';

import { AppServiceError, type AppAuthoritativeState } from './app-authoritative-state';
import { toUpgradeOverviewPayload, toVillageDetailPayload } from './projection-dto-mappers';

export type ProjectionCatalogPort = {
  readonly getBundle: () => Promise<CatalogBundle>;
};

export type ProjectionServiceOptions = {
  readonly state: AppAuthoritativeState;
  readonly clock: Clock;
  readonly catalog: ProjectionCatalogPort;
  readonly manual: ManualTrackerStore | null;
};

export class ProjectionService {
  private readonly state: AppAuthoritativeState;
  private readonly clock: Clock;
  private readonly catalog: ProjectionCatalogPort;
  private readonly manual: ManualTrackerStore | null;

  constructor(options: ProjectionServiceOptions) {
    this.state = options.state;
    this.clock = options.clock;
    this.catalog = options.catalog;
    this.manual = options.manual;
  }

  async upgradeOverview(): Promise<UpgradeOverviewPayload> {
    const nowMs = this.clock.nowMs();
    const villages = this.state.listVillages();
    const bundle = await this.loadBundle();
    const manualUpgradeCores = this.loadManualCores();
    const render = upgradeOverviewRender({
      villages,
      catalog: bundle.gameCatalog,
      craftTableCatalog: bundle.craftTableCatalog,
      seasonalPhases: bundle.seasonalPhaseTable,
      manualUpgradeCores,
      nowMs,
    });
    let payload: UpgradeOverviewPayload;
    try {
      payload = toUpgradeOverviewPayload({
        generation: this.state.getGeneration(),
        nowMs,
        catalogVersion: bundle.version,
        catalogIsUsable: bundle.gameCatalog !== null,
        render,
      });
    } catch (error) {
      if (error instanceof RangeError) {
        throw new AppServiceError('validation', '升级总览包含无法经 IPC 传递的数值。');
      }
      throw error;
    }
    const parsed = upgradeOverviewPayloadSchema.safeParse(payload);
    if (!parsed.success) {
      throw new AppServiceError('validation', '升级总览无法经 IPC schema 校验。');
    }
    return parsed.data;
  }

  async villageDetail(request: VillageDetailRequest): Promise<VillageDetailPayload> {
    const village = this.requireVillage(request.villageId);
    const base = request.base;
    const nowMs = this.clock.nowMs();
    const bundle = await this.loadBundle();
    const manualCore = this.loadManualCores()[village.id] ?? null;
    const projection = projectVillageCatalog({
      village,
      catalog: bundle.gameCatalog,
      craftTableCatalog: bundle.craftTableCatalog,
      seasonalPhases: bundle.seasonalPhaseTable,
      base,
      nowMs,
      manualUpgradeCore: manualCore,
    });
    const groups = villageDetailGroups(projection.items);
    const completion = villageDetailCompletionStats(projection.items, projection.catalogIsUsable);
    const totalCompletion = villageDetailTotalCompletion(
      projection.items,
      projection.catalogIsUsable,
    );
    const buildingGroups = projectBuildingGroupsFromProjection({
      projection,
      catalog: bundle.gameCatalog,
      base,
      manualUpgradeCore: manualCore,
    });
    const statsByKey: Record<string, (typeof completion)[number]> = {};
    for (const entry of completion) {
      statsByKey[entry.id] = entry;
    }
    const groupByInstanceID: Record<string, (typeof buildingGroups)[number]> = {};
    for (const group of buildingGroups) {
      for (const instance of group.instances) {
        groupByInstanceID[rawRecordID(instance.id)] = group;
        groupByInstanceID[rawRecordID(instance.item.id)] = group;
      }
    }
    const flatRows = buildVillageDetailFlatRows({
      displayGroups: groups,
      statsByKey,
      groupByInstanceID,
    });
    const metrics = projection.progressMetrics as VillageProgressMetrics;

    let payload: VillageDetailPayload;
    try {
      payload = toVillageDetailPayload({
        generation: this.state.getGeneration(),
        nowMs,
        village,
        base,
        catalogVersion: projection.catalogVersion ?? bundle.version,
        catalogIsUsable: projection.catalogIsUsable,
        compatibility: projection.compatibility,
        items: projection.items,
        groups,
        completion,
        totalCompletion,
        metrics,
        buildingGroups,
        flatRows,
      });
    } catch (error) {
      if (error instanceof RangeError) {
        throw new AppServiceError('validation', '村庄详情包含无法经 IPC 传递的数值。');
      }
      throw error;
    }
    const parsed = villageDetailPayloadSchema.safeParse(payload);
    if (!parsed.success) {
      throw new AppServiceError('validation', '村庄详情无法经 IPC schema 校验。');
    }
    return parsed.data;
  }

  private requireVillage(villageId: string): VillageProfile {
    const village = this.state.listVillages().find((entry) => entry.id === villageId);
    if (village === undefined) {
      throw new AppServiceError('notFound', '目标村庄不存在。');
    }
    return village;
  }

  private async loadBundle(): Promise<CatalogBundle> {
    try {
      return await this.catalog.getBundle();
    } catch {
      throw new AppServiceError('unavailable', '游戏目录尚未就绪。');
    }
  }

  private loadManualCores(): Readonly<Record<string, ManualUpgradeCore>> {
    if (this.manual === null) {
      return {};
    }
    const envelope = this.manual.load();
    if (envelope === null) {
      return {};
    }
    const cores: Record<string, ManualUpgradeCore> = {};
    for (const village of envelope.villages) {
      cores[village.villageID] = village.core;
    }
    return cores;
  }
}

function rawRecordID(id: string): string {
  const hash = id.indexOf('#');
  return hash >= 0 ? id.slice(0, hash) : id;
}
