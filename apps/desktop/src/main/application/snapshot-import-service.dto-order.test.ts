import { describe, expect, it, vi } from 'vitest';

import { AppAuthoritativeState, AppServiceError } from './app-authoritative-state';
import { InMemoryVillageStore } from './import-coordinator';
import { SnapshotImportService } from './snapshot-import-service';

class FakeClock {
  nowMs(): number {
    return 0;
  }
}

vi.mock('./dto-mappers', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./dto-mappers')>();
  return {
    ...actual,
    toPendingImportPreviewWire: () => {
      throw new RangeError('超出 safe integer');
    },
  };
});

describe('SnapshotImportService DTO-before-pending', () => {
  it('DTO 转换失败时不 setPending、不 bump generation', () => {
    const store = new InMemoryVillageStore();
    store.seed([], null);
    const state = new AppAuthoritativeState({
      persistence: {
        canInitializeDerivedStores: true,
        villageStatus: 'missing',
        villageError: null,
        villagesInMemory: [],
        selectedVillageId: null,
      } as never,
      villageStore: store,
    });
    const service = new SnapshotImportService({
      state,
      clock: new FakeClock(),
      importTransaction: null,
      history: null,
      manual: null,
    });
    expect(state.getGeneration()).toBe(0);
    expect(() => service.prepare({ text: '{"tag":"#X","buildings":[]}' })).toThrow(AppServiceError);
    expect(state.getPending()).toBeNull();
    expect(state.getGeneration()).toBe(0);
  });
});
