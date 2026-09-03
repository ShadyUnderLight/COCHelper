import {
  CoAPIClient,
  CoAPIRequestCancelledError,
  createOfficialEndpointState,
  fetchSingleOfficialEndpoint,
  isCapReached,
  MAX_WAR_LOG_ITEMS_PER_TAG,
  mergedPaginationPage,
  paginationHasMore,
  trimmedPage,
  type CoAPIError,
} from './index';
import { coAPIErrorsEqual } from './co-api-error';
import { RefreshCoordinator } from './refresh-coordinator';
import type { OfficialClanSnapshot } from './models/clan';
import { describe, expect, it } from 'vitest';

/** #274 验收行为矩阵（fake-server / 纯函数契约）。 */
describe('official api behavior matrix', () => {
  async function expectCoAPIError(
    run: () => Promise<unknown>,
    expected: CoAPIError,
  ): Promise<void> {
    await expect(run()).rejects.toSatisfy((error: unknown) =>
      coAPIErrorsEqual(error as CoAPIError, expected),
    );
  }

  function makeClient(
    handler: (request: Request) => Promise<Response> | Response,
    maxRetryCount = 0,
  ) {
    return new CoAPIClient({
      config: {
        scheme: 'https',
        host: 'api.clashofclans.com',
        apiVersion: 'v1',
        requestTimeoutMs: 20_000,
        maxRetryCount,
        baseRetryDelayMs: 1,
        maxRetryDelayMs: 8_000,
      },
      tokenProvider: () => 'fake-token',
      fetch: async (input, init) => handler(new Request(input, init)),
    });
  }

  it('HTTP 401/403/404/429/5xx/malformed 矩阵', async () => {
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
      const client = makeClient(
        () =>
          new Response(testCase.body ?? '', {
            status: testCase.status,
            headers: testCase.headers,
          }),
      );
      await expectCoAPIError(() => client.request('/locations'), testCase.expected);
    }
    const malformed = makeClient(() => new Response('not json', { status: 200 }));
    await expectCoAPIError(() => malformed.fetchLocations(), {
      kind: 'malformedResponse',
      detail: 'locations decode failed',
    });
  });

  it('cursor stall fail-closed：游标未前进时 after 清空', () => {
    const merged = mergedPaginationPage(
      { items: [{ id: 'a' }], before: undefined, after: 'CUR1' },
      { items: [{ id: 'b' }], before: undefined, after: 'CUR1' },
      (left, right) => left.id === right.id,
    );
    expect(merged.after).toBeUndefined();
    expect(paginationHasMore(undefined, merged.after)).toBe(false);
  });

  it('retention cap 达到后 isCapReached', () => {
    const items = Array.from({ length: MAX_WAR_LOG_ITEMS_PER_TAG }, (_, index) => ({ n: index }));
    const page = trimmedPage(
      { items, before: undefined, after: 'MORE' },
      MAX_WAR_LOG_ITEMS_PER_TAG,
    );
    expect(isCapReached(page.items.length, MAX_WAR_LOG_ITEMS_PER_TAG)).toBe(true);
  });

  it('endpoint refresher 失败保留 last-good 与 failureKind', async () => {
    const snapshot: OfficialClanSnapshot = {
      tag: '#CLAN',
      name: 'good',
      type: undefined,
      description: undefined,
      clanLevel: undefined,
      badgeUrls: undefined,
      members: undefined,
      requiredTrophies: undefined,
      requiredTownHallLevel: undefined,
      requiredBuilderBaseTrophies: undefined,
      requiredLeagueTier: undefined,
      clanBuilderBasePoints: undefined,
      clanCapitalPoints: undefined,
      capitalLeague: undefined,
      warLeague: undefined,
      warWins: undefined,
      warLosses: undefined,
      warTies: undefined,
      warWinStreak: undefined,
      isWarLogPublic: undefined,
      labels: undefined,
      clanCapital: undefined,
      unrecognizedKeys: [],
    };
    const previous = createOfficialEndpointState({
      status: 'success',
      clanTag: '#CLAN',
      fetchedAtMs: 1_000,
      lastAttemptAtMs: 1_000,
      parserVersion: 'clan-snapshot-0.4',
      lastGood: snapshot,
    });
    const failed = await fetchSingleOfficialEndpoint({
      tag: '#CLAN',
      previous,
      parserVersion: 'clan-snapshot-0.4',
      nowMs: 2_000,
      fetch: async () => {
        throw { kind: 'unauthorized' } satisfies CoAPIError;
      },
    });
    expect(failed.status).toBe('failed');
    expect(failed.failureKind).toBe('unauthorized');
    expect(failed.lastGood?.name).toBe('good');
    expect(failed.fetchedAtMs).toBe(1_000);
    expect(failed.parserVersion).toBe('clan-snapshot-0.4');
  });

  it('queued refresh drain 消费排队 tag', () => {
    const coordinator = new RefreshCoordinator<void>();
    coordinator.enqueueTag('#A');
    const tags = coordinator.drain([]);
    expect(tags).toEqual(['#A']);
  });

  it('cancel 后 shared flight 不 poison tag', async () => {
    const coordinator = new RefreshCoordinator<number>();
    const parent = new AbortController();
    const flight = coordinator.runSingleFlight(
      '#X',
      async (signal) => {
        await new Promise((resolve) => setTimeout(resolve, 30));
        if (signal.aborted) {
          throw new CoAPIRequestCancelledError();
        }
        return 1;
      },
      parent.signal,
    );
    parent.abort();
    await expect(flight).rejects.toBeInstanceOf(CoAPIRequestCancelledError);

    const recovered = await coordinator.runSingleFlight('#X', async () => 2);
    expect(recovered).toBe(2);
  });
});
