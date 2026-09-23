import type { PendingImportPreviewWire } from '@coc-helper/contracts';

import type { ImportPreviewState } from '../app-session';
import type { OfficialVillageApi } from '../use-official-village';
import { ClanCard } from './ClanCard';
import { OfficialPlayerCard } from './OfficialPlayerCard';

type ImportPanelProps = {
  readonly pasteText: string;
  readonly preview: ImportPreviewState | null;
  readonly canWrite: boolean;
  readonly busy: boolean;
  readonly onPasteTextChange: (text: string) => void;
  readonly onPrepare: () => void;
  readonly onCommit: () => void;
  readonly onDiscard: () => void;
  readonly official?: OfficialVillageApi;
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
  official,
}: ImportPanelProps) {
  const canConfirm =
    canWrite && !busy && preview !== null && preview.preview.targetKind !== 'ambiguous';

  return (
    <section className="import-panel" aria-label="账号导入">
      <header className="import-intro">
        <p className="section-eyebrow">
          ACCOUNT ARCHIVE <span>/</span> IMPORT
        </p>
        <h2>同步你的营地档案</h2>
        <p className="muted">粘贴游戏内复制的账号 JSON，先检查预览，再确认写入档案。</p>
      </header>

      <div className="import-layout">
        <div className="import-workflow">
          <div className="import-editor">
            <div className="import-editor-heading">
              <label className="paste-label" htmlFor="account-json">
                账号 JSON
              </label>
              <span className="editor-format">JSON</span>
            </div>
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
              <button
                type="button"
                className="primary-action"
                disabled={!canWrite || busy || pasteText.trim().length === 0}
                onClick={onPrepare}
              >
                解析并预览
              </button>
              <span className="editor-hint">确认前不会应用本次导入</span>
            </div>
          </div>

          {preview !== null ? (
            <div className="preview-box" role="region" aria-label="导入预览">
              <div className="preview-heading">
                <div>
                  <span className="section-eyebrow">REVIEW BEFORE IMPORT</span>
                  <h3>导入预览</h3>
                </div>
                <span className="preview-stamp">待确认</span>
              </div>
              <p className="preview-target">{previewTargetLabel(preview.preview)}</p>
              <div className="preview-facts">
                <p>
                  <span>快照标签</span>
                  <strong>{preview.preview.snapshot.tag ?? '无'}</strong>
                </p>
                <p>
                  <span>诊断记录</span>
                  <strong>{preview.preview.snapshot.diagnostics.length} 条</strong>
                </p>
                <p>
                  <span>未知顶层键</span>
                  <strong>{preview.preview.snapshot.unknownTopLevelKeys.length} 个</strong>
                </p>
                <p>
                  <span>预览代次</span>
                  <strong>{preview.preparedGeneration}</strong>
                </p>
              </div>
              {preview.preview.snapshot.diagnostics.slice(0, 5).map((item) => (
                <p key={item.id} className="preview-diagnostic">
                  [{item.severity}] {item.path}: {item.message}
                </p>
              ))}
              <div className="action-row">
                <button
                  type="button"
                  className="primary-action"
                  disabled={!canConfirm}
                  onClick={onCommit}
                >
                  确认导入
                </button>
                <button
                  type="button"
                  className="quiet-action"
                  disabled={!canWrite || busy}
                  onClick={onDiscard}
                >
                  取消
                </button>
              </div>
            </div>
          ) : null}
        </div>

        <aside className="import-guide">
          <span className="guide-emblem" aria-hidden="true">
            <svg viewBox="0 0 32 32" fill="none">
              <path d="M16 4v15M10 13l6 6 6-6M6 21v6h20v-6" />
              <path d="M7 8h4M21 8h4" />
            </svg>
          </span>
          <p className="section-eyebrow">THREE STEPS</p>
          <h3>导入流程</h3>
          <ol className="guide-steps">
            <li>
              <span>01</span>
              <p>在游戏中复制账号数据。</p>
            </li>
            <li>
              <span>02</span>
              <p>粘贴 JSON 并检查解析预览。</p>
            </li>
            <li>
              <span>03</span>
              <p>确认后更新对应的村庄档案。</p>
            </li>
          </ol>
          <p className="guide-note">如果标签匹配到多个村庄，预览会标出冲突，确认操作会保持禁用。</p>
        </aside>
      </div>

      {official !== undefined ? (
        <div className="import-official">
          <div className="subsection-heading">
            <span className="section-eyebrow">OFFICIAL PROFILE</span>
            <h3>官方资料</h3>
          </div>
          <OfficialPlayerCard
            view={official.player}
            refreshing={official.playerRefreshing}
            onRefresh={() => void official.refreshPlayer()}
          />
          <ClanCard
            view={official.clan}
            refreshing={official.clanRefreshing}
            onRefresh={() => void official.refreshClan()}
          />
        </div>
      ) : null}
    </section>
  );
}
