import type { SessionCursor } from './app-session';

export function advanceSessionCursor(
  cursorRef: { current: SessionCursor | null },
  sessionId: string,
  generation: number,
): void {
  const current = cursorRef.current;
  if (current === null || current.sessionId !== sessionId) {
    cursorRef.current = { sessionId, generation };
    return;
  }
  if (generation > current.generation) {
    cursorRef.current = { sessionId, generation };
  }
}
