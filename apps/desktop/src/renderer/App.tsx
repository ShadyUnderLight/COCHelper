import { getDesktopBridge } from './bridge';
import { useAppSession } from './use-app-session';
import { useUpgradeOverview } from './use-upgrade-overview';
import { AppShell } from './components/AppShell';

export function App() {
  const bridge = getDesktopBridge();
  const session = useAppSession(bridge);
  const overview = useUpgradeOverview(bridge, session.state.snapshot);
  return <AppShell session={session} overview={overview} />;
}
