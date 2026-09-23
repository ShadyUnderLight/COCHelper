import { useCallback, useEffect, useState } from 'react';

import type { DesktopBridge } from '@coc-helper/contracts';

import { formatIpcError } from './app-session';
import {
  applyTokenCommandSuccess,
  applyTokenClearFailure,
  applyTokenSaveFailure,
  applyTokenStatus,
  beginTokenSave,
  INITIAL_TOKEN_SETTINGS_STATE,
  type TokenSettingsState,
} from './token-settings-session';

export type BridgeTokenSettingsClient = Pick<
  DesktopBridge,
  'tokenStatus' | 'tokenSave' | 'tokenClear'
>;

export type TokenSettingsApi = {
  readonly state: TokenSettingsState;
  readonly refresh: () => Promise<void>;
  readonly save: (token: string) => Promise<boolean>;
  readonly clear: () => Promise<boolean>;
};

export function useTokenSettings(bridge: BridgeTokenSettingsClient): TokenSettingsApi {
  const [state, setState] = useState<TokenSettingsState>(INITIAL_TOKEN_SETTINGS_STATE);

  const refresh = useCallback(async () => {
    const result = await bridge.tokenStatus({});
    if (!result.ok) {
      setState({
        status: 'unavailable',
        token: {
          configured: false,
          storage: 'unavailable',
          message: formatIpcError(result.error),
        },
        error: formatIpcError(result.error),
      });
      return;
    }
    setState(applyTokenStatus(result.value));
  }, [bridge]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const save = useCallback(
    async (token: string): Promise<boolean> => {
      setState((previous) => beginTokenSave(previous));
      const result = await bridge.tokenSave({ token });
      if (!result.ok) {
        setState((previous) => applyTokenSaveFailure(previous, formatIpcError(result.error)));
        return false;
      }
      setState(applyTokenCommandSuccess(result.value));
      return true;
    },
    [bridge],
  );

  const clear = useCallback(async (): Promise<boolean> => {
    const result = await bridge.tokenClear({});
    if (!result.ok) {
      setState((previous) => applyTokenClearFailure(previous, formatIpcError(result.error)));
      return false;
    }
    setState(applyTokenCommandSuccess(result.value));
    return true;
  }, [bridge]);

  return { state, refresh, save, clear };
}
