import { useState } from 'react';

import type { TrackerBaseDto } from '@coc-helper/contracts';

import { getDesktopBridge } from './bridge';
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
  const quick = useQuickImport(bridge, session.state.snapshot, {
    onCommitted: () => {
      // Main 已广播新 generation；显式刷新三视图，Tag 变化后不留旧官方数据。
      void session.refresh();
      void overview.refresh();
      void detail.refresh();
    },
  });
  return (
    <AppShell
      session={session}
      overview={overview}
      detail={detail}
      detailBase={detailBase}
      onDetailBaseChange={setDetailBase}
      quick={quick}
    />
  );
}
