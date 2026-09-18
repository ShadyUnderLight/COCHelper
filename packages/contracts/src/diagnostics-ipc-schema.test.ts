import { describe, expect, it } from 'vitest';

import {
  diagnosticsSnapshotPayloadSchema,
  isDiagnosticsSnapshotPayload,
  isTokenStatusPayload,
  tokenSaveRequestSchema,
} from './diagnostics-ipc-schema';

const payload = {
  sessionId: 'session-1',
  app: { name: 'COCHelper', version: '0.0.0' },
  runtime: {
    electron: '44.0.0',
    node: '24.18.1',
    chrome: '136.0.0',
    platform: 'darwin',
    arch: 'arm64',
  },
  application: {
    availability: 'available',
    villageStatus: 'available',
    generation: 3,
    selectedVillageId: 'v1',
    selectedVillageName: '主村',
    canWrite: true,
    hasPendingJournal: false,
  },
  catalog: { status: 'available', version: '18.400.13' },
  official: {
    endpointAccess: 'mainOnly',
    authorization: 'mainOnly',
    credentialStorage: 'available',
    rawResponseExposure: 'notExposed',
  },
  manual: { status: 'empty' },
  token: { configured: false, storage: 'available', message: null },
} as const;

describe('diagnostics IPC schema', () => {
  it('接受脱敏的 diagnostics snapshot 和 token status', () => {
    expect(isDiagnosticsSnapshotPayload(payload)).toBe(true);
    expect(isTokenStatusPayload(payload.token)).toBe(true);
    expect(diagnosticsSnapshotPayloadSchema.parse(payload)).toEqual(payload);
  });

  it('拒绝额外敏感字段和不安全文案', () => {
    expect(
      isDiagnosticsSnapshotPayload({
        ...payload,
        token: { ...payload.token, plaintext: 'secret-token' },
      }),
    ).toBe(false);
    expect(
      isTokenStatusPayload({
        configured: false,
        storage: 'unavailable',
        message: 'Authorization: Bearer secret-token',
      }),
    ).toBe(false);
  });

  it('限制 token.save 输入形状和长度', () => {
    expect(tokenSaveRequestSchema.parse({ token: 'secret-token' })).toEqual({
      token: 'secret-token',
    });
    expect(() => tokenSaveRequestSchema.parse({ token: '' })).toThrow();
    expect(() => tokenSaveRequestSchema.parse({ token: 'x'.repeat(513) })).toThrow();
    expect(() => tokenSaveRequestSchema.parse({ token: 'secret-token', extra: true })).toThrow();
  });
});
