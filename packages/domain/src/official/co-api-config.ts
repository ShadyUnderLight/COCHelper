/** 官方 Clash of Clans API 连接配置（对齐 CoAPIConfig.swift）。 */
export type CoAPIConfig = {
  readonly scheme: string;
  readonly host: string;
  readonly apiVersion: string;
  readonly requestTimeoutMs: number;
  readonly maxRetryCount: number;
  readonly baseRetryDelayMs: number;
  readonly maxRetryDelayMs: number;
};

export const DEFAULT_CO_API_CONFIG: CoAPIConfig = {
  scheme: 'https',
  host: 'api.clashofclans.com',
  apiVersion: 'v1',
  requestTimeoutMs: 20_000,
  maxRetryCount: 2,
  baseRetryDelayMs: 500,
  maxRetryDelayMs: 8_000,
};
