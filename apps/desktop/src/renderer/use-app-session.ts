import { useCallback, useEffect, useRef, useState } from 'react';

import type { AppSnapshotPayload, RecoveryStatusPayload, Result } from '@coc-helper/contracts';

import {
  applyAcceptedSnapshot,
  applyActionError,
  applyFatalError,
  cursorFromSnapshot,
  formatIpcError,
  INITIAL_APP_SESSION,
  isCurrentEpoch,
  mergePrepareFollowUp,
  resolveCommitGeneration,
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
  const epochRef = useRef(0);
  const previewRef = useRef<ImportPreviewState | null>(null);
  const pasteRef = useRef('');

  const setPreview = useCallback((preview: ImportPreviewState | null) => {
    previewRef.current = preview;
  }, []);

  const acceptSnapshot = useCallback(
    (snapshot: AppSnapshotPayload, requestEpoch?: number) => {
      if (requestEpoch !== undefined && !isCurrentEpoch(requestEpoch, epochRef.current)) {
        return;
      }
      if (!shouldAcceptSnapshot(cursorRef.current, snapshot)) {
        return;
      }
      cursorRef.current = cursorFromSnapshot(snapshot);
      setState((prev) => {
        const next = applyAcceptedSnapshot(prev, snapshot);
        setPreview(next.preview);
        return next;
      });
    },
    [setPreview],
  );

  const refresh = useCallback(async () => {
    const requestEpoch = epochRef.current;
    const result = await bridge.snapshot({});
    if (!isCurrentEpoch(requestEpoch, epochRef.current)) {
      return;
    }
    if (!result.ok) {
      setState((prev) =>
        prev.snapshot === null
          ? applyFatalError(prev, formatIpcError(result.error))
          : applyActionError(prev, formatIpcError(result.error)),
      );
      return;
    }
    acceptSnapshot(result.value, requestEpoch);
  }, [acceptSnapshot, bridge]);

  useEffect(() => {
    let cancelled = false;
    const bootEpoch = epochRef.current;
    const unsubscribe = bridge.onStateChanged((payload) => {
      if (!cancelled) {
        acceptSnapshot(payload);
      }
    });

    void (async () => {
      const result = await bridge.snapshot({});
      if (cancelled || !isCurrentEpoch(bootEpoch, epochRef.current)) {
        return;
      }
      if (!result.ok) {
        setState((prev) => applyFatalError(prev, formatIpcError(result.error)));
        return;
      }
      acceptSnapshot(result.value, bootEpoch);
    })();

    return () => {
      cancelled = true;
      // 卸载或 bridge 更换时推进 epoch，丢弃挂起的 boot/pull 响应。
      epochRef.current += 1;
      unsubscribe();
    };
  }, [acceptSnapshot, bridge]);

  const runWrite = useCallback(
    async (action: (cursor: SessionCursor) => Promise<Result<unknown>>): Promise<boolean> => {
      const cursor = cursorRef.current;
      const requestEpoch = epochRef.current;
      if (cursor === null) {
        setState((prev) => applyActionError(prev, '应用尚未就绪。'));
        return false;
      }
      setState((prev) => ({ ...prev, busy: true, lastError: null }));
      const result = await action(cursor);
      if (!isCurrentEpoch(requestEpoch, epochRef.current)) {
        return false;
      }
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
    const requestEpoch = epochRef.current;
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
    if (!isCurrentEpoch(requestEpoch, epochRef.current)) {
      return;
    }
    if (!result.ok) {
      setState((prev) => applyActionError(prev, formatIpcError(result.error)));
      return;
    }

    const nextPreview: ImportPreviewState = {
      preview: result.value.preview,
      preparedGeneration: result.value.generation,
    };

    // prepare 会 bump generation 并广播；立刻拉取快照，严格按 preparedGeneration 对齐。
    const snap = await bridge.snapshot({});
    if (!isCurrentEpoch(requestEpoch, epochRef.current)) {
      return;
    }
    const followUp = mergePrepareFollowUp(cursorRef.current, nextPreview, snap);
    if (followUp.kind === 'stale') {
      setPreview(null);
      setState((prev) => ({
        ...prev,
        busy: false,
        preview: null,
        lastError: followUp.reason,
      }));
      // 权威态通常已由 state.changed 对齐；仅 snapshot 拉取失败时再 refresh，并保留错误文案。
      if (!snap.ok) {
        await refresh();
        setState((prev) => ({
          ...prev,
          preview: null,
          lastError: followUp.reason,
        }));
      }
      return;
    }

    cursorRef.current = cursorFromSnapshot(followUp.snapshot);
    setPreview(followUp.preview);
    setState((prev) => ({
      ...applyAcceptedSnapshot(prev, followUp.snapshot),
      busy: false,
      lastError: null,
      preview: followUp.preview,
    }));
  }, [bridge, refresh, setPreview, state.snapshot]);

  const commitImport = useCallback(async () => {
    const resolution = resolveCommitGeneration(previewRef.current, cursorRef.current);
    if (!resolution.ok) {
      setPreview(null);
      setState((prev) => applyActionError({ ...prev, preview: null }, resolution.reason));
      await refresh();
      return;
    }
    const expectedGeneration = resolution.expectedGeneration;
    const ok = await runWrite(async () => bridge.commitImport({ expectedGeneration }));
    if (ok) {
      pasteRef.current = '';
      setPreview(null);
      setState((prev) => ({ ...prev, pasteText: '', preview: null }));
    }
  }, [bridge, refresh, runWrite, setPreview]);

  const discardImport = useCallback(async () => {
    const resolution = resolveCommitGeneration(previewRef.current, cursorRef.current);
    if (!resolution.ok) {
      setPreview(null);
      setState((prev) => applyActionError({ ...prev, preview: null }, resolution.reason));
      await refresh();
      return;
    }
    const expectedGeneration = resolution.expectedGeneration;
    const ok = await runWrite(async () => bridge.discardImport({ expectedGeneration }));
    if (ok) {
      setPreview(null);
      setState((prev) => ({ ...prev, preview: null }));
    }
  }, [bridge, refresh, runWrite, setPreview]);

  const refreshRecovery = useCallback(async () => {
    const requestEpoch = epochRef.current;
    const result = await bridge.recoveryStatus({});
    if (!isCurrentEpoch(requestEpoch, epochRef.current)) {
      return;
    }
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
