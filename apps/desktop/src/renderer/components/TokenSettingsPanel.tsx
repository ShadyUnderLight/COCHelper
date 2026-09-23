import { useEffect, useState, type FormEvent } from 'react';

import type { DesktopBridge } from '@coc-helper/contracts';

import { useTokenSettings } from '../use-token-settings';

export function TokenSettingsPanel({
  bridge,
  onTokenChanged,
  onRefreshReady,
}: {
  readonly bridge: Pick<DesktopBridge, 'tokenStatus' | 'tokenSave' | 'tokenClear'>;
  readonly onTokenChanged?: () => void;
  readonly onRefreshReady?: (refresh: (() => Promise<void>) | null) => void;
}) {
  const api = useTokenSettings(bridge);
  const [input, setInput] = useState('');
  const [inputError, setInputError] = useState<string | null>(null);
  useEffect(() => {
    if (onRefreshReady === undefined) {
      return;
    }
    onRefreshReady(api.refresh);
    return () => onRefreshReady(null);
  }, [api.refresh, onRefreshReady]);
  const storageWritable =
    api.state.token?.storage === 'available' || api.state.token?.storage === 'decryptFailed';
  const saving = api.state.status === 'saving';
  const configured = api.state.token?.configured === true;
  const canClear = configured || api.state.token?.storage === 'decryptFailed';

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (input.trim().length === 0) {
      setInputError('请输入 Token。');
      return;
    }
    setInputError(null);
    if (await api.save(input)) {
      setInput('');
      onTokenChanged?.();
    }
  };

  const clear = async () => {
    setInputError(null);
    if (await api.clear()) {
      onTokenChanged?.();
    }
  };

  return (
    <section className="info-panel" aria-label="Token 设置">
      <div className="info-panel-heading">
        <div>
          <h2>Token Settings</h2>
          <p className="muted">Token 只会交给系统安全存储，不会显示或写入普通应用状态。</p>
        </div>
      </div>

      {api.state.status === 'loading' ? <p className="muted">正在读取 Token 状态…</p> : null}
      {api.state.status === 'unconfigured' ? (
        <p className="notice-text">当前未配置 Token。</p>
      ) : null}
      {api.state.status === 'configured' ? (
        <p className="notice-text">Token 已配置，输入新 Token 可覆盖当前配置。</p>
      ) : null}
      {api.state.status === 'unavailable' && api.state.token.storage === 'decryptFailed' ? (
        <p className="error-text" role="alert">
          已保存的 Token 无法解密，可以覆盖保存或清除损坏的凭据。
        </p>
      ) : null}
      {api.state.status === 'unavailable' && api.state.token.storage === 'unavailable' ? (
        <p className="error-text" role="alert">
          安全存储不可用{api.state.error === null ? '。' : `：${api.state.error}`}
        </p>
      ) : null}
      {api.state.status === 'saveFailed' ? (
        <p className="error-text" role="alert">
          Token 保存失败：{api.state.error}
        </p>
      ) : null}
      {api.state.status === 'clearFailed' ? (
        <p className="error-text" role="alert">
          Token 清除失败：{api.state.error}
        </p>
      ) : null}

      <form className="token-form" onSubmit={(event) => void submit(event)}>
        <label htmlFor="co-api-token">CoC API Token</label>
        <input
          id="co-api-token"
          type="password"
          value={input}
          autoComplete="off"
          spellCheck={false}
          disabled={!storageWritable || saving}
          onChange={(event) => {
            setInput(event.target.value);
            setInputError(null);
          }}
        />
        {inputError !== null ? (
          <p className="error-text" role="alert">
            {inputError}
          </p>
        ) : null}
        <div className="action-row">
          <button type="submit" disabled={!storageWritable || saving}>
            {saving ? '保存中…' : configured ? '更新 Token' : '保存 Token'}
          </button>
          <button
            type="button"
            className="danger"
            disabled={!canClear || saving}
            onClick={() => void clear()}
          >
            清除 Token
          </button>
        </div>
      </form>
    </section>
  );
}
