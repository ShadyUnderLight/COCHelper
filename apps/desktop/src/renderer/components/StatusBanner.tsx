import type { AppAvailability, AppSnapshotPayload, VillageSummaryDto } from '@coc-helper/contracts';

import { isEmptyVillages, isReadOnly } from '../app-session';

type StatusBannerProps = {
  readonly snapshot: AppSnapshotPayload;
};

function availabilityLabel(availability: AppAvailability): string {
  switch (availability) {
    case 'loading':
      return '加载中';
    case 'available':
      return '可用';
    case 'recovery':
      return '需要恢复';
    case 'unavailable':
      return '不可用';
  }
}

export function StatusBanner({ snapshot }: StatusBannerProps) {
  const empty = isEmptyVillages(snapshot);
  const readOnly = isReadOnly(snapshot);
  return (
    <section className="status-banner" aria-live="polite">
      <p>
        状态：{availabilityLabel(snapshot.availability)}
        {empty ? ' · 暂无村庄' : ''}
        {readOnly ? ' · 只读' : ''}
      </p>
      <p className="muted">
        session {snapshot.sessionId.slice(0, 8)}… · generation {snapshot.generation} · store{' '}
        {snapshot.villageStatus}
      </p>
      {snapshot.villageError !== null ? (
        <p className="error-text" role="alert">
          {snapshot.villageError}
        </p>
      ) : null}
      {snapshot.recoveryNotice !== null ? (
        <p className="notice-text">{snapshot.recoveryNotice}</p>
      ) : null}
    </section>
  );
}

type VillageSidebarProps = {
  readonly villages: readonly VillageSummaryDto[];
  readonly selectedVillageId: string | null;
  readonly disabled: boolean;
  readonly onSelect: (villageId: string) => void;
};

export function VillageSidebar({
  villages,
  selectedVillageId,
  disabled,
  onSelect,
}: VillageSidebarProps) {
  return (
    <aside className="sidebar" aria-label="村庄列表">
      <h2>村庄</h2>
      {villages.length === 0 ? (
        <p className="muted">还没有村庄。粘贴账号 JSON 导入第一个档案。</p>
      ) : (
        <ul className="village-list">
          {villages.map((village) => {
            const selected = village.id === selectedVillageId;
            return (
              <li key={village.id}>
                <button
                  type="button"
                  className={selected ? 'village-item selected' : 'village-item'}
                  disabled={disabled || selected}
                  aria-current={selected ? 'page' : undefined}
                  onClick={() => onSelect(village.id)}
                >
                  <span className="village-name">{village.name}</span>
                  <span className="muted">
                    {village.tag ?? '无标签'}
                    {village.hasImportedData ? '' : ' · 未导入'}
                  </span>
                </button>
              </li>
            );
          })}
        </ul>
      )}
    </aside>
  );
}
