import { z } from 'zod';

import { APP_HEALTH_CHANNEL, type AppHealthResponse } from '@coc-helper/contracts';

const appHealthRequestSchema = z.object({}).strict().optional();

export class IpcValidationError extends Error {
  override readonly name = 'IpcValidationError';
}

export function parseAppHealthRequest(payload: unknown): void {
  const result = appHealthRequestSchema.safeParse(payload);
  if (!result.success) {
    throw new IpcValidationError('app.health 参数不合法');
  }
}

export function appHealthResponse(): AppHealthResponse {
  return { ok: true, app: 'coc-helper' };
}

export const REGISTERED_IPC_CHANNELS = [APP_HEALTH_CHANNEL] as const;
