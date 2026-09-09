import type { PendingImportPreviewWire } from '@coc-helper/contracts';

import type { ImportPreviewState } from '../app-session';

type ImportPanelProps = {
  readonly pasteText: string;
  readonly preview: ImportPreviewState | null;
  readonly canWrite: boolean;
  readonly busy: boolean;
  readonly onPasteTextChange: (text: string) => void;
  readonly onPrepare: () => void;
  readonly onCommit: () => void;
  readonly onDiscard: () => void;
};

function previewTargetLabel(preview: PendingImportPreviewWire): string {
  if (preview.targetKind === 'create') {
    return '将创建新村庄';
  }
  if (preview.targetKind === 'ambiguous') {
    const names = preview.ambiguousVillageNames?.join('、') ?? '多个村庄';
    return `标签 ${preview.ambiguousTag ?? ''} 匹配到多个村庄：${names}`;
  }
  return `将更新村庄「${preview.targetVillageName ?? preview.targetVillageId ?? '未知'}」`;
}

export function ImportPanel({
  pasteText,
  preview,
  canWrite,
  busy,
  onPasteTextChange,
  onPrepare,
  onCommit,
  onDiscard,
}: ImportPanelProps) {
  const canConfirm =
    canWrite &&
    !busy &&
    preview !== null &&
    preview.preview.targetKind !== 'ambiguous';

  return (
    <section className="import-panel" aria-label="账号导入">
      <h2>账号数据</h2>
      <p className="muted">粘贴游戏内复制的账号 JSON，预览后再确认导入。</p>
      <label className="paste-label" htmlFor="account-json">
        账号 JSON
      </label>
      <textarea
        id="account-json"
        className="paste-input"
        rows={10}
        value={pasteText}
        disabled={!canWrite || busy}
        placeholder='{"tag":"#ABC...", ...}'
        onChange={(event) => onPasteTextChange(event.target.value)}
      />
      <div className="action-row">
        <button type="button" disabled={!canWrite || busy || pasteText.trim().length === 0} onClick={onPrepare}>
          解析预览
        </button>
      </div>

      {preview !== null ? (
        <div className="preview-box" role="region" aria-label="导入预览">
          <h3>导入预览</h3>
          <p>{previewTargetLabel(preview.preview)}</p>
          <p className="muted">
            快照标签：{preview.preview.snapshot.tag ?? '无'} · prepare generation{' '}
            {preview.preparedGeneration}
          </p>
          <p className="muted">
            诊断 {preview.preview.snapshot.diagnostics.length} 条 · 未知顶层键{' '}
            {preview.preview.snapshot.unknownTopLevelKeys.length} 个
          </p>
          {preview.preview.snapshot.diagnostics.slice(0, 5).map((item) => (
            <p key={item.id} className="muted">
              [{item.severity}] {item.path}: {item.message}
            </p>
          ))}
          <div className="action-row">
            <button type="button" disabled={!canConfirm} onClick={onCommit}>
              确认导入
            </button>
            <button type="button" disabled={!canWrite || busy} onClick={onDiscard}>
              取消
            </button>
          </div>
        </div>
      ) : null}
    </section>
  );
}
