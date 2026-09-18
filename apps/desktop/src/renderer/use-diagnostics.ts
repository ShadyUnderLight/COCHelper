import type { AppSnapshotPayload, DesktopBridge } from '@coc-helper/contracts';

import { useResourceQuery } from './use-resource-query';
import type { DiagnosticsState } from './diagnostics-session';

export type BridgeDiagnosticsClient = Pick<DesktopBridge, 'diagnosticsSnapshot'>;

export type DiagnosticsApi = {
  readonly state: DiagnosticsState;
  readonly refresh: () => Promise<void>;
};

export function useDiagnostics(
  bridge: BridgeDiagnosticsClient,
  snapshot: AppSnapshotPayload | null,
): DiagnosticsApi {
  const query = useResourceQuery({
    snapshot,
    subjectKey: snapshot === null ? null : `${snapshot.sessionId}:diagnostics`,
    fetch: () => bridge.diagnosticsSnapshot({}),
    extractGeneration: (payload) => payload.application.generation,
    fetchErrorMessage: '诊断查询失败',
  });
  return {
    state: query.state,
    refresh: query.refresh,
  };
}
