import { useCallback, useEffect, useRef, useState } from 'react';

import type { OperationProgressListener, RequestId, Result } from '@coc-helper/contracts';
import { isRequestId } from '@coc-helper/contracts';

import { formatIpcError } from './app-session';

export type OfficialOp = {
  readonly requestId: RequestId;
  readonly subjectKey: string;
};

export type CommandError = {
  readonly subjectKey: string;
  readonly message: string;
};

export type OfficialCommandBridge = {
  readonly onOperationProgress: (listener: OperationProgressListener) => () => void;
  readonly cancel: (request: { readonly requestId: RequestId }) => void;
};

export function createOfficialRequestId(): RequestId {
  const id = `official-${crypto.randomUUID()}`;
  if (!isRequestId(id)) {
    throw new Error('无法生成官方刷新 requestId');
  }
  return id;
}

export function commandErrorFor(
  error: CommandError | null,
  subjectKey: string | null,
): string | null {
  if (error === null || subjectKey === null || error.subjectKey !== subjectKey) {
    return null;
  }
  return error.message;
}

export function officialClanSubjectKey(
  sessionId: string,
  clanTag: string,
  resource: string,
): string {
  return JSON.stringify([sessionId, clanTag, resource]);
}

type CommandState = {
  readonly refreshing: boolean;
  readonly commandError: CommandError | null;
};

type RunOfficialCommandOptions = {
  readonly bridge: OfficialCommandBridge;
  readonly subjectKey: string;
  readonly subjectRef: React.MutableRefObject<string | null>;
  readonly opRef: React.MutableRefObject<OfficialOp | null>;
  readonly epochRef: React.MutableRefObject<number>;
  readonly setState: React.Dispatch<React.SetStateAction<CommandState>>;
  readonly invoke: (requestId: RequestId) => Promise<Result<unknown>>;
  readonly onSuccess: () => Promise<void>;
  readonly defaultFailureMessage: string;
};

export function cancelOfficialOp(
  bridge: OfficialCommandBridge,
  opRef: React.MutableRefObject<OfficialOp | null>,
  epochRef: React.MutableRefObject<number>,
  setState: React.Dispatch<React.SetStateAction<CommandState>>,
): void {
  const op = opRef.current;
  if (op !== null) {
    epochRef.current += 1;
    bridge.cancel({ requestId: op.requestId });
    opRef.current = null;
  }
  // 即使已无在途 op，也要清掉上一次失败留下的 commandError。
  setState({ refreshing: false, commandError: null });
}

export function useOfficialCommandState(): [
  CommandState,
  React.Dispatch<React.SetStateAction<CommandState>>,
  React.MutableRefObject<OfficialOp | null>,
  React.MutableRefObject<number>,
] {
  const [state, setState] = useState<CommandState>({ refreshing: false, commandError: null });
  const opRef = useRef<OfficialOp | null>(null);
  const epochRef = useRef(0);
  return [state, setState, opRef, epochRef];
}

export function useOfficialCommandLifecycle(
  bridge: OfficialCommandBridge,
  subjectKey: string | null,
  opRef: React.MutableRefObject<OfficialOp | null>,
  epochRef: React.MutableRefObject<number>,
  setState: React.Dispatch<React.SetStateAction<CommandState>>,
): void {
  useEffect(() => {
    const op = opRef.current;
    if (op !== null && (subjectKey === null || op.subjectKey !== subjectKey)) {
      epochRef.current += 1;
      opRef.current = null;
      setState({ refreshing: false, commandError: null });
      bridge.cancel({ requestId: op.requestId });
    } else if (subjectKey !== null) {
      setState((prev) => (prev.commandError === null ? prev : { ...prev, commandError: null }));
    }
  }, [bridge, subjectKey, epochRef, opRef, setState]);

  useEffect(() => {
    return () => {
      epochRef.current += 1;
      const op = opRef.current;
      opRef.current = null;
      if (op !== null) {
        bridge.cancel({ requestId: op.requestId });
      }
    };
  }, [bridge, epochRef, opRef]);
}

export function useOfficialCommandProgress(
  bridge: OfficialCommandBridge,
  opRef: React.MutableRefObject<OfficialOp | null>,
  subjectRef: React.MutableRefObject<string | null>,
  setState: React.Dispatch<React.SetStateAction<CommandState>>,
  defaultFailureMessage: string,
): void {
  useEffect(() => {
    return bridge.onOperationProgress((payload) => {
      const op = opRef.current;
      if (op === null || payload.operationId !== op.requestId) {
        return;
      }
      // completed 由 invoke + onSuccess（含 await query.refresh）收尾；此处只处理取消/失败。
      if (payload.phase !== 'cancelled' && payload.phase !== 'failed') {
        return;
      }
      opRef.current = null;
      setState({ refreshing: false, commandError: null });
      if (payload.phase === 'failed' && subjectRef.current === op.subjectKey) {
        setState({
          refreshing: false,
          commandError: {
            subjectKey: op.subjectKey,
            message: payload.message ?? defaultFailureMessage,
          },
        });
      }
    });
  }, [bridge, defaultFailureMessage, opRef, setState, subjectRef]);
}

export function useRunOfficialCommand(options: RunOfficialCommandOptions): () => Promise<void> {
  const {
    bridge,
    subjectKey,
    subjectRef,
    opRef,
    epochRef,
    setState,
    invoke,
    onSuccess,
    defaultFailureMessage,
  } = options;

  return useCallback(async () => {
    const previous = opRef.current;
    if (previous !== null) {
      bridge.cancel({ requestId: previous.requestId });
    }
    epochRef.current += 1;
    const epoch = epochRef.current;
    const requestId = createOfficialRequestId();
    const op: OfficialOp = { requestId, subjectKey };
    opRef.current = op;
    setState({ refreshing: true, commandError: null });

    const stillCurrent = (): boolean => {
      return epochRef.current === epoch && subjectRef.current === subjectKey;
    };

    const fail = (message: string): void => {
      if (!stillCurrent()) {
        return;
      }
      if (opRef.current?.requestId === requestId) {
        opRef.current = null;
      }
      setState({
        refreshing: false,
        commandError: { subjectKey, message },
      });
    };

    try {
      const result = await invoke(requestId);
      if (!stillCurrent()) {
        return;
      }
      if (!result.ok) {
        fail(formatIpcError(result.error));
        return;
      }
      await onSuccess();
      if (!stillCurrent()) {
        return;
      }
      if (opRef.current?.requestId === requestId) {
        opRef.current = null;
      }
      setState({ refreshing: false, commandError: null });
    } catch (error: unknown) {
      fail(error instanceof Error ? error.message : defaultFailureMessage);
    }
  }, [
    bridge,
    defaultFailureMessage,
    epochRef,
    invoke,
    onSuccess,
    opRef,
    setState,
    subjectKey,
    subjectRef,
  ]);
}
