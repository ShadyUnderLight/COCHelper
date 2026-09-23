import { useRef, useState, type ReactNode } from 'react';
import type { AppSnapshotPayload, TrackerBaseDto } from '@coc-helper/contracts';
import type { AppSessionApi } from '../use-app-session';
import type { OverviewApi } from '../use-upgrade-overview';
import type { QuickImportApi } from '../use-quick-import';
import type { ManualApi } from '../use-manual';
import type { VillageDetailApi } from '../use-village-detail';
import type { DiagnosticsApi } from '../use-diagnostics';
import type { BridgeTokenSettingsClient } from '../use-token-settings';
import type { ClanAffiliation, WarLogPublicity } from '../official-session';
import {
  useOfficialClanWarBundle,
  warLogPublicityOf,
  type BridgeOfficialVillageClient,
  type OfficialClanWarBundleApi,
} from '../use-official-clan-war-bundle';
import {
  useOfficialVillage,
  type BridgeOfficialClient,
  type OfficialVillageApi,
} from '../use-official-village';
import { isReadOnly, type ImportPreviewState } from '../app-session';
import {
  primaryTabOfRoute,
  type AppRoute,
  type NavigateAction,
  type PrimaryTab,
} from '../navigation';
import type { VillageDetailState } from '../village-detail-session';
import { ImportPanel } from './ImportPanel';
import { RecoveryPanel } from './RecoveryPanel';
import { StatusBanner, VillageSidebar } from './StatusBanner';
import { UpgradeOverview } from './UpgradeOverview';
import { VillageDetail } from './VillageDetail';
import { DiagnosticsPanel } from './DiagnosticsPanel';
import { TokenSettingsPanel } from './TokenSettingsPanel';

type AppShellProps = {
  readonly session: AppSessionApi;
  readonly overview: OverviewApi;
  readonly detail: VillageDetailApi;
  readonly diagnostics?: DiagnosticsApi;
  readonly tokenBridge?: BridgeTokenSettingsClient;
  readonly official?: OfficialVillageApi;
  readonly officialBridge?: BridgeOfficialVillageClient;
  /** 快捷导入（#277-D）：缺省时详情页不渲染入口，保持旧测试兼容。 */
  readonly quick?: QuickImportApi;
  /** 手动升级（#277-F）：缺省时详情页不渲染面板。 */
  readonly manual?: ManualApi;
  readonly route?: AppRoute;
  readonly navigate?: (action: NavigateAction) => void;
  /** 测试与旧调用方兼容：直接设置路由。 */
  readonly onRouteChange?: (route: AppRoute) => void;
};

export function AppShell({
  session,
  overview,
  detail,
  diagnostics,
  tokenBridge,
  official,
  officialBridge,
  quick,
  manual,
  route,
  navigate,
  onRouteChange,
}: AppShellProps) {
  const [internalRoute, setInternalRoute] = useState<AppRoute>({ kind: 'import' });
  const activeRoute = route ?? internalRoute;
  const activeRouteRef = useRef(activeRoute);
  activeRouteRef.current = activeRoute;
  const { state, recoveryStatus } = session;
  const snapshot = state.snapshot;
  const tab = primaryTabOfRoute(activeRoute);
  const detailRoute = activeRoute.kind === 'villageDetail' ? activeRoute : null;

  const applyRoute = (nextRoute: AppRoute): void => {
    if (navigate !== undefined) {
      navigate({ type: 'navigate', route: nextRoute });
    } else if (onRouteChange !== undefined) {
      onRouteChange(nextRoute);
    } else if (route === undefined) {
      setInternalRoute(nextRoute);
    }
  };

  const detailBaseForTab = (): TrackerBaseDto => detailRoute?.base ?? 'home';

  const goToTab = (nextTab: PrimaryTab): void => {
    const nextRoute: AppRoute =
      nextTab === 'import'
        ? { kind: 'import' }
        : nextTab === 'overview'
          ? { kind: 'overview' }
          : nextTab === 'info'
            ? { kind: 'info', section: 'diagnostics' }
            : snapshot === null || snapshot.selectedVillageId === null
              ? activeRoute
              : {
                  kind: 'villageDetail',
                  villageId: snapshot.selectedVillageId,
                  base: detailBaseForTab(),
                };
    applyRoute(nextRoute);
  };

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
  const canQuick = snapshot.canWrite && snapshot.availability === 'available' && !state.busy;
  const canManual = snapshot.canWrite && snapshot.availability === 'available' && !state.busy;
  const openDetail = async (recordId: string, villageId: string) => {
    overview.select(recordId);
    if (villageId !== snapshot.selectedVillageId && !(await session.selectVillage(villageId))) {
      return;
    }
    const currentRoute = activeRouteRef.current;
    if (currentRoute.kind === 'overview') {
      if (navigate !== undefined) {
        navigate({ type: 'openVillageDetail', villageId, base: 'home' });
      } else {
        applyRoute({ kind: 'villageDetail', villageId, base: 'home' });
      }
      return;
    }
    if (currentRoute.kind === 'villageDetail') {
      applyRoute({ kind: 'villageDetail', villageId, base: currentRoute.base });
    }
  };

  const onDetailBaseChange = (base: TrackerBaseDto): void => {
    if (detailRoute === null) {
      return;
    }
    applyRoute({ kind: 'villageDetail', villageId: detailRoute.villageId, base });
  };

  const onSidebarSelect = async (villageId: string): Promise<void> => {
    const ok = await session.selectVillage(villageId);
    if (!ok) {
      return;
    }
    const currentRoute = activeRouteRef.current;
    if (currentRoute.kind === 'villageDetail') {
      applyRoute({ kind: 'villageDetail', villageId, base: currentRoute.base });
    }
  };

  const refreshCurrentPage = (): void => {
    void session.refresh();
    if (tab === 'overview') {
      void overview.refresh();
    } else if (tab === 'detail') {
      void detail.refresh();
    } else if (tab === 'info') {
      void diagnostics?.refresh();
    }
  };

  return (
    <div
      className="app-shell"
      data-smoke="ready"
      data-availability={snapshot.availability}
      data-can-write={snapshot.canWrite ? 'true' : 'false'}
    >
      <p id="status" className="sr-only">
        Electron 宿主已就绪
      </p>
      <div className="app-frame">
        <aside className="glass-sidebar" aria-label="营地导航">
          <div className="brand-lockup">
            <span className="brand-crest" aria-hidden="true">
              <svg viewBox="0 0 40 40" fill="none">
                <path d="M20 3.5 34 9v10.2c0 8.6-5.7 14.6-14 18.1C11.7 33.8 6 27.8 6 19.2V9l14-5.5Z" />
                <path d="M11 24h18M14 24v-8l6-4 6 4v8M18 24v-4h4v4M10 29h20" />
              </svg>
            </span>
            <span className="brand-copy">
              <span>CLAN CAMP</span>
              <strong>COC 助手</strong>
            </span>
          </div>

          <TabNav
            tab={tab}
            onChange={goToTab}
            detailDisabled={detailDisabled}
            showDataTabs={showImport}
          />

          <VillageSidebar
            villages={snapshot.villages}
            selectedVillageId={snapshot.selectedVillageId}
            disabled={state.busy || snapshot.availability !== 'available'}
            onSelect={(villageId) => void onSidebarSelect(villageId)}
          />

          <StatusBanner snapshot={snapshot} />
        </aside>

        <main className="workspace">
          <header className="toolbar">
            <div className="page-context">
              <p className="eyebrow">
                CLAN CAMP <span>/</span> LOCAL ARCHIVE
              </p>
              <h1>{pageTitle(activeRoute)}</h1>
            </div>
            <div className="toolbar-actions">
              <button
                type="button"
                className="glass-action"
                disabled={state.busy}
                onClick={refreshCurrentPage}
              >
                <span aria-hidden="true">↻</span>
                刷新数据
              </button>
              <button
                type="button"
                className="primary-action"
                disabled={!showImport}
                onClick={() => goToTab('import')}
              >
                <span aria-hidden="true">＋</span>
                导入 JSON
              </button>
            </div>
          </header>

          <div className="page-scroll">
            {state.lastError !== null ? (
              <p className="error-text shell-alert" role="alert">
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
            ) : null}

            {showRecovery && tab !== 'info' ? null : (
              <div className="main-pane">
                {snapshot.availability === 'unavailable' ? (
                  <p className="error-text" role="alert">
                    应用当前不可用。{snapshot.villageError ?? ''}
                  </p>
                ) : null}
                {readOnly && snapshot.availability === 'available' ? (
                  <p className="notice-text" role="status">
                    当前为只读模式，无法导入或修改村庄数据。
                  </p>
                ) : null}
                {tab === 'info' ? (
                  <InfoPanel
                    route={activeRoute}
                    diagnostics={diagnostics}
                    tokenBridge={tokenBridge}
                    onTokenChanged={() => void diagnostics?.refresh()}
                    onNavigate={(section) => applyRoute({ kind: 'info', section })}
                  />
                ) : null}
                {showImport && tab === 'import' ? (
                  <OfficialImportPanel
                    pasteText={state.pasteText}
                    preview={state.preview}
                    canWrite={snapshot.canWrite && snapshot.availability === 'available'}
                    busy={state.busy}
                    onPasteTextChange={session.setPasteText}
                    onPrepare={() => void session.prepareImport()}
                    onCommit={() => void session.commitImport()}
                    onDiscard={() => void session.discardImport()}
                    official={official}
                    officialBridge={officialBridge}
                    snapshot={snapshot}
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
                  detailRoute === null ? (
                    <p className="muted">先选择村庄查看详情</p>
                  ) : (
                    <OfficialVillageDetail
                      state={detail.state}
                      base={detailRoute.base}
                      onBaseChange={onDetailBaseChange}
                      onRetry={() => void detail.refresh()}
                      official={official}
                      officialBridge={officialBridge}
                      snapshot={snapshot}
                      villageId={detailRoute.villageId}
                      quick={quick}
                      canQuick={canQuick}
                      canManual={canManual}
                      manual={manual}
                      onNavigateToImport={() => goToTab('import')}
                    />
                  )
                ) : null}
              </div>
            )}
          </div>
        </main>
      </div>
    </div>
  );
}

function pageTitle(route: AppRoute): string {
  switch (route.kind) {
    case 'import':
      return '账号与数据';
    case 'overview':
    case 'official':
    case 'manual':
      return '营地总览';
    case 'villageDetail':
      return '村庄档案';
    case 'info':
      return '设置与诊断';
    default: {
      const exhaustive: never = route;
      throw new Error('未知路由：' + String(exhaustive));
    }
  }
}

function OfficialVillageHost(props: {
  readonly bridge: BridgeOfficialClient;
  readonly snapshot: AppSnapshotPayload | null;
  readonly villageId: string | null;
  readonly children: (official: OfficialVillageApi) => ReactNode;
}) {
  const official = useOfficialVillage(props.bridge, props.snapshot, props.villageId);
  return props.children(official);
}

function OfficialImportPanel(props: {
  readonly pasteText: string;
  readonly preview: ImportPreviewState | null;
  readonly canWrite: boolean;
  readonly busy: boolean;
  readonly onPasteTextChange: (text: string) => void;
  readonly onPrepare: () => void;
  readonly onCommit: () => void;
  readonly onDiscard: () => void;
  readonly official?: OfficialVillageApi;
  readonly officialBridge?: BridgeOfficialClient;
  readonly snapshot: AppSnapshotPayload;
}) {
  const villageId = props.snapshot.selectedVillageId;
  const panel = (official: OfficialVillageApi | undefined) => (
    <ImportPanel
      pasteText={props.pasteText}
      preview={props.preview}
      canWrite={props.canWrite}
      busy={props.busy}
      onPasteTextChange={props.onPasteTextChange}
      onPrepare={props.onPrepare}
      onCommit={props.onCommit}
      onDiscard={props.onDiscard}
      official={official}
    />
  );
  if (props.officialBridge === undefined || villageId === null) {
    return panel(villageId === null ? undefined : props.official);
  }
  return (
    <OfficialVillageHost
      bridge={props.officialBridge}
      snapshot={props.snapshot}
      villageId={villageId}
    >
      {panel}
    </OfficialVillageHost>
  );
}

function OfficialVillageDetail(props: {
  readonly state: VillageDetailState;
  readonly base: TrackerBaseDto;
  readonly onBaseChange: (base: TrackerBaseDto) => void;
  readonly onRetry: () => void;
  readonly official?: OfficialVillageApi;
  readonly officialBridge?: BridgeOfficialVillageClient;
  readonly snapshot: AppSnapshotPayload;
  readonly villageId: string;
  readonly quick?: QuickImportApi;
  readonly canQuick: boolean;
  readonly canManual: boolean;
  readonly manual?: ManualApi;
  readonly onNavigateToImport: () => void;
}) {
  const detail = (
    official: OfficialVillageApi | undefined,
    officialWar: OfficialClanWarBundleApi | undefined,
  ) => (
    <VillageDetail
      state={props.state}
      base={props.base}
      onBaseChange={props.onBaseChange}
      onRetry={props.onRetry}
      official={official}
      officialWar={officialWar}
      quick={props.quick}
      canQuick={props.canQuick}
      canManual={props.canManual}
      manual={props.manual}
      onNavigateToImport={props.onNavigateToImport}
    />
  );
  if (props.officialBridge === undefined) {
    return detail(props.official, undefined);
  }
  const bridge = props.officialBridge;
  return (
    <OfficialVillageHost bridge={bridge} snapshot={props.snapshot} villageId={props.villageId}>
      {(official) => (
        <OfficialClanWarHost
          bridge={bridge}
          snapshot={props.snapshot}
          affiliation={official.clan.affiliation}
          clanTag={official.clan.clanTag}
          villageId={props.villageId}
          warLogPublicity={warLogPublicityOf(official.clan)}
        >
          {(officialWar) => detail(official, officialWar)}
        </OfficialClanWarHost>
      )}
    </OfficialVillageHost>
  );
}

function OfficialClanWarHost(props: {
  readonly bridge: BridgeOfficialVillageClient;
  readonly snapshot: AppSnapshotPayload | null;
  readonly affiliation: ClanAffiliation;
  readonly clanTag: string | null;
  readonly villageId: string | null;
  readonly warLogPublicity: WarLogPublicity;
  readonly children: (officialWar: OfficialClanWarBundleApi) => ReactNode;
}) {
  const officialWar = useOfficialClanWarBundle(
    props.bridge,
    props.snapshot,
    props.affiliation,
    props.clanTag,
    props.villageId,
    props.warLogPublicity,
  );
  return props.children(officialWar);
}

function InfoPanel(props: {
  readonly route: AppRoute;
  readonly diagnostics?: DiagnosticsApi;
  readonly tokenBridge?: BridgeTokenSettingsClient;
  readonly onTokenChanged: () => void;
  readonly onNavigate: (section: 'diagnostics' | 'tokenSettings') => void;
}) {
  const section = props.route.kind === 'info' ? props.route.section : 'diagnostics';
  return (
    <div className="info-content">
      <nav className="info-nav" aria-label="Info 页面">
        <button
          type="button"
          aria-pressed={section === 'diagnostics'}
          onClick={() => props.onNavigate('diagnostics')}
        >
          Diagnostics
        </button>
        <button
          type="button"
          aria-pressed={section === 'tokenSettings'}
          onClick={() => props.onNavigate('tokenSettings')}
        >
          Token Settings
        </button>
      </nav>
      {section === 'diagnostics' ? (
        props.diagnostics === undefined ? (
          <section className="info-panel" aria-label="诊断">
            <h2>Diagnostics</h2>
            <p className="error-text" role="alert">
              诊断服务不可用。
            </p>
          </section>
        ) : (
          <DiagnosticsPanel
            state={props.diagnostics.state}
            onRetry={() => void props.diagnostics?.refresh()}
          />
        )
      ) : props.tokenBridge === undefined ? (
        <section className="info-panel" aria-label="Token 设置">
          <h2>Token Settings</h2>
          <p className="error-text" role="alert">
            Token 安全存储不可用。
          </p>
        </section>
      ) : (
        <TokenSettingsPanel bridge={props.tokenBridge} onTokenChanged={props.onTokenChanged} />
      )}
    </div>
  );
}

function TabNav(props: {
  readonly tab: PrimaryTab;
  readonly onChange: (tab: PrimaryTab) => void;
  readonly detailDisabled: boolean;
  readonly showDataTabs: boolean;
}) {
  return (
    <nav className="tab-row" aria-label="功能切换">
      {props.showDataTabs ? (
        <>
          <button
            className="nav-item"
            type="button"
            aria-pressed={props.tab === 'overview'}
            onClick={() => props.onChange('overview')}
          >
            <span className="nav-icon" aria-hidden="true">
              <svg viewBox="0 0 24 24" fill="none">
                <path d="M3 19.5h18M5.5 16V10M10 16V5M14.5 16v-3M4 7l5-3 5 2 5-3" />
              </svg>
            </span>
            <span>升级总览</span>
          </button>
          <button
            className="nav-item"
            type="button"
            aria-pressed={props.tab === 'import'}
            onClick={() => props.onChange('import')}
          >
            <span className="nav-icon" aria-hidden="true">
              <svg viewBox="0 0 24 24" fill="none">
                <path d="M12 3.5v11M7.5 10l4.5 4.5 4.5-4.5M4.5 16.5v3h15v-3" />
              </svg>
            </span>
            <span>导入</span>
          </button>
          <button
            className="nav-item"
            type="button"
            aria-pressed={props.tab === 'detail'}
            disabled={props.detailDisabled}
            title={props.detailDisabled ? '先选择村庄' : undefined}
            onClick={() => props.onChange('detail')}
          >
            <span className="nav-icon" aria-hidden="true">
              <svg viewBox="0 0 24 24" fill="none">
                <path d="M3.5 20V9.5l4-2.5 4 2.5V20M11.5 20V5.5l4-2 5 2.5V20M2.5 20h19" />
                <path d="M6 12h3M15 9h3M15 13h3" />
              </svg>
            </span>
            <span>村庄详情</span>
          </button>
        </>
      ) : null}
      <button
        className="nav-item"
        type="button"
        aria-pressed={props.tab === 'info'}
        onClick={() => props.onChange('info')}
      >
        <span className="nav-icon" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none">
            <circle cx="12" cy="12" r="8.5" />
            <path d="M12 10.5v5M12 7.5h.01" />
          </svg>
        </span>
        <span>Info</span>
      </button>
    </nav>
  );
}
