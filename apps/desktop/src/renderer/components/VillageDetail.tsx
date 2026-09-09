import { useMemo } from 'react';

import type {
  BuildingGroupDto,
  TrackerBaseDto,
  VillageCategoryCompletionDto,
  VillageDetailFlatRowDto,
  VillageDetailGroupDto,
  VillageItemStateDto,
} from '@coc-helper/contracts';

import { baseLabel, effectiveStatusLabel, statusLabel } from '../overview-session';
import {
  compatibilityAlertText,
  compatibilityVersionText,
  formatCompletionPercent,
  groupTitleText,
  isEmptyDetail,
  levelTransitionText,
  metricStateLabel,
  type VillageDetailState,
} from '../village-detail-session';

export type VillageDetailProps = {
  readonly state: VillageDetailState;
  readonly base: TrackerBaseDto;
  readonly onBaseChange: (base: TrackerBaseDto) => void;
  readonly onOpenLevel: (id: string) => void;
  readonly onRetry: () => void;
};

export function VillageDetail({
  state,
  base,
  onBaseChange,
  onOpenLevel,
  onRetry,
}: VillageDetailProps) {
  const { status, payload, lastError } = state;
  const lookups = useMemo(() => (payload === null ? null : buildLookups(payload)), [payload]);

  if (payload === null || lookups === null) {
    if (status === 'idle') {
      return (
        <section className="detail-panel" aria-label="村庄详情">
          <p className="muted">先选择村庄查看详情</p>
        </section>
      );
    }
    if (status === 'error') {
      return (
        <section className="detail-panel" aria-label="村庄详情">
          <p className="error-text" role="alert">
            {lastError ?? '村庄详情加载失败'}
          </p>
          <button type="button" onClick={onRetry}>
            重试
          </button>
        </section>
      );
    }
    return (
      <section className="detail-panel" aria-label="村庄详情">
        <p className="muted">正在加载村庄详情…</p>
      </section>
    );
  }

  const alert = compatibilityAlertText(payload.compatibility);
  const version = compatibilityVersionText(payload.compatibility);

  return (
    <section className="detail-panel" aria-label="村庄详情">
      <DetailHeader
        villageName={payload.villageName}
        villageTag={payload.villageTag}
        version={version}
        base={base}
        onBaseChange={onBaseChange}
      />
      {lastError !== null ? (
        <p className="notice-text" role="alert">
          数据可能过期：{lastError}
        </p>
      ) : null}
      {alert !== null ? (
        <p className="notice-text" role="alert">
          {alert}
        </p>
      ) : null}
      {isEmptyDetail(payload) ? <p className="muted">该村庄暂无详情数据</p> : null}
      <MetricsCards payload={payload} />
      <FlatRows payload={payload} lookups={lookups} onOpenLevel={onOpenLevel} />
    </section>
  );
}

function DetailHeader(props: {
  readonly villageName: string;
  readonly villageTag: string | null;
  readonly version: string | null;
  readonly base: TrackerBaseDto;
  readonly onBaseChange: (base: TrackerBaseDto) => void;
}) {
  return (
    <div className="detail-header">
      <h2>
        {props.villageName}
        {props.villageTag !== null ? `（${props.villageTag}）` : ''}
      </h2>
      {props.version !== null ? <p className="muted">目录版本 {props.version}</p> : null}
      <div className="base-switch" role="group" aria-label="基地切换">
        {(['home', 'builder'] as const).map((b) => (
          <button
            key={b}
            type="button"
            aria-pressed={props.base === b}
            onClick={() => props.onBaseChange(b)}
          >
            {baseLabel(b)}
          </button>
        ))}
      </div>
    </div>
  );
}

type Lookups = {
  readonly itemsById: ReadonlyMap<string, VillageItemStateDto>;
  readonly groupsById: ReadonlyMap<string, VillageDetailGroupDto>;
  readonly groupOfInstance: ReadonlyMap<string, BuildingGroupDto>;
};

function buildLookups(payload: Parameters<typeof isEmptyDetail>[0]): Lookups {
  const itemsById = new Map(payload.items.map((item) => [item.id, item] as const));
  const groupsById = new Map(payload.groups.map((group) => [group.id, group] as const));
  const groupOfInstance = new Map<string, BuildingGroupDto>();
  for (const group of payload.buildingGroups) {
    for (const instanceId of group.instanceIds) {
      if (!groupOfInstance.has(instanceId)) {
        groupOfInstance.set(instanceId, group);
      }
    }
  }
  return { itemsById, groupsById, groupOfInstance };
}

function MetricsCards(props: { readonly payload: Parameters<typeof isEmptyDetail>[0] }) {
  const entries = [
    { title: '当前阶段', metric: props.payload.metrics.currentStageProgress },
    { title: '全局进度', metric: props.payload.metrics.globalProgress },
    { title: '快照覆盖', metric: props.payload.metrics.snapshotCoverage },
    { title: '实例进度', metric: props.payload.metrics.instanceProgress },
    { title: '有效追踪', metric: props.payload.metrics.effectiveTrackerProgress },
  ] as const;
  return (
    <ul className="metrics-list">
      {entries.map((entry) => (
        <li key={entry.title} className="metric-card">
          <span className="metric-title">{entry.title}</span>
          <span className="muted">
            {entry.metric.numerator}/{entry.metric.denominator} {entry.metric.units} ·{' '}
            {metricStateLabel(entry.metric.state)}
            {entry.metric.degradedReason !== null ? `（${entry.metric.degradedReason}）` : ''}
          </span>
        </li>
      ))}
    </ul>
  );
}

function FlatRows(props: {
  readonly payload: Parameters<typeof isEmptyDetail>[0];
  readonly lookups: Lookups;
  readonly onOpenLevel: (id: string) => void;
}) {
  return (
    <div className="detail-rows">
      {props.payload.flatRows.map((row) => (
        <FlatRow
          key={rowKey(row)}
          row={row}
          payload={props.payload}
          lookups={props.lookups}
          onOpenLevel={props.onOpenLevel}
        />
      ))}
    </div>
  );
}

function rowKey(row: VillageDetailFlatRowDto): string {
  switch (row.kind) {
    case 'sectionHeader':
      return `section:${row.groupID}`;
    case 'craftTable':
      return `craft:${row.groupID}`;
    case 'groupHeader':
      return `group:${row.groupID}`;
    case 'instance':
      return `instance:${row.instanceID}`;
    case 'legacy':
      return `legacy:${row.itemID}`;
    default: {
      const exhaustive: never = row;
      throw new Error(`未知详情行：${String(exhaustive)}`);
    }
  }
}

function FlatRow(props: {
  readonly row: VillageDetailFlatRowDto;
  readonly payload: Parameters<typeof isEmptyDetail>[0];
  readonly lookups: Lookups;
  readonly onOpenLevel: (id: string) => void;
}) {
  const { row, lookups, onOpenLevel } = props;
  switch (row.kind) {
    case 'sectionHeader': {
      const group = lookups.groupsById.get(row.groupID);
      return (
        <div className="detail-section">
          <h3>{group === undefined ? row.groupID : groupTitleText(group)}</h3>
          {row.stats === null ? null : <StatsLine stats={row.stats} />}
        </div>
      );
    }
    case 'craftTable': {
      return (
        <div className="detail-section">
          <h3>精制台</h3>
          {row.stats === null ? null : <StatsLine stats={row.stats} />}
        </div>
      );
    }
    case 'groupHeader': {
      const group = lookups.groupsById.get(row.groupID);
      return (
        <div className="detail-section">
          <h4>{group === undefined ? row.groupID : groupTitleText(group)}</h4>
        </div>
      );
    }
    case 'instance': {
      const group = lookups.groupOfInstance.get(row.instanceID);
      if (group === undefined) {
        return <p className="muted">未知分组实例（{row.instanceID}）</p>;
      }
      return (
        <div className="detail-row">
          {row.leadingDivider ? <hr className="row-divider" /> : null}
          <button
            type="button"
            className="detail-item"
            aria-label={`${group.name}，打开等级详情`}
            onClick={() => onOpenLevel(row.instanceID)}
          >
            <span className="detail-item-name">{group.name}</span>
            <span className="muted">
              {group.summary.instanceCount} 实例 · 剩余 {group.summary.remainingLevelCount} 级 ·
              累计耗时 {group.summary.totalDurationSeconds} 秒{costText(group)} ·{' '}
              {effectiveStatusLabel(group.trackerStatus)}
              {completenessText(group)}
            </span>
          </button>
        </div>
      );
    }
    case 'legacy': {
      const item = lookups.itemsById.get(row.itemID);
      if (item === undefined) {
        return <p className="muted">未知条目（{row.itemID}）</p>;
      }
      return (
        <div className={row.indented ? 'detail-row indented' : 'detail-row'}>
          {row.leadingDivider ? <hr className="row-divider" /> : null}
          <button
            type="button"
            className="detail-item"
            aria-label={`${item.name}，打开等级详情`}
            onClick={() => onOpenLevel(item.id)}
          >
            <span className="detail-item-name">{item.name}</span>
            <span className="muted">
              {levelTransitionText(item.currentLevel, item.nextLevel)} · {statusLabel(item.status)}
              {item.effectiveStatus === null
                ? ''
                : ` · ${effectiveStatusLabel(item.effectiveStatus) ?? ''}`}
            </span>
          </button>
        </div>
      );
    }
    default: {
      const exhaustive: never = row;
      throw new Error(`未知详情行：${String(exhaustive)}`);
    }
  }
}

function costText(group: BuildingGroupDto): string {
  if (group.summary.costByResource.length === 0) {
    return '';
  }
  return ` · ${group.summary.costByResource.map((entry) => `${entry.resource} ${entry.totalCost}`).join('、')}`;
}

function completenessText(group: BuildingGroupDto): string {
  switch (group.summary.completeness) {
    case 'complete':
      return '';
    case 'partialMissing':
      return ' · 部分缺失';
    case 'versionMismatch':
      return ' · 版本不一致';
    default: {
      const exhaustive: never = group.summary.completeness;
      throw new Error(`未知完整度：${String(exhaustive)}`);
    }
  }
}

function StatsLine(props: { readonly stats: VillageCategoryCompletionDto }) {
  const { stats } = props;
  const percent = formatCompletionPercent(stats.completionRatio);
  return (
    <p className="muted">
      已知 {stats.knownCount} · 完成 {stats.completedCount} · 未知 {stats.unknownCount}
      {percent === null ? '' : ` · ${percent}`}
      {stats.isFullyMaxed ? ' · 已满级' : ''}
    </p>
  );
}
