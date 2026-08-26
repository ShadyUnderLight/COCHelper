import { describe, expect, it } from 'vitest';

import { isIpcError, isResult, resultErr, resultOk, type IpcError } from './result';

const validError: IpcError = {
  kind: 'validation',
  code: 'invalidRequest',
  messageKey: 'ipc.invalidRequest',
  message: '请求参数不合法。',
};

const isString = (value: unknown): value is string => typeof value === 'string';

describe('@coc-helper/contracts Result', () => {
  it('区分 success 与 failure，并可 JSON 往返', () => {
    const success = resultOk({ answer: 42 });
    const failure = resultErr(validError);

    expect(success).toEqual({ ok: true, value: { answer: 42 } });
    expect(failure).toEqual({ ok: false, error: validError });
    expect(JSON.parse(JSON.stringify(success))).toEqual(success);
    expect(JSON.parse(JSON.stringify(failure))).toEqual(failure);
  });

  it('运行时识别安全错误 envelope 和 Result discriminant', () => {
    const diagnosticError: IpcError = {
      ...validError,
      diagnostics: [
        {
          severity: 'warning',
          code: 'staleData',
          messageKey: 'data.stale',
          message: '数据已过期。',
          path: 'snapshot.items[0]',
        },
      ],
    };
    expect(isIpcError(validError)).toBe(true);
    expect(isIpcError(diagnosticError)).toBe(true);
    expect(isResult({ ok: true, value: 'ready' }, isString, isIpcError)).toBe(true);
    expect(isResult({ ok: false, error: validError }, isString, isIpcError)).toBe(true);
    expect(isResult({ ok: true, value: 'ready', error: validError }, isString, isIpcError)).toBe(
      false,
    );
  });

  it('拒绝 Error、stack 和其他未声明字段，避免秘密跨边界传播', () => {
    const bearerMessage = ['Authorization', ': ', 'Bearer', ' ', 'secret'].join('');
    expect(isIpcError(new Error(bearerMessage))).toBe(false);
    expect(
      isIpcError({
        ...validError,
        stack: bearerMessage,
      }),
    ).toBe(false);
    expect(isIpcError({ ...validError, diagnostics: [{ ...validError }] })).toBe(false);
  });
});
