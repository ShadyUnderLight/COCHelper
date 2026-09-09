import type { RecoveryStatusPayload } from '@coc-helper/contracts';

type RecoveryPanelProps = {
  readonly status: RecoveryStatusPayload | null;
  readonly busy: boolean;
  readonly onReset: () => void;
  readonly onRestoreSaved: () => void;
  readonly onRecoverJournal: () => void;
  readonly onRefresh: () => void;
};

export function RecoveryPanel({
  status,
  busy,
  onReset,
  onRestoreSaved,
  onRecoverJournal,
  onRefresh,
}: RecoveryPanelProps) {
  return (
    <section className="recovery-panel" aria-label="数据恢复">
      <h2>数据恢复</h2>
      <p className="muted">当前村庄存储需要显式恢复后才能继续写入。</p>
      {status === null ? (
        <p className="muted">正在读取 recovery.status…</p>
      ) : (
        <>
          <p>
            recoveryRequired: {status.recoveryRequired ? '是' : '否'} · store {status.villageStatus}
          </p>
          {status.villageError !== null ? (
            <p className="error-text" role="alert">
              {status.villageError}
            </p>
          ) : null}
          {status.notice !== null ? <p className="notice-text">{status.notice}</p> : null}
          <div className="action-row">
            <button type="button" disabled={busy} onClick={onRefresh}>
              刷新状态
            </button>
            <button
              type="button"
              disabled={busy || !status.canRestoreSavedCopy}
              onClick={onRestoreSaved}
            >
              恢复已保存副本
            </button>
            <button
              type="button"
              disabled={busy || !status.hasPendingJournal}
              onClick={onRecoverJournal}
            >
              恢复事务 journal
            </button>
            <button type="button" className="danger" disabled={busy} onClick={onReset}>
              重置为空存储
            </button>
          </div>
        </>
      )}
    </section>
  );
}
