import { useEffect } from 'react';
import type {
  UpgradeDisplayRecordDto,
  UpgradeRecentCompletionDto,
  VillageSummaryDto,
} from '@coc-helper/contracts';

import {
  availabilityLabel,
  baseLabel,
  isCatalogUnavailable,
  isEmptyOverview,
  type OverviewState,
} from '../overview-session';
import {
  authoritativeLevelStatus,
  categoryGlyph,
  formatDurationSeconds,
  levelTransitionText,
  primaryLevelAssets,
} from '../village-detail-session';
import { AssetImage } from './AssetImage';

type UpgradeOverviewProps = {
  readonly state: OverviewState;
  readonly selectedId: string | null;
  readonly villages: readonly VillageSummaryDto[];
  readonly onSelect: (id: string) => void;
  readonly onOpenDetail?: (recordId: string, villageId: string) => void;
  readonly onRetry: () => void;
};

export function UpgradeOverview({
  state,
  selectedId,
  villages,
  onSelect,
  onOpenDetail,
  onRetry,
}: UpgradeOverviewProps) {
  const { status, payload, lastError } = state;

  useEffect(() => {
    if (payload !== null) {
      globalThis.performance.mark('coc-helper:renderer:overview:commit');
    }
  }, [payload]);

  if (payload === null) {
    if (status === 'error') {
      return (
        <section className="overview-panel" aria-label="升级追踪" data-perf-state="error">
          <div className="empty-state">
            <span className="empty-mark" aria-hidden="true">
              !
            </span>
            <h2>营地数据暂时不可用</h2>
            <p className="muted" role="alert">
              {lastError ?? '升级追踪加载失败'}
            </p>
            <button type="button" className="primary-action" onClick={onRetry}>
              重试
            </button>
          </div>
        </section>
      );
    }
    return (
      <section className="overview-panel" aria-label="升级追踪" data-perf-state="loading">
        <div className="loading-state">
          <span className="loading-orbit" aria-hidden="true" />
          <p className="muted">正在整理营地数据…</p>
        </div>
      </section>
    );
  }

  const unavailable = isCatalogUnavailable(payload);
  const empty = isEmptyOverview(payload);
  const active = payload.active;
  const pending = payload.pending;
  const attention = payload.state.attentionRecords;
  const needsReimport = payload.state.needsReimportRecords;

  return (
    <section className="overview-panel" aria-label="升级追踪" data-perf-state="ready">
      {lastError !== null ? (
        <p className="notice-text shell-alert" role="alert">
          数据可能过期：{lastError}
        </p>
      ) : null}
      {unavailable ? (
        <p className="notice-text shell-alert" role="alert">
          游戏目录不可用，升级追踪暂不可展示。以下为快照侧记录，仅供参考。
        </p>
      ) : null}

      <section className="camp-hero" aria-label="多村庄升级追踪">
        <div className="camp-copy">
          <p className="hero-eyebrow">
            UPGRADE TRACKER <span>/</span> MULTI-VILLAGE OVERVIEW
          </p>
          <h2>所有村庄的升级动态</h2>
          <p className="camp-description">
            {empty
              ? payload.state.manualCompletedCount > 0
                ? '当前没有进行中或待处理的升级，已记录 ' +
                  payload.state.manualCompletedCount +
                  ' 项手动完成。'
                : '导入游戏账号后，这里会汇总所有村庄正在进行和待安排的升级。'
              : '已收录 ' +
                villages.length +
                ' 个村庄档案，当前有 ' +
                active.length +
                ' 项进行中，' +
                pending.length +
                ' 项待开始。点击条目查看对应村庄详情。'}
          </p>
          <OverviewCounts
            manualActiveCount={payload.state.manualActiveCount}
            importedActiveCount={payload.state.importedActiveCount}
            manualCompletedCount={payload.state.manualCompletedCount}
          />
        </div>
        <CampMapIllustration />
      </section>

      <div className="overview-stats" aria-label="升级记录概况">
        <SummaryCard label="进行中" value={active.length} symbol="↗" tone="active" />
        <SummaryCard label="待开始" value={pending.length} symbol="◷" tone="pending" />
        <SummaryCard label="需要关注" value={attention.length} symbol="!" tone="attention" />
        <SummaryCard label="待重新导入" value={needsReimport.length} symbol="↻" tone="reimport" />
      </div>

      <div className="overview-grid">
        {active.length > 0 ? (
          <RecordList
            title="进行中"
            description="当前正在推进的升级"
            records={active}
            selectedId={selectedId}
            onSelect={onSelect}
            onOpenDetail={onOpenDetail}
            emphasis
          />
        ) : (
          <section className="content-card empty-card" aria-label="进行中">
            <div className="card-heading">
              <div className="heading-left">
                <span className="section-mark" aria-hidden="true">
                  ↗
                </span>
                <div>
                  <h3>进行中</h3>
                  <p>当前正在推进的升级</p>
                </div>
              </div>
              <span className="record-badge">0</span>
            </div>
            <p className="empty-state compact">暂无进行中的升级</p>
          </section>
        )}

        <div className="overview-rail">
          <RecordList
            title="待开始"
            description="已安排，等待开工"
            records={pending}
            selectedId={selectedId}
            onSelect={onSelect}
            onOpenDetail={onOpenDetail}
          />
          <RecordList
            title="需要关注"
            description="有数据状态需要留意"
            records={attention}
            selectedId={selectedId}
            onSelect={onSelect}
            onOpenDetail={onOpenDetail}
          />
          <RecordList
            title="待重新导入"
            description="更新快照后继续追踪"
            records={needsReimport}
            selectedId={selectedId}
            onSelect={onSelect}
            onOpenDetail={onOpenDetail}
          />
          {pending.length + attention.length + needsReimport.length === 0 ? (
            <div className="quiet-card">
              <span className="quiet-mark" aria-hidden="true">
                ✦
              </span>
              <div>
                <strong>暂无待处理</strong>
                <p>目前没有其他待处理记录。</p>
              </div>
            </div>
          ) : null}
          <RecentCompletions records={payload.state.completedRecently} villages={villages} />
        </div>
      </div>
    </section>
  );
}

function RecentCompletions(props: {
  readonly records: readonly UpgradeRecentCompletionDto[];
  readonly villages: readonly VillageSummaryDto[];
}) {
  if (props.records.length === 0) {
    return null;
  }

  const villagesById = new Map(props.villages.map((village) => [village.id, village] as const));
  return (
    <section className="content-card completion-card" aria-label="近期完成">
      <div className="card-heading">
        <div className="heading-left">
          <span className="section-mark" aria-hidden="true">
            ✓
          </span>
          <div>
            <h3>近期完成</h3>
            <p>最近完成的升级</p>
          </div>
        </div>
        <span className="record-badge">{props.records.length}</span>
      </div>
      <ul className="completion-list">
        {props.records.map((record) => {
          const village = villagesById.get(record.villageID);
          const villageName =
            village === undefined
              ? '已移除的村庄'
              : `${village.name}${village.tag === null ? '' : `（${village.tag}）`}`;
          const date = new Date(record.completedAtMs);
          return (
            <li key={record.id}>
              <span className="completion-copy">
                <strong>{record.itemName}</strong>
                <span>
                  {villageName} · {record.quantity > 1 ? `${record.quantity} 项 · ` : ''}升至{' '}
                  {record.targetLevel} 级
                </span>
              </span>
              <time dateTime={Number.isNaN(date.getTime()) ? undefined : date.toISOString()}>
                {Number.isNaN(date.getTime())
                  ? '时间未知'
                  : new Intl.DateTimeFormat('zh-CN', { month: 'numeric', day: 'numeric' }).format(
                      date,
                    )}
              </time>
            </li>
          );
        })}
      </ul>
    </section>
  );
}

function OverviewCounts(props: {
  readonly manualActiveCount: number;
  readonly importedActiveCount: number;
  readonly manualCompletedCount: number;
}) {
  return (
    <div className="camp-meta">
      <span>
        <i className="meta-dot manual" />
        手动进行中 {props.manualActiveCount}
      </span>
      <span>
        <i className="meta-dot imported" />
        导入进行中 {props.importedActiveCount}
      </span>
      <span>
        <i className="meta-dot completed" />
        手动已完成 {props.manualCompletedCount}
      </span>
    </div>
  );
}

function SummaryCard(props: {
  readonly label: string;
  readonly value: number;
  readonly symbol: string;
  readonly tone: 'active' | 'pending' | 'attention' | 'reimport';
}) {
  return (
    <article className={'stat-card ' + props.tone}>
      <div className="stat-top">
        <span>{props.label}</span>
        <span className="stat-symbol" aria-hidden="true">
          {props.symbol}
        </span>
      </div>
      <div className="stat-value">
        {props.value}
        <small>项记录</small>
      </div>
    </article>
  );
}

function CampMapIllustration() {
  return (
    <div className="camp-map" aria-hidden="true">
      <svg viewBox="0 0 540 230" role="presentation">
        <ellipse cx="281" cy="151" rx="226" ry="68" fill="url(#camp-ground)" />
        <path
          d="M64 146c37-37 93-55 147-45 40 7 69 27 111 25 44-2 87-29 143-19 22 4 41 15 57 31"
          className="map-contour"
        />
        <path
          d="M82 161c48-30 88-39 133-29 47 11 74 35 121 32 50-2 87-27 137-19 19 3 36 10 51 20"
          className="map-contour second"
        />
        <path
          d="M115 126c27-17 60-28 92-21 27 6 50 25 80 24 36-1 57-23 92-22 23 1 41 8 59 21"
          className="map-contour third"
        />
        <path
          d="M83 154c70-4 102 19 164 16 66-4 98-35 165-31 34 2 55 11 76 25"
          className="map-road"
        />
        <path d="M93 152c68-4 103 20 154 17 69-4 101-34 166-31" className="map-road-edge" />
        <g className="map-keep" transform="translate(237 75)">
          <path d="m30 0 31 18v40H0V18L30 0Z" />
          <path d="M10 27h40M16 58V37l14-10 14 10v21M25 58V44h10v14" />
          <path d="m24 18 6-8 6 8" />
        </g>
        <g className="map-tower" transform="translate(140 118)">
          <path d="M0 14 17 3l17 11v31H0V14Z" />
          <path d="M11 45V24h12v21M7 15h20" />
        </g>
        <g className="map-tower small" transform="translate(352 111)">
          <path d="M0 13 15 4l15 9v28H0V13Z" />
          <path d="M10 41V22h10v19M6 14h18" />
        </g>
        <circle className="map-pin-halo" cx="282" cy="68" r="12" />
        <circle className="map-pin" cx="282" cy="68" r="5" />
        <defs>
          <linearGradient
            id="camp-ground"
            x1="55"
            x2="502"
            y1="106"
            y2="188"
            gradientUnits="userSpaceOnUse"
          >
            <stop stopColor="#5c744d" />
            <stop offset=".52" stopColor="#77915b" />
            <stop offset="1" stopColor="#435f43" />
          </linearGradient>
        </defs>
      </svg>
      <span className="map-label map-label-keep">营地中心</span>
      <span className="map-label map-label-east">建设区域</span>
      <span className="map-compass">
        N <i>↗</i>
      </span>
    </div>
  );
}

function RecordList(props: {
  readonly title: string;
  readonly description: string;
  readonly records: readonly UpgradeDisplayRecordDto[];
  readonly selectedId: string | null;
  readonly onSelect: (id: string) => void;
  readonly onOpenDetail?: (recordId: string, villageId: string) => void;
  readonly emphasis?: boolean;
}) {
  if (props.records.length === 0) {
    return null;
  }
  return (
    <section
      className={props.emphasis ? 'content-card record-card emphasis' : 'content-card record-card'}
      aria-label={props.title}
    >
      <div className="card-heading">
        <div className="heading-left">
          <span className="section-mark" aria-hidden="true">
            {sectionSymbol(props.title)}
          </span>
          <div>
            <h3>{props.title}</h3>
            <p>{props.description}</p>
          </div>
        </div>
        <span className="record-badge">{props.records.length}</span>
      </div>
      <ul className="overview-list">
        {props.records.map((record) => (
          <li key={record.id}>
            <button
              type="button"
              className={
                record.id === props.selectedId ? 'overview-item selected' : 'overview-item'
              }
              aria-pressed={record.id === props.selectedId}
              onClick={() => {
                props.onSelect(record.id);
                props.onOpenDetail?.(record.id, record.villageID);
              }}
            >
              <AssetImage
                catalogVersion={record.catalogVersion}
                candidates={primaryLevelAssets(record.item)}
                size={36}
                className="overview-item-icon"
                fallbackNode={
                  <span className="overview-item-glyph" aria-hidden="true">
                    {categoryGlyph(record.item.displayCategory, record.item.category)}
                  </span>
                }
              />
              <span className="overview-item-name">{record.item.name}</span>
              <span className="level-pill">
                {levelTransitionText(
                  record.item.effectiveCurrentLevel,
                  record.item.effectiveTargetLevel,
                )}
              </span>
              <span className="overview-item-meta">
                {record.villageName}
                {record.villageTag === null ? '' : `（${record.villageTag}）`} ·{' '}
                {baseLabel(record.base)} · {authoritativeLevelStatus(record.item)}
                {record.effectiveRemainingSeconds !== null && record.effectiveRemainingSeconds > 0
                  ? ` · 剩余 ${formatDurationSeconds(record.effectiveRemainingSeconds)}`
                  : ''}
                {availabilityText(record)}
              </span>
            </button>
          </li>
        ))}
      </ul>
    </section>
  );
}

function sectionSymbol(title: string): string {
  switch (title) {
    case '进行中':
      return '↗';
    case '待开始':
      return '◷';
    case '需要关注':
      return '!';
    case '待重新导入':
      return '↻';
    default:
      return '•';
  }
}

function availabilityText(record: UpgradeDisplayRecordDto): string {
  const label = availabilityLabel(record.item.availability);
  return label === null ? '' : ' · ' + label;
}
