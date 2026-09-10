import type { QuickImportPreviewWire } from '@coc-helper/contracts';

import type { QuickImportState } from '../use-quick-import';

type QuickImportSheetProps = {
  readonly state: QuickImportState;
  readonly canWrite: boolean;
  readonly onConfirm: () => void;
  readonly onCancel: () => void;
  readonly onRetry: () => void;
  readonly onClose: () => void;
};

function tagLabel(tag: string | null): string {
  return tag ?? '无';
}

function previewTargetLine(preview: QuickImportPreviewWire): string {
  return `目标村庄「${preview.targetVillageName}」（当前 ${tagLabel(preview.targetVillageTag)}）→ JSON ${tagLabel(preview.snapshot.tag ?? null)}`;
}

export function QuickImportSheet({
  state,
  canWrite,
  onConfirm,
  onCancel,
  onRetry,
  onClose,
}: QuickImportSheetProps) {
  const { status, preview, lastError } = state;
  const busy = status === 'preparing' || status === 'committing';
  const stale = status === 'ready' && lastError !== null;
  const canConfirm = canWrite && status === 'ready' && preview !== null && !stale;

  return (
    <div className="quick-import-sheet" role="dialog" aria-modal="true" aria-label="快捷导入">
      <h3>粘贴并更新</h3>
      {status === 'preparing' ? <p className="muted">正在读取剪贴板并预览…</p> : null}
      {status === 'committing' ? <p className="muted">正在写入…</p> : null}
      {preview !== null ? (
        <div className="preview-box" role="region" aria-label="快捷导入预览">
          <p>{previewTargetLine(preview)}</p>
          <p className="muted">{preview.destinationDescription}</p>
          <p className="muted">
            诊断 {preview.snapshot.diagnostics.length} 条 · 未知顶层键{' '}
            {preview.snapshot.unknownTopLevelKeys.length} 个
          </p>
          {preview.snapshot.diagnostics.slice(0, 5).map((item) => (
            <p key={item.id} className="muted">
              [{item.severity}] {item.path}: {item.message}
            </p>
          ))}
        </div>
      ) : null}
      {lastError !== null ? (
        <p className="error-text" role="alert">
          {lastError}
        </p>
      ) : null}
      <div className="action-row">
        {status === 'ready' && preview !== null ? (
          <button type="button" disabled={!canConfirm} onClick={onConfirm}>
            确认导入
          </button>
        ) : null}
        {status === 'idle' && lastError !== null ? (
          <button type="button" disabled={busy} onClick={onRetry}>
            重试
          </button>
        ) : null}
        {stale ? (
          <button type="button" disabled={busy} onClick={onRetry}>
            重新预览
          </button>
        ) : null}
        <button type="button" disabled={busy} onClick={status === 'ready' ? onCancel : onClose}>
          {status === 'ready' ? '取消' : '关闭'}
        </button>
      </div>
    </div>
  );
}
