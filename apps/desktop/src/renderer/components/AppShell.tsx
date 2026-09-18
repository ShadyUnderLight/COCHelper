import { useRef, useState, type ReactNode } from 'react';
import type { AppSnapshotPayload, TrackerBaseDto } from '@coc-helper/contracts';
import type { AppSessionApi } from '../use-app-session';
import type { OverviewApi } from '../use-upgrade-overview';
import type { QuickImportApi } from '../use-quick-import';
import type { ManualApi } from '../use-manual';
import type { VillageDetailApi } from '../use-village-detail';
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

type AppShellProps = {
  readonly session: AppSessionApi;
  readonly overview: OverviewApi;
  readonly detail: VillageDetailApi;
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
            onSelect={(villageId) => void onSidebarSelect(villageId)}
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
              <TabNav tab={tab} onChange={goToTab} detailDisabled={detailDisabled} />
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
          </main>
        </div>
      )}
    </div>
  );
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

function TabNav(props: {
  readonly tab: PrimaryTab;
  readonly onChange: (tab: PrimaryTab) => void;
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
