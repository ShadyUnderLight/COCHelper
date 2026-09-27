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
      <p className="status-heading">
        <span className={'online-dot ' + snapshot.availability} aria-hidden="true" />
        <strong>{availabilityLabel(snapshot.availability)}</strong>
        {readOnly ? <span className="status-mode">只读</span> : null}
      </p>
      <p className="status-detail">
        {empty ? '暂无村庄档案' : '本地营地档案'}
        <span className="status-technical">
          {' · '}session {snapshot.sessionId.slice(0, 8)}… · generation {snapshot.generation} ·
          store {snapshot.villageStatus}
        </span>
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
      <div className="village-heading">
        <h2>我的村庄</h2>
        <span className="village-count">{villages.length}</span>
      </div>
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
                  disabled={disabled}
                  aria-pressed={selected}
                  onClick={() => onSelect(village.id)}
                >
                  <span className="village-emblem" aria-hidden="true">
                    <svg viewBox="0 0 24 24" fill="none">
                      <path d="M12 2.5 20 6v5.8c0 4.7-3.1 8-8 9.7-4.9-1.7-8-5-8-9.7V6l8-3.5Z" />
                      <path d="M7.5 14.5h9M9 14.5v-4l3-2.2 3 2.2v4M11 14.5v-2h2v2" />
                    </svg>
                  </span>
                  <span className="village-copy">
                    <span className="village-name">{village.name}</span>
                    <span className="village-meta">
                      {village.tag ?? '无标签'}
                      {village.hasImportedData ? '' : ' · 未导入'}
                    </span>
                  </span>
                  <span className="village-chevron" aria-hidden="true">
                    ›
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
