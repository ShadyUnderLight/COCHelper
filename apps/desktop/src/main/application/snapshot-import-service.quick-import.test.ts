import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  bootstrapPersistence,
  PERSISTENCE_FILE_NAMES,
  type ElectronPersistencePaths,
} from '@coc-helper/domain';
import { afterEach, describe, expect, it } from 'vitest';

import { AppAuthoritativeState, AppServiceError } from './app-authoritative-state';
import { PersistentVillageStore } from './persistent-village-store';
import { SnapshotImportService } from './snapshot-import-service';
import { ManualTrackerService } from './manual-tracker-service';

class FakeClock {
  nowMs(): number {
    return 1_700_000_000_000;
  }
}

const tempRoots: string[] = [];

function pathsFor(root: string): ElectronPersistencePaths {
  return {
    root,
    villages: join(root, PERSISTENCE_FILE_NAMES.villages),
    villagesRecovery: join(root, PERSISTENCE_FILE_NAMES.villagesRecovery),
    selection: join(root, PERSISTENCE_FILE_NAMES.selection),
    snapshotHistory: join(root, PERSISTENCE_FILE_NAMES.snapshotHistory),
    snapshotHistoryJournal: join(root, PERSISTENCE_FILE_NAMES.snapshotHistoryJournal),
    manualTracker: join(root, PERSISTENCE_FILE_NAMES.manualTracker),
    manualTrackerJournal: join(root, PERSISTENCE_FILE_NAMES.manualTrackerJournal),
    snapshotImportJournal: join(root, PERSISTENCE_FILE_NAMES.snapshotImportJournal),
    clans: join(root, PERSISTENCE_FILE_NAMES.clans),
    clanWars: join(root, PERSISTENCE_FILE_NAMES.clanWars),
    clanWarLogs: join(root, PERSISTENCE_FILE_NAMES.clanWarLogs),
    clanCapitals: join(root, PERSISTENCE_FILE_NAMES.clanCapitals),
    playerStates: join(root, PERSISTENCE_FILE_NAMES.playerStates),
    trackedClans: join(root, PERSISTENCE_FILE_NAMES.trackedClans),
    apiTokenEncrypted: join(root, PERSISTENCE_FILE_NAMES.apiTokenEncrypted),
  };
}

function bootService() {
  const root = mkdtempSync(join(tmpdir(), 'coc-quick-'));
  tempRoots.push(root);
  const paths = pathsFor(root);
  const persistence = bootstrapPersistence({ paths });
  const villageStore = new PersistentVillageStore({
    villages: persistence.villages,
    selection: persistence.selection,
    initialVillages: persistence.villagesInMemory,
    initialSelectedVillageId: persistence.selectedVillageId,
  });
  const state = new AppAuthoritativeState({ persistence, villageStore });
  const clock = new FakeClock();
  const manualTracker = new ManualTrackerService({
    state,
    clock,
    manual: persistence.manual,
    history: persistence.history,
    catalog: {
      getBundle: async () => {
        throw new Error('catalog not needed for quick import tests');
      },
    },
  });
  const service = new SnapshotImportService({
    state,
    clock,
    importTransaction: persistence.importTransaction,
    history: persistence.history,
    manual: persistence.manual,
    manualTracker,
  });
  return { persistence, villageStore, state, service };
}

function createVillage(
  service: SnapshotImportService,
  text: string,
): { villageId: string; generation: number } {
  const prepared = service.prepare({ text });
  const committed = service.commit(prepared.generation);
  const villageId = committed.selectedVillageId;
  if (villageId === null) {
    throw new Error('expected created village id');
  }
  return { villageId, generation: committed.generation };
}

afterEach(() => {
  while (tempRoots.length > 0) {
    const root = tempRoots.pop();
    if (root !== undefined) {
      rmSync(root, { recursive: true, force: true });
    }
  }
});

describe('SnapshotImportService quick import', () => {
  it('空剪贴板 → validation', () => {
    const { service } = bootService();
    const { villageId } = createVillage(service, '{"tag":"#QEMPTY","buildings":[]}');
    expect(() => service.quickPrepare({ targetVillageId: villageId, text: '   \n' })).toThrowError(
      AppServiceError,
    );
    try {
      service.quickPrepare({ targetVillageId: villageId, text: '' });
    } catch (error) {
      expect((error as AppServiceError).code).toBe('validation');
      return;
    }
    throw new Error('expected validation error');
  });

  it('非法 JSON → validation', () => {
    const { service } = bootService();
    const { villageId } = createVillage(service, '{"tag":"#QBAD","buildings":[]}');
    try {
      service.quickPrepare({ targetVillageId: villageId, text: 'not json' });
    } catch (error) {
      expect((error as AppServiceError).code).toBe('validation');
      return;
    }
    throw new Error('expected validation error');
  });

  it('目标村庄不存在 → notFound', () => {
    const { service } = bootService();
    createVillage(service, '{"tag":"#QNF","buildings":[]}');
    try {
      service.quickPrepare({
        targetVillageId: '00000000-0000-0000-0000-000000009999',
        text: '{"tag":"#QNF","buildings":[]}',
      });
    } catch (error) {
      expect((error as AppServiceError).code).toBe('notFound');
      return;
    }
    throw new Error('expected notFound error');
  });

  it('Tag 属于其他村庄 → conflict', () => {
    const { service } = bootService();
    const a = createVillage(service, '{"tag":"#QAAA","buildings":[]}');
    const b = createVillage(service, '{"tag":"#QBBB","buildings":[]}');
    try {
      service.quickPrepare({
        targetVillageId: a.villageId,
        text: '{"tag":"#QBBB","buildings":[]}',
      });
    } catch (error) {
      expect((error as AppServiceError).code).toBe('conflict');
      expect(b.villageId).not.toBe(a.villageId);
      return;
    }
    throw new Error('expected conflict error');
  });

  it('首次导入：prepare 描述走建立分支，commit 经事务落盘', () => {
    const { persistence, villageStore, state, service } = bootService();
    const { villageId } = createVillage(service, '{"tag":"#QFIRST","buildings":[]}');
    // 用无快照的新村做首次导入目标：先建空村再 quick
    const empty = service.prepare({ text: '{"tag":"#QEMPTY2","buildings":[]}' });
    const created = service.commit(empty.generation);
    const targetId = created.selectedVillageId!;
    const prepared = service.quickPrepare({
      targetVillageId: targetId,
      text: '{"tag":"#QNEW1","buildings":[]}',
    });
    expect(prepared.preview.targetVillageId).toBe(targetId);
    expect(prepared.preview.targetVillageHasSnapshot).toBe(true);
    const committed = service.quickCommit(prepared.generation);
    expect(committed.selectedVillageId).toBe(targetId);
    expect(villageStore.listVillages().find((v) => v.id === targetId)?.tag).toBe('#QNEW1');
    expect(state.getGeneration()).toBe(committed.generation);
    expect(persistence.history.load()).not.toBeNull();
    expect(villageId).not.toBe(targetId);
  });

  it('同 Tag 更新：commit 成功且选中目标', () => {
    const { villageStore, service } = bootService();
    const { villageId } = createVillage(service, '{"tag":"#QSAME","buildings":[]}');
    const prepared = service.quickPrepare({
      targetVillageId: villageId,
      text: '{"tag":"#QSAME","buildings":[]}',
    });
    expect(prepared.preview.replacesSameTag).toBe(true);
    const committed = service.quickCommit(prepared.generation);
    expect(committed.selectedVillageId).toBe(villageId);
    expect(villageStore.listVillages().find((v) => v.id === villageId)?.tag).toBe('#QSAME');
  });

  it('选择变化后仍写入原目标并切回选中', () => {
    const { villageStore, state, service } = bootService();
    const a = createVillage(service, '{"tag":"#QSELA","buildings":[]}');
    const b = createVillage(service, '{"tag":"#QSELB","buildings":[]}');
    const prepared = service.quickPrepare({
      targetVillageId: a.villageId,
      text: '{"tag":"#QSELA","buildings":[]}',
    });
    villageStore.setSelectedVillageId(b.villageId);
    expect(state.getSelectedVillageId()).toBe(b.villageId);
    const committed = service.quickCommit(prepared.generation);
    expect(committed.selectedVillageId).toBe(a.villageId);
    expect(villageStore.listVillages().find((v) => v.id === a.villageId)?.tag).toBe('#QSELA');
  });

  it('确认前 generation 变化 → conflict', () => {
    const { service } = bootService();
    const { villageId } = createVillage(service, '{"tag":"#QSTALE","buildings":[]}');
    const prepared = service.quickPrepare({
      targetVillageId: villageId,
      text: '{"tag":"#QSTALE","buildings":[]}',
    });
    // 普通 prepare 推进 generation，使 quick 的 expectedGeneration 过期
    service.prepare({ text: '{"tag":"#QOTHER","buildings":[]}' });
    expect(() => service.quickCommit(prepared.generation)).toThrowError(AppServiceError);
    try {
      service.quickCommit(prepared.generation);
    } catch (error) {
      expect((error as AppServiceError).code).toBe('conflict');
    }
  });

  it('重复提交：旧 generation 已过期 → conflict，且不会写第二次', () => {
    const { villageStore, service } = bootService();
    const { villageId } = createVillage(service, '{"tag":"#QDUP","buildings":[]}');
    const prepared = service.quickPrepare({
      targetVillageId: villageId,
      text: '{"tag":"#QDUP","buildings":[]}',
    });
    service.quickCommit(prepared.generation);
    const tagAfterFirst = villageStore.listVillages().find((v) => v.id === villageId)?.tag;
    try {
      service.quickCommit(prepared.generation);
    } catch (error) {
      // generation 已推进：CAS 直接拒绝，不会触及 pending，更不会写第二次
      expect((error as AppServiceError).code).toBe('conflict');
      expect(villageStore.listVillages().find((v) => v.id === villageId)?.tag).toBe(tagAfterFirst);
      return;
    }
    throw new Error('expected conflict error on double commit');
  });

  it('discard 清理待确认且幂等', () => {
    const { service, state } = bootService();
    const { villageId } = createVillage(service, '{"tag":"#QDISC","buildings":[]}');
    const prepared = service.quickPrepare({
      targetVillageId: villageId,
      text: '{"tag":"#QDISC","buildings":[]}',
    });
    const discarded = service.quickDiscard(prepared.generation);
    expect(discarded.generation).toBe(state.getGeneration());
    const again = service.quickDiscard(discarded.generation);
    expect(again.generation).toBe(discarded.generation);
    // generation 是新的但已无待确认 → validation（不是 conflict）
    try {
      service.quickCommit(discarded.generation);
    } catch (error) {
      expect((error as AppServiceError).code).toBe('validation');
      return;
    }
    throw new Error('expected commit after discard to fail');
  });

  it('Renderer 不得回传 preview：commit 只用 Main 保存的快照', () => {
    const { villageStore, service } = bootService();
    const { villageId } = createVillage(service, '{"tag":"#QMAIN","buildings":[]}');
    const prepared = service.quickPrepare({
      targetVillageId: villageId,
      text: '{"tag":"#QMAIN","buildings":[]}',
    });
    // 即使调用方手头有 preview 对象，也无法把它作为写入依据：commit 签名只有 generation
    const keys = Object.keys(prepared);
    expect(keys).toEqual(expect.arrayContaining(['generation', 'preview']));
    service.quickCommit(prepared.generation);
    expect(villageStore.listVillages().find((v) => v.id === villageId)?.tag).toBe('#QMAIN');
  });

  it('新 generation 提交旧 pending → conflict 且不得写盘（pending 绑定创建代）', () => {
    const { persistence, villageStore, state, service } = bootService();
    const createdText = '{"tag":"#QTOK","buildings":[]}';
    const { villageId } = createVillage(service, createdText);
    // 同 Tag 但原文不同：若被错误提交，originalText 会变化，可被检测到
    const quickText = '{"tag": "#QTOK", "buildings": []}';
    const prepared = service.quickPrepare({ targetVillageId: villageId, text: quickText });
    expect(prepared.preview.replacesSameTag).toBe(true);
    // 另一个 authoritative mutation 推进 generation（普通 prepare，不写盘）
    const bumped = service.prepare({ text: '{"tag":"#QTOKNEW","buildings":[]}' });
    expect(bumped.generation).toBe(prepared.generation + 1);
    const historyEntriesBefore = persistence.history.load()?.entries.length ?? 0;

    try {
      service.quickCommit(bumped.generation);
    } catch (error) {
      expect((error as AppServiceError).code).toBe('conflict');
    }
    // 不得写盘：村庄快照原文不变，history 条目数不变
    const target = villageStore.listVillages().find((v) => v.id === villageId);
    expect(target?.tag).toBe('#QTOK');
    expect(target?.accountSnapshot?.originalText).toBe(createdText);
    expect(persistence.history.load()?.entries.length ?? 0).toBe(historyEntriesBefore);
    // 普通 pending 不受影响（无串扰）
    expect(state.getPending()?.snapshot.tag).toBe('#QTOKNEW');
    // 死 pending 已被清理：再次提交走 validation 而非重复 conflict 写盘风险
    try {
      service.quickCommit(bumped.generation);
    } catch (error) {
      expect((error as AppServiceError).code).toBe('validation');
      return;
    }
    throw new Error('expected validation error after stale pending cleanup');
  });

  it('新 generation discard 旧 pending → conflict、清理且不 bump', () => {
    const { service, state } = bootService();
    const { villageId } = createVillage(service, '{"tag":"#QTDISC","buildings":[]}');
    const prepared = service.quickPrepare({
      targetVillageId: villageId,
      text: '{"tag":"#QTDISC","buildings":[]}',
    });
    const bumped = service.prepare({ text: '{"tag":"#QTDISCNEW","buildings":[]}' });
    expect(bumped.generation).toBe(prepared.generation + 1);
    try {
      service.quickDiscard(bumped.generation);
    } catch (error) {
      expect((error as AppServiceError).code).toBe('conflict');
    }
    // 失败不 bump：generation 仍是 mutation 后的值
    expect(state.getGeneration()).toBe(bumped.generation);
    // 死 pending 已被清理：再次 discard 幂等返回，不抛错
    expect(service.quickDiscard(bumped.generation)).toEqual({ generation: bumped.generation });
  });

  it('quickPrepare 响应不得泄漏剪贴板原文（sentinel）', () => {
    const { service } = bootService();
    const { villageId } = createVillage(service, '{"tag":"#QSENT","buildings":[]}');
    // 只存在于 raw text 的秘密值：合法 JSON、可解析，但 UI 摘要不需要它
    const sentinel = 's3cr3t-clipboard-only-7f3a9c';
    const prepared = service.quickPrepare({
      targetVillageId: villageId,
      text: `{"tag":"#QSENT","buildings":[],"note":"${sentinel}"}`,
    });
    const serialized = JSON.stringify(prepared);
    expect(serialized).not.toContain(sentinel);
    expect(serialized).not.toContain('originalText');
    expect('originalText' in prepared.preview.snapshot).toBe(false);
    // UI 所需摘要字段仍在
    expect(prepared.preview.snapshot.tag).toBe('#QSENT');
    expect(prepared.preview.targetVillageId).toBe(villageId);
  });

  it('镜像：普通 prepare 后被 quickPrepare 顶掉代 → 普通 commit 必须 conflict 且零写入', () => {
    const { persistence, villageStore, state, service } = bootService();
    const { villageId } = createVillage(service, '{"tag":"#NMIRX","buildings":[]}');
    // 普通 prepare A（新建村庄）→ gen N，普通 pending A 存活
    const normal = service.prepare({ text: '{"tag":"#NMIRA","buildings":[]}' });
    // quickPrepare B 推进到 N+1：普通 pending A 变死，但仍躺在权威态里
    const quick = service.quickPrepare({
      targetVillageId: villageId,
      text: '{"tag":"#NMIRX","buildings":[]}',
    });
    expect(quick.generation).toBe(normal.generation + 1);
    const villagesBefore = villageStore.listVillages().length;
    const historyEntriesBefore = persistence.history.load()?.entries.length ?? 0;
    const manualBefore = JSON.stringify(persistence.manual.load());

    try {
      service.commit(quick.generation);
    } catch (error) {
      expect((error as AppServiceError).code).toBe('conflict');
    }
    // 零写入：没有 #NMIRA 村庄被创建，history/manual 纹丝不动
    expect(villageStore.listVillages()).toHaveLength(villagesBefore);
    expect(villageStore.listVillages().some((v) => v.tag === '#NMIRA')).toBe(false);
    expect(persistence.history.load()?.entries.length ?? 0).toBe(historyEntriesBefore);
    expect(JSON.stringify(persistence.manual.load())).toBe(manualBefore);
    // 死普通 pending 已被清理
    expect(state.getPending()).toBeNull();
    // 再提交走 validation（无待确认），而非重复 conflict 风险
    try {
      service.commit(quick.generation);
    } catch (error) {
      expect((error as AppServiceError).code).toBe('validation');
    }
    // quick pending B 仍可正常处理（无串扰）
    const committed = service.quickCommit(quick.generation);
    expect(committed.selectedVillageId).toBe(villageId);
  });

  it('镜像：普通 pending 过期后 discard → conflict、清理且不 bump', () => {
    const { service, state } = bootService();
    const { villageId } = createVillage(service, '{"tag":"#NMIRDX","buildings":[]}');
    const normal = service.prepare({ text: '{"tag":"#NMIRDNEW","buildings":[]}' });
    const quick = service.quickPrepare({
      targetVillageId: villageId,
      text: '{"tag":"#NMIRDX","buildings":[]}',
    });
    expect(quick.generation).toBe(normal.generation + 1);
    try {
      service.discard(quick.generation);
    } catch (error) {
      expect((error as AppServiceError).code).toBe('conflict');
    }
    expect(state.getGeneration()).toBe(quick.generation);
    expect(state.getPending()).toBeNull();
    expect(service.discard(quick.generation)).toEqual({ generation: quick.generation });
  });
});
