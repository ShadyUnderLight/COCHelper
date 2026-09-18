import type { TokenStatusPayload } from '@coc-helper/contracts';

export type TokenSettingsState =
  | { readonly status: 'loading'; readonly token: null; readonly error: null }
  | { readonly status: 'unconfigured'; readonly token: TokenStatusPayload; readonly error: null }
  | { readonly status: 'configured'; readonly token: TokenStatusPayload; readonly error: null }
  | { readonly status: 'saving'; readonly token: TokenStatusPayload; readonly error: null }
  | {
      readonly status: 'unavailable';
      readonly token: TokenStatusPayload;
      readonly error: string | null;
    }
  | {
      readonly status: 'saveFailed';
      readonly token: TokenStatusPayload;
      readonly error: string;
    };

export const INITIAL_TOKEN_SETTINGS_STATE: TokenSettingsState = {
  status: 'loading',
  token: null,
  error: null,
};

export function applyTokenStatus(payload: TokenStatusPayload): TokenSettingsState {
  if (payload.storage !== 'available') {
    return {
      status: 'unavailable',
      token: payload,
      error: payload.message,
    };
  }
  return {
    status: payload.configured ? 'configured' : 'unconfigured',
    token: payload,
    error: null,
  };
}

export function beginTokenSave(state: TokenSettingsState): TokenSettingsState {
  if (state.token === null) {
    return state;
  }
  return {
    status: 'saving',
    token: state.token,
    error: null,
  };
}

export function applyTokenSaveFailure(
  state: TokenSettingsState,
  message: string,
): TokenSettingsState {
  if (state.token === null) {
    return state;
  }
  return {
    status: 'saveFailed',
    token: state.token,
    error: message,
  };
}

export function applyTokenCommandSuccess(payload: TokenStatusPayload): TokenSettingsState {
  return applyTokenStatus(payload);
}
