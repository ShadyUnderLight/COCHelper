import {
  formatManualRecordSummary,
  isManualCommandEnabled,
  isManualQueryStale,
  manualStatusLabel,
  manualStatusNotice,
  type ManualView,
} from '../manual-session';

export function ManualStatusPanel(props: {
  readonly view: ManualView;
  readonly canWrite: boolean;
  readonly busy: boolean;
  readonly commandError: string | null;
  readonly onRetry: () => void;
  readonly onSettle: () => void;
  readonly onCancelRecord: (recordId: string) => void;
  readonly onAdjustRecord: (recordId: string, startedAtMs: number) => void;
}) {
  const { view, canWrite, busy, commandError } = props;
  if (view.status === 'idle' || view.status === 'loading') {
    return (
      <section className="manual-panel" aria-label="手动升级">
        <p className="muted">正在加载手动升级状态…</p>
      </section>
    );
  }
  if (view.status === 'error' || view.payload === null) {
    return (
      <section className="manual-panel" aria-label="手动升级">
        <p className="error-text" role="alert">
          {view.lastError ?? '手动升级状态加载失败'}
        </p>
        <button type="button" onClick={props.onRetry}>
          重试
        </button>
      </section>
    );
  }

  const payload = view.payload;
  const queryStale = isManualQueryStale(view);
  const notice = manualStatusNotice(payload);
  const writable = isManualCommandEnabled(payload, canWrite, queryStale);

  return (
    <section className="manual-panel" aria-label="手动升级">
      <h3>本地手动升级</h3>
      <p>
        状态：{manualStatusLabel(payload.status)}
        {payload.activeRecordCount > 0 ? ` · 进行中 ${payload.activeRecordCount}` : ''}
      </p>
      {notice !== null ? <p className="notice-text">{notice}</p> : null}
      {view.lastError !== null ? (
        <p className="notice-text" role="alert">
          数据可能过期：{view.lastError}
        </p>
      ) : null}
      {commandError !== null ? (
        <p className="error-text" role="alert">
          {commandError}
        </p>
      ) : null}
      <div className="action-row">
        <button type="button" disabled={busy} onClick={props.onRetry}>
          刷新状态
        </button>
        <button type="button" disabled={!writable || busy} onClick={props.onSettle}>
          结算到期升级
        </button>
      </div>
      {payload.activeRecords.length > 0 ? (
        <ul className="manual-record-list">
          {payload.activeRecords.map((record) => (
            <li key={record.recordId}>
              <span>{formatManualRecordSummary(record)}</span>
              <div className="action-row">
                <button
                  type="button"
                  disabled={!writable || busy}
                  onClick={() => props.onCancelRecord(record.recordId)}
                >
                  取消
                </button>
                <button
                  type="button"
                  disabled={!writable || busy}
                  onClick={() => props.onAdjustRecord(record.recordId, record.startedAtMs)}
                >
                  调整开始时间
                </button>
              </div>
            </li>
          ))}
        </ul>
      ) : null}
      <p className="muted manual-local-note">本地手动升级仅在本应用内记录进度，不会操作游戏。</p>
    </section>
  );
}
