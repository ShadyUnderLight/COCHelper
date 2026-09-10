import { useEffect, useRef } from 'react';

import type { QuickPreparePreviewWire } from '@coc-helper/contracts';

import type { QuickImportState } from '../use-quick-import';

type QuickImportSheetProps = {
  readonly state: QuickImportState;
  readonly canWrite: boolean;
  readonly onConfirm: () => void;
  readonly onCancel: () => void;
  readonly onRetry: () => void;
  readonly onClose: () => void;
  readonly returnFocusTo?: HTMLElement | null;
};

function tagLabel(tag: string | null): string {
  return tag ?? '无';
}

function previewTargetLine(preview: QuickPreparePreviewWire): string {
  return `目标村庄「${preview.targetVillageName}」（当前 ${tagLabel(preview.targetVillageTag)}）→ JSON ${tagLabel(preview.snapshot.tag ?? null)}`;
}

export function QuickImportSheet({
  state,
  canWrite,
  onConfirm,
  onCancel,
  onRetry,
  onClose,
  returnFocusTo,
}: QuickImportSheetProps) {
  const { status, preview, stale, lastError } = state;
  const busy = status === 'preparing' || status === 'committing';
  const canConfirm = canWrite && status === 'ready' && preview !== null && !stale;
  const dialogRef = useRef<HTMLDivElement | null>(null);

  // 真 modal 语义与 LevelDetailSheet 同模式：overlay 点击关闭、Escape 关闭、
  // Tab 焦点陷阱、关闭后焦点回到打开者。ARIA 声称 modal，就必须有 modal 行为。
  // 打开即把初始焦点移进 dialog（容器可聚焦），避免焦点滞留底层 opener。
  useEffect(() => {
    dialogRef.current?.focus();
  }, []);
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        onClose();
        return;
      }
      if (event.key !== 'Tab') {
        return;
      }
      const dialog = dialogRef.current;
      if (dialog === null) {
        return;
      }
      const focusables = Array.from(
        dialog.querySelectorAll<HTMLElement>(
          'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])',
        ),
      ).filter((el) => (el as { readonly disabled?: boolean }).disabled !== true);
      if (focusables.length === 0) {
        event.preventDefault();
        return;
      }
      const first = focusables[0] as HTMLElement;
      const last = focusables[focusables.length - 1] as HTMLElement;
      const active = document.activeElement as HTMLElement | null;
      if (event.shiftKey) {
        if (active === first || (active !== null && !dialog.contains(active))) {
          event.preventDefault();
          last.focus();
        }
      } else {
        if (active === last || (active !== null && !dialog.contains(active))) {
          event.preventDefault();
          first.focus();
        }
      }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [onClose]);
  useEffect(() => {
    return () => {
      returnFocusTo?.focus();
    };
  }, [returnFocusTo]);

  return (
    <div className="sheet-overlay" onClick={onClose}>
      <div
        ref={dialogRef}
        className="quick-import-sheet"
        role="dialog"
        aria-modal="true"
        aria-label="快捷导入"
        tabIndex={-1}
        onClick={(event) => event.stopPropagation()}
      >
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
    </div>
  );
}
