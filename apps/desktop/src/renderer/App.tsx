import { useMemo, useReducer } from 'react';

import { getDesktopBridge } from './bridge';
import { INITIAL_ROUTE, navigationReducer, type AppRoute, type NavigateAction } from './navigation';
import { useAppSession } from './use-app-session';
import { useOfficialVillage } from './use-official-village';
import { useQuickImport } from './use-quick-import';
import { useUpgradeOverview } from './use-upgrade-overview';
import { useVillageDetail } from './use-village-detail';
import { AppShell } from './components/AppShell';

export function App() {
  const bridge = getDesktopBridge();
  const session = useAppSession(bridge);
  const overview = useUpgradeOverview(bridge, session.state.snapshot);
  const [route, dispatch] = useReducer(navigationReducer, INITIAL_ROUTE);

  const detailTarget = useMemo(
    () =>
      route.kind === 'villageDetail' ? { villageId: route.villageId, base: route.base } : null,
    [route],
  );
  const detail = useVillageDetail(bridge, session.state.snapshot, detailTarget);
  const officialVillageId = useMemo(() => {
    if (route.kind === 'villageDetail') {
      return route.villageId;
    }
    if (route.kind === 'import') {
      return session.state.snapshot?.selectedVillageId ?? null;
    }
    return null;
  }, [route, session.state.snapshot?.selectedVillageId]);
  const official = useOfficialVillage(bridge, session.state.snapshot, officialVillageId);
  const quick = useQuickImport(bridge, session.state.snapshot);

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
      official={official}
      quick={quick}
      route={route}
      navigate={navigate}
      onRouteChange={setRoute}
    />
  );
}
