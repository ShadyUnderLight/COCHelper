import { AppShell } from './components/AppShell';
import { getDesktopBridge } from './bridge';
import { useAppSession } from './use-app-session';

export function App() {
  const bridge = getDesktopBridge();
  const session = useAppSession(bridge);
  return <AppShell session={session} />;
}
