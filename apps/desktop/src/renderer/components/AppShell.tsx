import { useState } from 'react';
import type { TrackerBaseDto } from '@coc-helper/contracts';
import type { AppSessionApi } from '../use-app-session';
import type { OverviewApi } from '../use-upgrade-overview';
import type { VillageDetailApi } from '../use-village-detail';
import { isReadOnly } from '../app-session';
import { ImportPanel } from './ImportPanel';
import { RecoveryPanel } from './RecoveryPanel';
import { StatusBanner, VillageSidebar } from './StatusBanner';
import { UpgradeOverview } from './UpgradeOverview';
import { VillageDetail } from './VillageDetail';

type AppShellProps = {
  readonly session: AppSessionApi;
  readonly overview: OverviewApi;
  readonly detail: VillageDetailApi;
  readonly detailBase: TrackerBaseDto;
  readonly onDetailBaseChange: (base: TrackerBaseDto) => void;
};

export function AppShell({
  session,
  overview,
  detail,
  detailBase,
  onDetailBaseChange,
}: AppShellProps) {
  const [tab, setTab] = useState<'import' | 'overview' | 'detail'>('import');
  const { state, recoveryStatus } = session;
  const snapshot = state.snapshot;

  if (state.status === 'fatal') {
    return (
      <div className="app-shell" data-smoke="fatal">
        <header className="app-header">
          <h1>COC 助手</h1>
        </header>
        <p id="status" className="error-text" role="alert">
          {state.lastError ?? '应用启动失败'}
        </p>
        <button type="button" onClick={() => void session.refresh()}>
          重试
        </button>
      </div>
    );
  }

  if (state.status === 'booting' || snapshot === null) {
    return (
      <div className="app-shell" data-smoke="loading">
        <header className="app-header">
          <h1>COC 助手</h1>
        </header>
        <p id="status">正在加载应用快照…</p>
        {state.lastError !== null ? (
          <p className="error-text" role="alert">
            {state.lastError}
          </p>
        ) : null}
      </div>
    );
  }

  const readOnly = isReadOnly(snapshot);
  const showRecovery = snapshot.availability === 'recovery';
  const showImport = snapshot.availability === 'available' || snapshot.availability === 'loading';
  const detailDisabled = snapshot.selectedVillageId === null;
  const openDetail = async (recordId: string, villageId: string) => {
    overview.select(recordId);
    if (villageId !== snapshot.selectedVillageId && !(await session.selectVillage(villageId))) {
      return;
    }
    setTab('detail');
  };

  return (
    <div
      className="app-shell"
      data-smoke="ready"
      data-availability={snapshot.availability}
      data-can-write={snapshot.canWrite ? 'true' : 'false'}
    >
      <header className="app-header">
        <h1>COC 助手</h1>
        <p id="status" className="sr-only">
          Electron 宿主已就绪
        </p>
      </header>

      <StatusBanner snapshot={snapshot} />

      {state.lastError !== null ? (
        <p className="error-text" role="alert">
          {state.lastError}
        </p>
      ) : null}

      {showRecovery ? (
        <RecoveryPanel
          status={recoveryStatus}
          busy={state.busy}
          onReset={() => void session.recoveryReset()}
          onRestoreSaved={() => void session.recoveryRestoreSaved()}
          onRecoverJournal={() => void session.recoveryRecoverJournal()}
          onRefresh={() => void session.refreshRecovery()}
        />
      ) : (
        <div className="layout">
          <VillageSidebar
            villages={snapshot.villages}
            selectedVillageId={snapshot.selectedVillageId}
            disabled={state.busy || snapshot.availability !== 'available'}
            onSelect={(villageId) => void session.selectVillage(villageId)}
          />
          <main className="main-pane">
            {snapshot.availability === 'unavailable' ? (
              <p className="error-text" role="alert">
                应用当前不可用。{snapshot.villageError ?? ''}
              </p>
            ) : null}
            {readOnly && snapshot.availability === 'available' ? (
              <p className="notice-text">当前为只读模式，无法导入或修改村庄数据。</p>
            ) : null}
            {showImport ? (
              <TabNav tab={tab} onChange={setTab} detailDisabled={detailDisabled} />
            ) : null}
            {showImport && tab === 'import' ? (
              <ImportPanel
                pasteText={state.pasteText}
                preview={state.preview}
                canWrite={snapshot.canWrite && snapshot.availability === 'available'}
                busy={state.busy}
                onPasteTextChange={session.setPasteText}
                onPrepare={() => void session.prepareImport()}
                onCommit={() => void session.commitImport()}
                onDiscard={() => void session.discardImport()}
              />
            ) : null}
            {showImport && tab === 'overview' ? (
              <UpgradeOverview
                state={overview.state}
                selectedId={overview.selectedId}
                onSelect={overview.select}
                onOpenDetail={openDetail}
                onRetry={() => void overview.refresh()}
              />
            ) : null}
            {showImport && tab === 'detail' ? (
              detailDisabled ? (
                <p className="muted">先选择村庄查看详情</p>
              ) : (
                <VillageDetail
                  state={detail.state}
                  base={detailBase}
                  onBaseChange={onDetailBaseChange}
                  onRetry={() => void detail.refresh()}
                />
              )
            ) : null}
          </main>
        </div>
      )}
    </div>
  );
}

function TabNav(props: {
  readonly tab: 'import' | 'overview' | 'detail';
  readonly onChange: (tab: 'import' | 'overview' | 'detail') => void;
  readonly detailDisabled: boolean;
}) {
  return (
    <nav className="tab-row" aria-label="功能切换">
      <button
        type="button"
        aria-pressed={props.tab === 'import'}
        onClick={() => props.onChange('import')}
      >
        导入
      </button>
      <button
        type="button"
        aria-pressed={props.tab === 'overview'}
        onClick={() => props.onChange('overview')}
      >
        升级总览
      </button>
      <button
        type="button"
        aria-pressed={props.tab === 'detail'}
        disabled={props.detailDisabled}
        title={props.detailDisabled ? '先选择村庄' : undefined}
        onClick={() => props.onChange('detail')}
      >
        村庄详情
      </button>
    </nav>
  );
}
