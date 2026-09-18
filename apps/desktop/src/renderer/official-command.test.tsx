/** @vitest-environment jsdom */

import { act, renderHook, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import type { OperationProgressListener, Result } from '@coc-helper/contracts';

import {
  useOfficialCommandLifecycle,
  useOfficialCommandState,
  useRunOfficialCommand,
  type OfficialCommandBridge,
} from './official-command';

function ok<T>(value: T): Result<T> {
  return { ok: true, value };
}

function err(message: string): Result<never> {
  return {
    ok: false,
    error: {
      kind: 'internal',
      code: 'failed',
      messageKey: 'failed',
      message,
    },
  };
}

function createBridge() {
  const resolvers: Array<(value: Result<unknown>) => void> = [];
  const progressListeners = new Set<OperationProgressListener>();
  const bridge: OfficialCommandBridge = {
    onOperationProgress: (listener) => {
      progressListeners.add(listener);
      return () => {
        progressListeners.delete(listener);
      };
    },
    cancel: vi.fn(),
  };
  return {
    bridge,
    invoke: vi.fn(
      async () =>
        await new Promise<Result<unknown>>((resolve) => {
          resolvers.push(resolve);
        }),
    ),
    resolve(value: Result<unknown>) {
      resolvers.shift()?.(value);
    },
  };
}

function useCommandHarness(
  bridge: OfficialCommandBridge,
  invoke: (requestId: string) => Promise<Result<unknown>>,
  onSuccess: () => Promise<void>,
  subjectKey: string,
) {
  const subjectRef = { current: subjectKey };
  const [state, setState, opRef, epochRef] = useOfficialCommandState();
  useOfficialCommandLifecycle(bridge, subjectKey, opRef, epochRef, setState);
  const run = useRunOfficialCommand({
    bridge,
    subjectKey,
    subjectRef,
    opRef,
    epochRef,
    setState,
    invoke: (requestId) => invoke(requestId),
    onSuccess,
    defaultFailureMessage: '命令失败',
  });
  return { state, run };
}

describe('official-command lifecycle', () => {
  it('unmount 后迟到的 success/error 不再执行 onSuccess 或写入 commandError', async () => {
    const harness = createBridge();
    const onSuccess = vi.fn(async () => {});
    const { result, unmount } = renderHook(() =>
      useCommandHarness(harness.bridge, harness.invoke, onSuccess, 'subject-a'),
    );

    act(() => {
      void result.current.run();
    });
    await waitFor(() => {
      expect(harness.invoke).toHaveBeenCalledTimes(1);
    });

    unmount();

    await act(async () => {
      harness.resolve(ok({ generation: 2 }));
    });
    expect(onSuccess).not.toHaveBeenCalled();

    const harnessErr = createBridge();
    const onSuccessErr = vi.fn(async () => {});
    const view = renderHook(() =>
      useCommandHarness(harnessErr.bridge, harnessErr.invoke, onSuccessErr, 'subject-b'),
    );
    act(() => {
      void view.result.current.run();
    });
    await waitFor(() => {
      expect(harnessErr.invoke).toHaveBeenCalledTimes(1);
    });
    view.unmount();
    await act(async () => {
      harnessErr.resolve(err('迟到失败'));
    });
    expect(onSuccessErr).not.toHaveBeenCalled();
  });
});
