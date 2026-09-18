import { useMemo, useReducer } from 'react';

import { getDesktopBridge } from './bridge';
import { INITIAL_ROUTE, navigationReducer, type AppRoute, type NavigateAction } from './navigation';
import { useAppSession } from './use-app-session';
import { useQuickImport } from './use-quick-import';
import { useManual } from './use-manual';
import { useUpgradeOverview } from './use-upgrade-overview';
import { useVillageDetail } from './use-village-detail';
import { useDiagnostics } from './use-diagnostics';
import { AppShell } from './components/AppShell';

export function App() {
  const bridge = getDesktopBridge();
  const session = useAppSession(bridge);
  const diagnostics = useDiagnostics(bridge, session.state.snapshot);
  const overview = useUpgradeOverview(bridge, session.state.snapshot);
  const [route, dispatch] = useReducer(navigationReducer, INITIAL_ROUTE);

  const detailTarget = useMemo(
    () =>
      route.kind === 'villageDetail' ? { villageId: route.villageId, base: route.base } : null,
    [route],
  );
  const detail = useVillageDetail(bridge, session.state.snapshot, detailTarget);
  const quick = useQuickImport(bridge, session.state.snapshot, {
    onCommitted: () => {
      void session.refresh();
      void overview.refresh();
      void detail.refresh();
    },
  });
  const manual = useManual(bridge, session.state.snapshot, detailTarget?.villageId ?? null, {
    onMutated: () => {
      void session.refresh();
      void overview.refresh();
      void detail.refresh();
    },
  });

  const navigate = (action: NavigateAction): void => {
    dispatch(action);
  };

  const setRoute = (next: AppRoute): void => {
    navigate({ type: 'navigate', route: next });
  };

  return (
    <AppShell
      session={session}
      overview={overview}
      detail={detail}
      diagnostics={diagnostics}
      tokenBridge={bridge}
      officialBridge={bridge}
      quick={quick}
      manual={manual}
      route={route}
      navigate={navigate}
      onRouteChange={setRoute}
    />
  );
}
