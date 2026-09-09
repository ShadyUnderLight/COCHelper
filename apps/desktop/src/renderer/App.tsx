import { useState } from 'react';

import type { TrackerBaseDto } from '@coc-helper/contracts';

import { getDesktopBridge } from './bridge';
import { useAppSession } from './use-app-session';
import { useUpgradeOverview } from './use-upgrade-overview';
import { useVillageDetail } from './use-village-detail';
import { AppShell } from './components/AppShell';

export function App() {
  const bridge = getDesktopBridge();
  const session = useAppSession(bridge);
  const overview = useUpgradeOverview(bridge, session.state.snapshot);
  const [detailBase, setDetailBase] = useState<TrackerBaseDto>('home');
  const detail = useVillageDetail(bridge, session.state.snapshot, detailBase);
  return (
    <AppShell
      session={session}
      overview={overview}
      detail={detail}
      detailBase={detailBase}
      onDetailBaseChange={setDetailBase}
    />
  );
}
