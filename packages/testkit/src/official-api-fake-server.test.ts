import { CoAPIClient, coAPIErrorsEqual, type CoAPIError } from '@coc-helper/domain';
import { describe, expect, it, afterEach } from 'vitest';

import {
  createFakeCoAPIServer,
  emptyResponse,
  fakeCoAPIConfig,
  jsonResponse,
  type FakeCoAPIServer,
} from './fake-co-api-server';

/** #274 fake server matrix：真实 HTTP transport + CoAPIClient。 */
describe('official api fake server matrix', () => {
  let server: FakeCoAPIServer | undefined;

  afterEach(async () => {
    await server?.close();
    server = undefined;
  });

  async function makeClient(
    handler: Parameters<typeof createFakeCoAPIServer>[0],
    config?: Partial<ReturnType<typeof fakeCoAPIConfig>>,
  ) {
    server = await createFakeCoAPIServer(handler);
    const baseConfig = fakeCoAPIConfig(server.baseUrl);
    return new CoAPIClient({
      config: { ...baseConfig, ...config },
      tokenProvider: () => 'fake-token',
      fetch: server.fetch,
    });
  }

  async function expectError(run: () => Promise<unknown>, expected: CoAPIError): Promise<void> {
    await expect(run()).rejects.toSatisfy((error: unknown) =>
      coAPIErrorsEqual(error as CoAPIError, expected),
    );
  }

  it('401/403/404/429/5xx/malformed 走真实 HTTP', async () => {
    const cases: Array<{
      status: number;
      expected: CoAPIError;
      body?: string;
      headers?: Record<string, string>;
    }> = [
      { status: 401, expected: { kind: 'unauthorized' } },
      {
        status: 403,
        body: JSON.stringify({ reason: 'accessDenied.invalidIp' }),
        expected: { kind: 'accessDenied', reason: 'accessDenied.invalidIp' },
      },
      { status: 404, expected: { kind: 'notFound' } },
      {
        status: 429,
        headers: { 'Retry-After': '30' },
        expected: { kind: 'rateLimited', retryAfterSeconds: 30 },
      },
      { status: 500, expected: { kind: 'serverError', statusCode: 500 } },
    ];

    for (const testCase of cases) {
      const client = await makeClient(
        () => ({
          status: testCase.status,
          headers: { 'content-type': 'application/json', ...testCase.headers },
          body: testCase.body,
        }),
        { maxRetryCount: 0 },
      );
      await expectError(() => client.request('/locations'), testCase.expected);
    }

    const malformed = await makeClient(
      () => ({
        status: 200,
        body: 'not json',
      }),
      { maxRetryCount: 0 },
    );
    await expectError(() => malformed.fetchLocations(), {
      kind: 'malformedResponse',
      detail: 'locations decode failed',
    });
  });

  it('429 经真实 HTTP 重试后成功', async () => {
    let count = 0;
    const client = await makeClient(
      () => {
        count += 1;
        if (count === 1) {
          return emptyResponse(429);
        }
        return jsonResponse(200, { items: [{ id: 1, name: 'A', isCountry: false }] });
      },
      { maxRetryCount: 2, baseRetryDelayMs: 1 },
    );
    const result = await client.fetchLocations();
    expect(result.items).toHaveLength(1);
    expect(count).toBe(2);
    expect(server?.requestCount).toBe(2);
  });

  it('requestTimeoutMs 触发真实 delay → retry → 最终 timeout', async () => {
    const client = await makeClient(
      async () => {
        await new Promise((resolve) => setTimeout(resolve, 200));
        return jsonResponse(200, { items: [] });
      },
      { maxRetryCount: 1, baseRetryDelayMs: 1, requestTimeoutMs: 50 },
    );
    await expectError(() => client.request('/locations'), { kind: 'timeout' });
    expect(server?.requestCount).toBe(2);
  });

  it('requestTimeoutMs 触发 delay 后第二次成功', async () => {
    let count = 0;
    const client = await makeClient(
      async () => {
        count += 1;
        if (count === 1) {
          await new Promise((resolve) => setTimeout(resolve, 200));
        }
        return jsonResponse(200, { items: [{ id: 2 }] });
      },
      { maxRetryCount: 2, baseRetryDelayMs: 1, requestTimeoutMs: 50 },
    );
    const result = await client.fetchLocations();
    expect(result.items[0]?.id).toBe(2);
    expect(count).toBe(2);
  });
});
