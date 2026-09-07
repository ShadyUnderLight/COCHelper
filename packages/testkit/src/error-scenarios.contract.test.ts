import {
  CoAPIClient,
  CoAPIRequestCancelledError,
  coAPIErrorKind,
  coAPIErrorsEqual,
  createOfficialEndpointState,
  fetchSingleOfficialEndpoint,
  officialAPISourceLabel,
  officialEndpointRefreshStatus,
  type CoAPIError,
  type OfficialAPIRequestStatus,
  type OfficialClanSnapshot,
  type OfficialEndpointFailureKind,
} from '@coc-helper/domain';
import { bytesToHex, canonicalBytes, canonicalize, parseJson } from '@coc-helper/wire';
import { describe, expect, it } from 'vitest';

import { loadGoldenManifest, readGoldenFixture } from './manifest';

type HttpMappingCase = {
  readonly id: string;
  readonly token?: null;
  readonly status: number;
  readonly body?: string;
  readonly headers?: Record<string, string>;
  readonly request?: 'locations' | 'raw';
  readonly expected: CoAPIError;
};

type FailureKindCase = {
  readonly id: string;
  readonly error: CoAPIError | { readonly type: 'cancelled' };
  readonly expectedFailureKind: OfficialEndpointFailureKind;
};

type SourceLabelCase = {
  readonly id: string;
  readonly status: OfficialAPIRequestStatus;
  readonly hasLastGood: boolean;
  readonly expected: string | null;
};

type RefreshStatusCase = {
  readonly id: string;
  readonly status: OfficialAPIRequestStatus;
  readonly hasLastGood: boolean;
  readonly fetchedAtMs: number | null;
  readonly nowMs: number;
  readonly expected: string;
};

type RefreshPrevious = {
  readonly status: OfficialAPIRequestStatus;
  readonly fetchedAtMs: number;
  readonly parserVersion: string;
  readonly hasLastGood: boolean;
  readonly lastGoodName: string;
};

type RefreshStateExpected = {
  readonly status: string;
  readonly fetchedAtMs: number | null;
  readonly lastAttemptAtMs: number;
  readonly failureKind: OfficialEndpointFailureKind | null;
  readonly lastHTTPStatus: number | null;
  readonly parserVersion: string;
  readonly hasLastGood: boolean;
  readonly lastGoodName: string | null;
  readonly sourceLabel: string | null;
  readonly refreshStatus: string;
  readonly lastErrorReason: string | null;
  readonly canonicalHex: string;
};

type RefreshStateCase = {
  readonly id: string;
  readonly tag: string;
  readonly parserVersion: string;
  readonly nowMs: number;
  readonly previous: RefreshPrevious | null;
  readonly error:
    | {
        readonly type: 'coapi';
        readonly kind: CoAPIError['kind'];
        readonly retryAfterSeconds?: number | null;
      }
    | { readonly type: 'cancelled' }
    | { readonly type: 'unknown'; readonly name: string }
    | { readonly type: 'success'; readonly name: string };
  readonly expected: RefreshStateExpected;
};

type ErrorScenariosContract = {
  readonly contractVersion: number;
  readonly httpMappingCases: readonly HttpMappingCase[];
  readonly failureKindCases: readonly FailureKindCase[];
  readonly sourceLabelCases: readonly SourceLabelCase[];
  readonly refreshStatusCases: readonly RefreshStatusCase[];
  readonly refreshStateCases: readonly RefreshStateCase[];
};

const root = process.cwd();
const manifest = loadGoldenManifest(root);
const entry = manifest.cases.find((item) => item.id === 'error/error-scenarios-contract');
if (entry === undefined) {
  throw new Error('golden manifest 缺少 error/error-scenarios-contract。');
}
const contract = readGoldenFixture(root, entry) as ErrorScenariosContract;

function outcomeCanonicalHex(expected: Omit<RefreshStateExpected, 'canonicalHex'>): string {
  return bytesToHex(
    canonicalBytes(
      canonicalize(
        parseJson(
          JSON.stringify({
            status: expected.status,
            fetchedAtMs: expected.fetchedAtMs,
            lastAttemptAtMs: expected.lastAttemptAtMs,
            failureKind: expected.failureKind,
            lastHTTPStatus: expected.lastHTTPStatus,
            parserVersion: expected.parserVersion,
            hasLastGood: expected.hasLastGood,
            lastGoodName: expected.lastGoodName,
            sourceLabel: expected.sourceLabel,
            refreshStatus: expected.refreshStatus,
            lastErrorReason: expected.lastErrorReason,
          }),
        ),
      ),
    ),
  );
}

function sampleClan(name: string): OfficialClanSnapshot {
  return {
    tag: '#CLAN',
    name,
    type: undefined,
    description: undefined,
    clanLevel: 5,
    badgeUrls: undefined,
    members: 10,
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
}

function makeClient(
  handler: (request: Request) => Promise<Response> | Response,
  token: string | undefined,
) {
  return new CoAPIClient({
    config: {
      scheme: 'https',
      host: 'api.clashofclans.com',
      apiVersion: 'v1',
      requestTimeoutMs: 20_000,
      maxRetryCount: 0,
      baseRetryDelayMs: 1,
      maxRetryDelayMs: 8_000,
    },
    tokenProvider: () => token,
    fetch: async (input, init) => handler(new Request(input, init)),
  });
}

function makeCoAPIError(error: {
  readonly kind: CoAPIError['kind'];
  readonly retryAfterSeconds?: number | null;
}): CoAPIError {
  switch (error.kind) {
    case 'accessDenied':
      return { kind: 'accessDenied', reason: 'x' };
    case 'rateLimited':
      return { kind: 'rateLimited', retryAfterSeconds: error.retryAfterSeconds ?? undefined };
    case 'serverError':
      return { kind: 'serverError', statusCode: 503 };
    case 'network':
      return { kind: 'network', underlying: 'e' };
    case 'malformedResponse':
      return { kind: 'malformedResponse', detail: 'd' };
    case 'missingCredentials':
    case 'unauthorized':
    case 'notFound':
    case 'timeout':
      return { kind: error.kind };
  }
}

describe('error scenarios golden contract', () => {
  it('contractVersion 与 case 集合完整', () => {
    expect(contract.contractVersion).toBe(1);
    expect(contract.httpMappingCases.map((item) => item.id)).toEqual([
      'missing-credentials',
      'http-401-unauthorized',
      'http-403-access-denied',
      'http-404-not-found',
      'http-429-rate-limited',
      'http-500-server-error',
      'http-502-server-error',
      'http-418-unexpected-network',
      'malformed-locations-response',
    ]);
    expect(contract.failureKindCases).toHaveLength(10);
    expect(contract.sourceLabelCases).toHaveLength(7);
    expect(contract.refreshStatusCases).toHaveLength(7);
    expect(contract.refreshStateCases).toHaveLength(5);
  });

  it('HTTP → CoAPIError 映射冻结静态 expected', async () => {
    for (const testCase of contract.httpMappingCases) {
      const token = testCase.token === null ? undefined : 'fake-token';
      const client = makeClient(
        () =>
          new Response(testCase.body ?? '', {
            status: testCase.status,
            headers: testCase.headers,
          }),
        token,
      );
      const run =
        testCase.request === 'locations'
          ? () => client.fetchLocations()
          : () => client.request('/locations');
      await expect(run(), testCase.id).rejects.toSatisfy((error: unknown) =>
        coAPIErrorsEqual(error as CoAPIError, testCase.expected),
      );
    }
  });

  it('failureKind 十值协议冻结静态 expected', async () => {
    for (const testCase of contract.failureKindCases) {
      if ('type' in testCase.error && testCase.error.type === 'cancelled') {
        const state = await fetchSingleOfficialEndpoint({
          tag: '#CLAN',
          previous: undefined,
          parserVersion: 'clan-snapshot-0.9',
          nowMs: 1,
          fetch: async () => {
            throw new CoAPIRequestCancelledError();
          },
        });
        expect(state.failureKind, testCase.id).toBe(testCase.expectedFailureKind);
        continue;
      }
      expect(coAPIErrorKind(testCase.error as CoAPIError), testCase.id).toBe(
        testCase.expectedFailureKind,
      );
    }
  });

  it('sourceLabel 真值表冻结静态 expected', () => {
    for (const testCase of contract.sourceLabelCases) {
      expect(officialAPISourceLabel(testCase.status, testCase.hasLastGood), testCase.id).toBe(
        testCase.expected ?? undefined,
      );
    }
  });

  it('refreshStatus 七态冻结静态 expected', () => {
    for (const testCase of contract.refreshStatusCases) {
      const state = createOfficialEndpointState({
        status: testCase.status,
        parserVersion: 'clan-snapshot-0.4',
        fetchedAtMs: testCase.fetchedAtMs ?? undefined,
        lastGood: testCase.hasLastGood ? sampleClan('good') : undefined,
      });
      expect(officialEndpointRefreshStatus(state, testCase.nowMs), testCase.id).toBe(
        testCase.expected,
      );
    }
  });

  it('refreshState 三保留与 outcome canonicalHex 冻结静态 expected', async () => {
    for (const testCase of contract.refreshStateCases) {
      const previous =
        testCase.previous === null
          ? undefined
          : createOfficialEndpointState({
              status: testCase.previous.status,
              clanTag: testCase.tag,
              fetchedAtMs: testCase.previous.fetchedAtMs,
              lastAttemptAtMs: testCase.previous.fetchedAtMs,
              parserVersion: testCase.previous.parserVersion,
              lastGood: testCase.previous.hasLastGood
                ? sampleClan(testCase.previous.lastGoodName)
                : undefined,
            });

      const state = await fetchSingleOfficialEndpoint({
        tag: testCase.tag,
        previous,
        parserVersion: testCase.parserVersion,
        nowMs: testCase.nowMs,
        fetch: async () => {
          if (testCase.error.type === 'success') {
            return sampleClan(testCase.error.name);
          }
          if (testCase.error.type === 'cancelled') {
            throw new CoAPIRequestCancelledError();
          }
          if (testCase.error.type === 'unknown') {
            if (testCase.error.name === 'TypeError') {
              throw new TypeError('boom');
            }
            throw new Error('boom');
          }
          throw makeCoAPIError(testCase.error);
        },
      });

      const actual = {
        status: state.status,
        fetchedAtMs: state.fetchedAtMs ?? null,
        lastAttemptAtMs: state.lastAttemptAtMs!,
        failureKind: state.failureKind ?? null,
        lastHTTPStatus: state.lastHTTPStatus ?? null,
        parserVersion: state.parserVersion,
        hasLastGood: state.lastGood !== undefined,
        lastGoodName: state.lastGood?.name ?? null,
        sourceLabel: officialAPISourceLabel(state.status, state.lastGood !== undefined) ?? null,
        refreshStatus: officialEndpointRefreshStatus(state, testCase.nowMs),
        lastErrorReason: state.lastErrorReason ?? null,
      };

      expect(actual, testCase.id).toEqual({
        status: testCase.expected.status,
        fetchedAtMs: testCase.expected.fetchedAtMs,
        lastAttemptAtMs: testCase.expected.lastAttemptAtMs,
        failureKind: testCase.expected.failureKind,
        lastHTTPStatus: testCase.expected.lastHTTPStatus,
        parserVersion: testCase.expected.parserVersion,
        hasLastGood: testCase.expected.hasLastGood,
        lastGoodName: testCase.expected.lastGoodName,
        sourceLabel: testCase.expected.sourceLabel,
        refreshStatus: testCase.expected.refreshStatus,
        lastErrorReason: testCase.expected.lastErrorReason,
      });
      expect(outcomeCanonicalHex(actual), testCase.id).toBe(testCase.expected.canonicalHex);
    }
  });
});
