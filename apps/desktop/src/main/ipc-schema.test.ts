import { describe, expect, it } from 'vitest';

import {
  APP_HEALTH_CHANNEL,
  APP_SNAPSHOT_CHANNEL,
  API_REFRESH_CHANNEL,
  CAPITAL_RAID_LOAD_MORE_CHANNEL,
  CAPITAL_RAID_STATE_CHANNEL,
  CLAN_STATE_CHANNEL,
  CLAN_WAR_STATE_CHANNEL,
  IMPORT_COMMIT_CHANNEL,
  IMPORT_DISCARD_CHANNEL,
  IMPORT_PREPARE_CHANNEL,
  MANUAL_ADJUST_CHANNEL,
  MANUAL_CANCEL_CHANNEL,
  MANUAL_RECONCILE_CHANNEL,
  MANUAL_SETTLE_CHANNEL,
  MANUAL_START_CHANNEL,
  MANUAL_STATE_CHANNEL,
  OPERATION_PROGRESS_CHANNEL,
  PLAYER_STATE_CHANNEL,
  REQUEST_CANCEL_CHANNEL,
  STATE_CHANGED_CHANNEL,
  UPGRADE_OVERVIEW_CHANNEL,
  VILLAGE_DETAIL_CHANNEL,
  VILLAGE_SELECT_CHANNEL,
  WAR_LOG_LOAD_MORE_CHANNEL,
  WAR_LOG_STATE_CHANNEL,
  isSafeIpcDiagnosticText,
  type RequestId,
} from '@coc-helper/contracts';

import {
  IpcValidationError,
  REGISTERED_IPC_CHANNELS,
  appHealthResponse,
  parseAppSnapshotRequest,
  parseCancelRequest,
  parseImportCommitRequest,
  parseImportDiscardRequest,
  parseImportPrepareRequest,
  parseAppHealthRequest,
  parseVillageSelectRequest,
  toIpcError,
} from './ipc-schema';

describe('app.health schema', () => {
  it('接受空对象或缺省参数', () => {
    expect(() => parseAppHealthRequest(undefined)).not.toThrow();
    expect(() => parseAppHealthRequest({})).not.toThrow();
  });

  it('拒绝多余字段与非对象', () => {
    expect(() => parseAppHealthRequest({ extra: true })).toThrow(IpcValidationError);
    expect(() => parseAppHealthRequest([])).toThrow(IpcValidationError);
    expect(() => parseAppHealthRequest('ping')).toThrow(IpcValidationError);
    expect(() => parseAppHealthRequest(1)).toThrow(IpcValidationError);
  });

  it('登记 health/cancel 与 E3-02 业务通道，并返回 Result envelope', () => {
    expect(REGISTERED_IPC_CHANNELS).toEqual([
      APP_HEALTH_CHANNEL,
      REQUEST_CANCEL_CHANNEL,
      APP_SNAPSHOT_CHANNEL,
      VILLAGE_SELECT_CHANNEL,
      IMPORT_PREPARE_CHANNEL,
      IMPORT_COMMIT_CHANNEL,
      IMPORT_DISCARD_CHANNEL,
      UPGRADE_OVERVIEW_CHANNEL,
      VILLAGE_DETAIL_CHANNEL,
      MANUAL_STATE_CHANNEL,
      MANUAL_START_CHANNEL,
      MANUAL_CANCEL_CHANNEL,
      MANUAL_ADJUST_CHANNEL,
      MANUAL_SETTLE_CHANNEL,
      MANUAL_RECONCILE_CHANNEL,
      PLAYER_STATE_CHANNEL,
      CLAN_STATE_CHANNEL,
      CLAN_WAR_STATE_CHANNEL,
      WAR_LOG_STATE_CHANNEL,
      CAPITAL_RAID_STATE_CHANNEL,
      API_REFRESH_CHANNEL,
      WAR_LOG_LOAD_MORE_CHANNEL,
      CAPITAL_RAID_LOAD_MORE_CHANNEL,
      OPERATION_PROGRESS_CHANNEL,
      STATE_CHANGED_CHANNEL,
    ]);
    expect(appHealthResponse()).toEqual({ ok: true, value: { app: 'coc-helper' } });
  });
});

describe('E3-02 business schemas', () => {
  it('解析 app.snapshot / village.select / import.prepare', () => {
    expect(parseAppSnapshotRequest(undefined)).toEqual({});
    expect(parseVillageSelectRequest({ villageId: 'v-1' })).toEqual({ villageId: 'v-1' });
    expect(() => parseVillageSelectRequest({})).toThrow(IpcValidationError);
    expect(parseImportPrepareRequest({ text: '{}' })).toEqual({ text: '{}' });
    expect(parseImportPrepareRequest({ text: '{}', villageId: null })).toEqual({
      text: '{}',
      villageId: null,
    });
    expect(parseImportPrepareRequest({ text: '{}', villageId: 'v-1' })).toEqual({
      text: '{}',
      villageId: 'v-1',
    });
    expect(() => parseImportPrepareRequest({ text: '{}', extra: true })).toThrow(
      IpcValidationError,
    );
  });

  it('import.commit/discard 必须携带 expectedGeneration', () => {
    expect(parseImportCommitRequest({ expectedGeneration: 3 })).toEqual({
      expectedGeneration: 3,
    });
    expect(() => parseImportCommitRequest({})).toThrow(IpcValidationError);
    expect(() => parseImportCommitRequest(undefined)).toThrow(IpcValidationError);
    expect(parseImportDiscardRequest({ expectedGeneration: 0 })).toEqual({
      expectedGeneration: 0,
    });
    expect(() => parseImportDiscardRequest({ expectedGeneration: -1 })).toThrow(IpcValidationError);
  });
});

describe('request.cancel schema', () => {
  it('接受可打印 requestId 并拒绝空值、超长值和额外字段', () => {
    expect(parseCancelRequest({ requestId: 'request-1' })).toEqual({
      requestId: 'request-1' as RequestId,
    });
    expect(() => parseCancelRequest({ requestId: '' })).toThrow(IpcValidationError);
    expect(() => parseCancelRequest({ requestId: 'x'.repeat(129) })).toThrow(IpcValidationError);
    expect(() => parseCancelRequest({ requestId: 'request-1', extra: true })).toThrow(
      IpcValidationError,
    );
    expect(() => parseCancelRequest({ requestId: 'line\nbreak' })).toThrow(IpcValidationError);
    expect(() => parseCancelRequest('request-1')).toThrow(IpcValidationError);
  });
});

describe('toIpcError', () => {
  it('保留静态 validation 信息并将未知 Error 收敛为安全 internal', () => {
    const bearerMessage = ['Authorization', ': ', 'Bearer', ' ', 'secret-token'].join('');
    expect(toIpcError(new IpcValidationError('请求参数不合法'))).toEqual({
      kind: 'validation',
      code: 'invalidRequest',
      messageKey: 'ipc.invalidRequest',
      message: '请求参数不合法',
    });
    expect(toIpcError(new Error(bearerMessage))).toEqual({
      kind: 'internal',
      code: 'internalError',
      messageKey: 'ipc.internalError',
      message: '宿主内部错误。',
    });
    const redacted = toIpcError(
      new IpcValidationError(`${bearerMessage} https://example.test/body`),
    );
    expect(redacted.message).not.toContain('secret-token');
    expect(isSafeIpcDiagnosticText(redacted.message)).toBe(true);
  });

  it('不信任 IpcValidationError 被篡改的 code/messageKey', () => {
    const error = new IpcValidationError('请求参数不合法', 'invalidCancelRequest');
    Object.defineProperty(error, 'code', { value: 'forgedCode' });
    Object.defineProperty(error, 'messageKey', { value: 'forged.messageKey' });

    expect(toIpcError(error)).toMatchObject({
      kind: 'validation',
      code: 'invalidRequest',
      messageKey: 'ipc.invalidRequest',
    });
  });

  it('将 AbortError 映射为 cancelled，不传播原始消息', () => {
    const error = new Error('request body secret');
    error.name = 'AbortError';
    expect(toIpcError(error)).toEqual({
      kind: 'cancelled',
      code: 'requestCancelled',
      messageKey: 'ipc.requestCancelled',
      message: '请求已取消。',
    });
  });
});
