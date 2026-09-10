/**
 * Upgrade Overview 会话态（#277-B1）：纯函数，只消费 Overview DTO。
 * 不重算完成度/分组/排序/diff；stale 语义与 app-session.ts 一致。
 */
import type {
  CatalogAvailabilityDto,
  EffectiveVillageItemStatusDto,
  ProgressMetricDto,
  TrackerBaseDto,
  UpgradeDisplayRecordDto,
  UpgradeOverviewPayload,
  VillageItemStateDto,
  VillageProgressMetricsDto,
  VillageItemStatusDto,
} from '@coc-helper/contracts';

export type OverviewCursor = {
  readonly sessionId: string;
  readonly generation: number;
};

export type OverviewState = {
  readonly status: 'loading' | 'ready' | 'error';
  /** 最近一次成功 payload；error 且非 null 即 failed-with-last-good。 */
  readonly payload: UpgradeOverviewPayload | null;
  readonly lastError: string | null;
};

export const INITIAL_OVERVIEW_STATE: OverviewState = {
  status: 'loading',
  payload: null,
  lastError: null,
};

/**
 * 是否接受 Overview 帧。
 * sessionId 必须取自权威 `AppSnapshotPayload.sessionId`（Overview payload 无 sessionId 字段）；
 * 跨 session 必须拒绝，调用方不得传常量。
 */
export function shouldAcceptOverview(
  current: OverviewCursor | null,
  sessionId: string,
  generation: number,
): boolean {
  if (current === null) {
    return true;
  }
  if (sessionId !== current.sessionId) {
    return false;
  }
  return generation >= current.generation;
}

/** sessionId 必须取自权威 `AppSnapshotPayload.sessionId`（Overview payload 无 sessionId 字段）。 */
export function cursorFromOverview(
  sessionId: string,
  payload: { readonly generation: number },
): OverviewCursor {
  return { sessionId, generation: payload.generation };
}

export function applyOverviewSuccess(payload: UpgradeOverviewPayload): OverviewState {
  return { status: 'ready', payload, lastError: null };
}

export function applyOverviewError(prev: OverviewState, message: string): OverviewState {
  if (prev.payload === null) {
    return { status: 'error', payload: null, lastError: message };
  }
  return { status: 'ready', payload: prev.payload, lastError: message };
}

export function isCatalogUnavailable(payload: UpgradeOverviewPayload): boolean {
  return !payload.catalogIsUsable;
}

export function isEmptyOverview(payload: UpgradeOverviewPayload): boolean {
  return (
    payload.active.length === 0 &&
    payload.pending.length === 0 &&
    payload.state.activeRecords.length === 0 &&
    payload.state.attentionRecords.length === 0 &&
    payload.state.needsReimportRecords.length === 0 &&
    payload.state.completedRecently.length === 0
  );
}

export function statusLabel(status: VillageItemStatusDto): string {
  switch (status) {
    case 'upgrading':
      return '进行中';
    case 'complete':
      return '已完成';
    case 'maxed':
      return '已满级';
    case 'unknown':
      return '未知';
    case 'unavailable':
      return '不可用';
    case 'available':
      return '可升级';
    case 'unverified':
      return '未验证';
    default: {
      const exhaustive: never = status;
      throw new Error(`未知状态：${String(exhaustive)}`);
    }
  }
}

export function effectiveStatusLabel(status: EffectiveVillageItemStatusDto | null): string | null {
  if (status === null) {
    return null;
  }
  switch (status) {
    case 'observed':
      return '已同步';
    case 'manualCompleted':
      return '手动已完成';
    case 'manualActive':
      return '手动进行中';
    case 'importedActive':
      return '导入进行中';
    case 'needsReimport':
      return '待重新导入';
    case 'conflict':
      return '冲突';
    case 'unknown':
      return '未知';
    case 'unavailable':
      return '不可用';
    default: {
      const exhaustive: never = status;
      throw new Error(`未知有效状态：${String(exhaustive)}`);
    }
  }
}

/** permanent → null 表示无徽标、不渲染。 */
export function availabilityLabel(availability: CatalogAvailabilityDto): string | null {
  switch (availability.kind) {
    case 'permanent':
      return null;
    case 'seasonal':
      return `限时：${availability.phaseName ?? availability.phaseID}`;
    case 'unconfigured':
      return '目录未配置';
    case 'conflict':
      return `声明冲突：${availability.phaseName ?? availability.phaseID}`;
    default: {
      const exhaustive: never = availability;
      throw new Error(`未知可用性：${String(exhaustive)}`);
    }
  }
}

export function baseLabel(base: TrackerBaseDto): string {
  switch (base) {
    case 'home':
      return '主村';
    case 'builder':
      return '夜世界';
    default: {
      const exhaustive: never = base;
      throw new Error(`未知基地：${String(exhaustive)}`);
    }
  }
}

/** 测试与组件共用的最小记录 fixture（字段按 contracts/projection-ipc.ts 全量给出）。 */
export function recordFixture(
  overrides: Partial<UpgradeDisplayRecordDto> = {},
): UpgradeDisplayRecordDto {
  const metrics: VillageProgressMetricsDto = {
    currentStageProgress: metricFixture(),
    globalProgress: metricFixture(),
    snapshotCoverage: metricFixture(),
    instanceProgress: metricFixture(),
    effectiveTrackerProgress: metricFixture(),
  };
  return {
    id: 'rec-1',
    villageID: 'v1',
    villageName: '主村',
    villageTag: '#AAA',
    base: 'home',
    catalogVersion: '18.400.13',
    villageMetrics: metrics,
    item: itemFixture(),
    ...overrides,
  };
}

function metricFixture(): ProgressMetricDto {
  return {
    kind: 'test',
    numerator: 1,
    denominator: 2,
    state: 'ready' as const,
    saturated: false,
    units: 'items',
    degradedReason: null,
    ratio: 0.5,
  };
}

function itemFixture(): VillageItemStateDto {
  return {
    id: 'item-1',
    section: 'buildings',
    dataID: 1000001,
    base: 'home',
    name: '加农炮',
    category: 'buildings',
    currentLevel: 5,
    count: 1,
    timerSeconds: null,
    remainingSeconds: null,
    nextLevel: 6,
    nextLevelDurationSeconds: 3600,
    nextLevelDurationState: { kind: 'timed', seconds: 3600 },
    maxLevel: 10,
    currentStageMaxLevel: 10,
    nextUpgrade: { kind: 'available', level: 6, durationSeconds: 3600 },
    status: 'upgrading',
    missingReason: null,
    catalogItemMissingReason: null,
    availability: { kind: 'permanent' },
    icon: null,
    levelVisual: null,
    currentLevelIcon: null,
    currentLevelVisual: null,
    isNested: false,
    displayCategory: 'defense',
    countOverflowed: false,
    effectiveStatus: 'importedActive',
    effectiveCurrentLevel: 5,
    effectiveTargetLevel: 6,
    effectiveNextUpgrade: { kind: 'available', level: 6, durationSeconds: 3600 },
    effectiveNextLevelDurationState: { kind: 'timed', seconds: 3600 },
    effectiveDiagnostic: null,
    effectiveIsMaxed: false,
  };
}
