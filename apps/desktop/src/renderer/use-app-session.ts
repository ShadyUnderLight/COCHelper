import { useCallback, useEffect, useRef, useState } from 'react';

import type {
  AppSnapshotPayload,
  RecoveryStatusPayload,
  Result,
} from '@coc-helper/contracts';

import {
  applyAcceptedSnapshot,
  applyActionError,
  applyFatalError,
  cursorFromSnapshot,
  formatIpcError,
  INITIAL_APP_SESSION,
  shouldAcceptSnapshot,
  type AppSessionState,
  type BridgeSnapshotClient,
  type ImportPreviewState,
  type SessionCursor,
} from './app-session';

export type AppSessionApi = {
  readonly state: AppSessionState;
  readonly recoveryStatus: RecoveryStatusPayload | null;
  readonly setPasteText: (text: string) => void;
  readonly refresh: () => Promise<void>;
  readonly selectVillage: (villageId: string) => Promise<void>;
  readonly prepareImport: () => Promise<void>;
  readonly commitImport: () => Promise<void>;
  readonly discardImport: () => Promise<void>;
  readonly refreshRecovery: () => Promise<void>;
  readonly recoveryReset: () => Promise<void>;
  readonly recoveryRestoreSaved: () => Promise<void>;
  readonly recoveryRecoverJournal: () => Promise<void>;
};

export function useAppSession(bridge: BridgeSnapshotClient): AppSessionApi {
  const [state, setState] = useState<AppSessionState>(INITIAL_APP_SESSION);
  const [recoveryStatus, setRecoveryStatus] = useState<RecoveryStatusPayload | null>(null);
  const cursorRef = useRef<SessionCursor | null>(null);
  const pasteRef = useRef('');

  const acceptSnapshot = useCallback((snapshot: AppSnapshotPayload) => {
    if (!shouldAcceptSnapshot(cursorRef.current, snapshot)) {
      return;
    }
    cursorRef.current = cursorFromSnapshot(snapshot);
    setState((prev) => applyAcceptedSnapshot(prev, snapshot));
  }, []);

  const refresh = useCallback(async () => {
    const result = await bridge.snapshot({});
    if (!result.ok) {
      setState((prev) =>
        prev.snapshot === null
          ? applyFatalError(prev, formatIpcError(result.error))
          : applyActionError(prev, formatIpcError(result.error)),
      );
      return;
    }
    acceptSnapshot(result.value);
  }, [acceptSnapshot, bridge]);

  useEffect(() => {
    let cancelled = false;
    const unsubscribe = bridge.onStateChanged((payload) => {
      if (!cancelled) {
        acceptSnapshot(payload);
      }
    });

    void (async () => {
      const result = await bridge.snapshot({});
      if (cancelled) {
        return;
      }
      if (!result.ok) {
        setState((prev) => applyFatalError(prev, formatIpcError(result.error)));
        return;
      }
      acceptSnapshot(result.value);
    })();

    return () => {
      cancelled = true;
      unsubscribe();
    };
  }, [acceptSnapshot, bridge]);

  const runWrite = useCallback(
    async (action: (cursor: SessionCursor) => Promise<Result<unknown>>): Promise<boolean> => {
      const cursor = cursorRef.current;
      if (cursor === null) {
        setState((prev) => applyActionError(prev, '应用尚未就绪。'));
        return false;
      }
      setState((prev) => ({ ...prev, busy: true, lastError: null }));
      const result = await action(cursor);
      if (!result.ok) {
        setState((prev) => applyActionError(prev, formatIpcError(result.error)));
        if (result.error.code === 'conflict') {
          await refresh();
        }
        return false;
      }
      setState((prev) => ({ ...prev, busy: false }));
      await refresh();
      return true;
    },
    [refresh],
  );

  const setPasteText = useCallback((text: string) => {
    pasteRef.current = text;
    setState((prev) => ({ ...prev, pasteText: text }));
  }, []);

  const selectVillage = useCallback(
    async (villageId: string) => {
      await runWrite(async () => bridge.selectVillage({ villageId }));
    },
    [bridge, runWrite],
  );

  const prepareImport = useCallback(async () => {
    const snapshot = state.snapshot;
    if (cursorRef.current === null || snapshot === null) {
      setState((prev) => applyActionError(prev, '应用尚未就绪。'));
      return;
    }
    const text = pasteRef.current.trim();
    if (text.length === 0) {
      setState((prev) => applyActionError(prev, '请先粘贴账号 JSON。'));
      return;
    }
    setState((prev) => ({ ...prev, busy: true, lastError: null }));
    const result = await bridge.prepareImport({
      text,
      villageId: snapshot.selectedVillageId,
    });
    if (!result.ok) {
      setState((prev) => applyActionError(prev, formatIpcError(result.error)));
      return;
    }

    const nextPreview: ImportPreviewState = {
      preview: result.value.preview,
      preparedGeneration: result.value.generation,
    };

    // prepare 会 bump generation 并广播；立刻拉取快照，并在同一 setState 写回 preview，避免竞态丢掉 wire。
    const snap = await bridge.snapshot({});
    setState((prev) => {
      if (!snap.ok || !shouldAcceptSnapshot(cursorRef.current, snap.value)) {
        return { ...prev, busy: false, lastError: null, preview: nextPreview };
      }
      cursorRef.current = cursorFromSnapshot(snap.value);
      const base = applyAcceptedSnapshot(prev, snap.value);
      const keepPreview =
        snap.value.pendingImport !== null &&
        nextPreview.preparedGeneration === snap.value.generation;
      return {
        ...base,
        busy: false,
        lastError: null,
        preview: keepPreview ? nextPreview : null,
      };
    });
  }, [bridge, state.snapshot]);

  const commitImport = useCallback(async () => {
    const ok = await runWrite(async (cursor) =>
      bridge.commitImport({ expectedGeneration: cursor.generation }),
    );
    if (ok) {
      pasteRef.current = '';
      setState((prev) => ({ ...prev, pasteText: '', preview: null }));
    }
  }, [bridge, runWrite]);

  const discardImport = useCallback(async () => {
    const ok = await runWrite(async (cursor) =>
      bridge.discardImport({ expectedGeneration: cursor.generation }),
    );
    if (ok) {
      setState((prev) => ({ ...prev, preview: null }));
    }
  }, [bridge, runWrite]);

  const refreshRecovery = useCallback(async () => {
    const result = await bridge.recoveryStatus({});
    if (!result.ok) {
      setState((prev) => applyActionError(prev, formatIpcError(result.error)));
      return;
    }
    setRecoveryStatus(result.value);
  }, [bridge]);

  useEffect(() => {
    if (state.snapshot?.availability === 'recovery') {
      void refreshRecovery();
    } else {
      setRecoveryStatus(null);
    }
  }, [refreshRecovery, state.snapshot?.availability]);

  const recoveryReset = useCallback(async () => {
    await runWrite(async (cursor) =>
      bridge.recoveryReset({ expectedGeneration: cursor.generation }),
    );
    await refreshRecovery();
  }, [bridge, refreshRecovery, runWrite]);

  const recoveryRestoreSaved = useCallback(async () => {
    await runWrite(async (cursor) =>
      bridge.recoveryRestoreSaved({ expectedGeneration: cursor.generation }),
    );
    await refreshRecovery();
  }, [bridge, refreshRecovery, runWrite]);

  const recoveryRecoverJournal = useCallback(async () => {
    await runWrite(async (cursor) =>
      bridge.recoveryRecoverJournal({ expectedGeneration: cursor.generation }),
    );
    await refreshRecovery();
  }, [bridge, refreshRecovery, runWrite]);

  return {
    state,
    recoveryStatus,
    setPasteText,
    refresh,
    selectVillage,
    prepareImport,
    commitImport,
    discardImport,
    refreshRecovery,
    recoveryReset,
    recoveryRestoreSaved,
    recoveryRecoverJournal,
  };
}
