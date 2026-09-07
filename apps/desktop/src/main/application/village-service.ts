/**
 * VillageService：村庄选择与列表（#276）。
 * select 必须显式 villageId，不回落到「当前选中」。
 */

import type { VillageSelectPayload } from '@coc-helper/contracts';

import { AppServiceError, type AppAuthoritativeState } from './app-authoritative-state';

export class VillageService {
  constructor(private readonly state: AppAuthoritativeState) {}

  selectVillage(villageId: string): VillageSelectPayload {
    if (!this.state.canWrite()) {
      throw new AppServiceError('unavailable', '当前处于恢复或只读状态，无法选择村庄。');
    }
    const store = this.state.getVillageStore();
    const exists = store.listVillages().some((village) => village.id === villageId);
    if (!exists) {
      throw new AppServiceError('notFound', '目标村庄不存在。');
    }
    store.setSelectedVillageId(villageId);
    this.state.notifyMutation();
    return {
      generation: this.state.getGeneration(),
      selectedVillageId: villageId,
    };
  }
}
