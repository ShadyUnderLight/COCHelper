import type { UpgradeDisplayRecordDto } from '@coc-helper/contracts';

import {
  availabilityLabel,
  baseLabel,
  effectiveStatusLabel,
  isCatalogUnavailable,
  isEmptyOverview,
  statusLabel,
  type OverviewState,
} from '../overview-session';
import { primaryLevelAssets } from '../village-detail-session';
import { AssetImage } from './AssetImage';

type UpgradeOverviewProps = {
  readonly state: OverviewState;
  readonly selectedId: string | null;
  readonly onSelect: (id: string) => void;
  readonly onOpenDetail?: (recordId: string, villageId: string) => void;
  readonly onRetry: () => void;
};

export function UpgradeOverview({
  state,
  selectedId,
  onSelect,
  onOpenDetail,
  onRetry,
}: UpgradeOverviewProps) {
  const { status, payload, lastError } = state;

  if (payload === null) {
    if (status === 'error') {
      return (
        <section className="overview-panel" aria-label="升级总览">
          <p className="error-text" role="alert">
            {lastError ?? '升级总览加载失败'}
          </p>
          <button type="button" onClick={onRetry}>
            重试
          </button>
        </section>
      );
    }
    return (
      <section className="overview-panel" aria-label="升级总览">
        <p className="muted">正在加载升级总览…</p>
      </section>
    );
  }

  const unavailable = isCatalogUnavailable(payload);
  const empty = isEmptyOverview(payload);

  return (
    <section className="overview-panel" aria-label="升级总览">
      {lastError !== null ? (
        <p className="notice-text" role="alert">
          数据可能过期：{lastError}
        </p>
      ) : null}
      {unavailable ? (
        <p className="notice-text" role="alert">
          游戏目录不可用，升级总览暂不可展示。以下为快照侧记录，仅供参考。
        </p>
      ) : null}
      {empty ? <p className="muted">暂无进行中的升级</p> : null}
      <OverviewCounts
        manualActiveCount={payload.state.manualActiveCount}
        importedActiveCount={payload.state.importedActiveCount}
        manualCompletedCount={payload.state.manualCompletedCount}
      />
      <RecordList
        title="进行中"
        records={payload.active}
        selectedId={selectedId}
        onSelect={onSelect}
        onOpenDetail={onOpenDetail}
      />
      <RecordList
        title="待开始"
        records={payload.pending}
        selectedId={selectedId}
        onSelect={onSelect}
        onOpenDetail={onOpenDetail}
      />
      <RecordList
        title="需要关注"
        records={payload.state.attentionRecords}
        selectedId={selectedId}
        onSelect={onSelect}
        onOpenDetail={onOpenDetail}
      />
      <RecordList
        title="待重新导入"
        records={payload.state.needsReimportRecords}
        selectedId={selectedId}
        onSelect={onSelect}
        onOpenDetail={onOpenDetail}
      />
    </section>
  );
}

function OverviewCounts(props: {
  readonly manualActiveCount: number;
  readonly importedActiveCount: number;
  readonly manualCompletedCount: number;
}) {
  return (
    <p className="muted">
      手动进行中 {props.manualActiveCount} · 导入进行中 {props.importedActiveCount} · 手动已完成{' '}
      {props.manualCompletedCount}
    </p>
  );
}

function RecordList(props: {
  readonly title: string;
  readonly records: readonly UpgradeDisplayRecordDto[];
  readonly selectedId: string | null;
  readonly onSelect: (id: string) => void;
  readonly onOpenDetail?: (recordId: string, villageId: string) => void;
}) {
  if (props.records.length === 0) {
    return null;
  }
  return (
    <div className="overview-group">
      <h3>{props.title}</h3>
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
                size={28}
                className="overview-item-icon"
                fallback="hide"
              />
              <span className="overview-item-name">{record.item.name}</span>
              <span className="muted">
                {record.villageName} · {baseLabel(record.base)} · {levelText(record)} ·{' '}
                {statusLabel(record.item.status)}
                {effectiveText(record)}
                {availabilityText(record)}
              </span>
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}

function levelText(record: UpgradeDisplayRecordDto): string {
  const current = record.item.currentLevel;
  const next = record.item.nextLevel;
  if (current !== null && next !== null) {
    return `${current} → ${next} 级`;
  }
  if (next !== null) {
    return `下一级 ${next} 级`;
  }
  return '等级未知';
}

function effectiveText(record: UpgradeDisplayRecordDto): string {
  const label = effectiveStatusLabel(record.item.effectiveStatus);
  return label === null ? '' : ` · ${label}`;
}

function availabilityText(record: UpgradeDisplayRecordDto): string {
  const label = availabilityLabel(record.item.availability);
  return label === null ? '' : ` · ${label}`;
}
