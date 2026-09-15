import { useReducer, useState } from 'react';

import type { TrackerBaseDto } from '@coc-helper/contracts';

import { getDesktopBridge } from './bridge';
import {
  INITIAL_ROUTE,
  navigationReducer,
  type AppRoute,
  type NavigateAction,
} from './navigation';
import { useAppSession } from './use-app-session';
import { useQuickImport } from './use-quick-import';
import { useUpgradeOverview } from './use-upgrade-overview';
import { useVillageDetail } from './use-village-detail';
import { AppShell } from './components/AppShell';

export function App() {
  const bridge = getDesktopBridge();
  const session = useAppSession(bridge);
  const overview = useUpgradeOverview(bridge, session.state.snapshot);
  const [detailBase, setDetailBase] = useState<TrackerBaseDto>('home');
  const detail = useVillageDetail(bridge, session.state.snapshot, detailBase);
  const quick = useQuickImport(bridge, session.state.snapshot);
  const [route, dispatch] = useReducer(navigationReducer, INITIAL_ROUTE);

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
      detailBase={detailBase}
      onDetailBaseChange={setDetailBase}
      quick={quick}
      route={route}
      navigate={navigate}
      onRouteChange={setRoute}
    />
  );
}
