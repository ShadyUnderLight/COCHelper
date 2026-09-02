import {
  CoAPIClient,
} from './co-api-client';
import type { CoAPIConfig } from './co-api-config';
import type { CoAPIError } from './co-api-error';
import { coAPIErrorsEqual } from './co-api-error';
import { describe, expect, it } from 'vitest';

describe('CoAPIClient', () => {
  function makeClient(
    handler: (request: Request) => Promise<Response> | Response,
    options?: {
      readonly token?: string | null;
      readonly config?: Partial<CoAPIConfig>;
    },
  ) {
    let callCount = 0;
    const token = options?.token === null ? undefined : (options?.token ?? 'fake-token');
    const client = new CoAPIClient({
      config: {
        scheme: 'https',
        host: 'api.clashofclans.com',
        apiVersion: 'v1',
        requestTimeoutMs: 20_000,
        maxRetryCount: options?.config?.maxRetryCount ?? 0,
        baseRetryDelayMs: options?.config?.baseRetryDelayMs ?? 1,
        maxRetryDelayMs: options?.config?.maxRetryDelayMs ?? 8_000,
      },
      tokenProvider: () => token,
      fetch: async (input, init) => {
        callCount += 1;
        return handler(new Request(input, init));
      },
    });
    return { client, getCount: () => callCount };
  }

  async function expectError(
    run: () => Promise<unknown>,
    expected: CoAPIError,
  ): Promise<void> {
    await expect(run()).rejects.toSatisfy((error: unknown) =>
      coAPIErrorsEqual(error as CoAPIError, expected),
    );
  }

  it('fetchLocations 成功', async () => {
    const { client } = makeClient(() =>
      Response.json({
        items: [
          { id: 32_000_000, name: 'International', isCountry: false },
          { id: 32_000_001, name: 'China', isCountry: true },
        ],
      }),
    );
    const result = await client.fetchLocations();
    expect(result.items).toHaveLength(2);
    expect(result.items[0]?.id).toBe(32_000_000);
  });

  it('缺少 token 不发请求', async () => {
    const { client, getCount } = makeClient(() => Response.json({ items: [] }), { token: null });
    await expectError(() => client.request('/locations'), { kind: 'missingCredentials' });
    expect(getCount()).toBe(0);
  });

  it('状态码映射', async () => {
    const cases: Array<{
      status: number;
      headers?: Record<string, string>;
      body?: string;
      expected: CoAPIError;
    }> = [
      { status: 401, expected: { kind: 'unauthorized' } },
      {
        status: 403,
        body: JSON.stringify({ reason: 'accessDenied.invalidIp' }),
        expected: { kind: 'accessDenied', reason: 'accessDenied.invalidIp' },
      },
      { status: 404, expected: { kind: 'notFound' } },
      { status: 429, headers: { 'Retry-After': '60' }, expected: { kind: 'rateLimited', retryAfterSeconds: 60 } },
      { status: 500, expected: { kind: 'serverError', statusCode: 500 } },
    ];
    for (const testCase of cases) {
      const { client, getCount } = makeClient(() =>
        new Response(testCase.body ?? '', {
          status: testCase.status,
          headers: testCase.headers,
        }),
      );
      await expectError(() => client.request('/locations'), testCase.expected);
      expect(getCount()).toBe(1);
    }
  });

  it('429 重试后成功', async () => {
    let count = 0;
    const { client } = makeClient(
      () => {
        count += 1;
        if (count === 1) {
          return new Response('', { status: 429 });
        }
        return Response.json({ items: [{ id: 1 }] });
      },
      { config: { maxRetryCount: 2, baseRetryDelayMs: 1 } },
    );
    const result = await client.fetchLocations();
    expect(result.items).toHaveLength(1);
    expect(count).toBe(2);
  });

  it('5xx 不重试', async () => {
    const { client, getCount } = makeClient(
      () => new Response('', { status: 500 }),
      { config: { maxRetryCount: 2 } },
    );
    await expectError(() => client.request('/locations'), { kind: 'serverError', statusCode: 500 });
    expect(getCount()).toBe(1);
  });

  it('smoke 成功', async () => {
    const { client } = makeClient(() => Response.json({ items: [{ id: 1 }, { id: 2 }] }));
    await expect(client.smoke()).resolves.toEqual({ kind: 'success', locationCount: 2 });
  });

  it('空对象 locations 视为 malformed', async () => {
    const { client } = makeClient(() => Response.json({}));
    await expectError(() => client.fetchLocations(), {
      kind: 'malformedResponse',
      detail: 'locations decode failed',
    });
  });
});
