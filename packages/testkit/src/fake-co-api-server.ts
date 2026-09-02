import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { URL } from 'node:url';

export type FakeCoAPIResponse = {
  readonly status: number;
  readonly headers?: Readonly<Record<string, string>>;
  readonly body?: string | Buffer;
};

export type FakeCoAPIHandler = (
  request: IncomingMessage & { readonly url: string },
) => FakeCoAPIResponse | Promise<FakeCoAPIResponse>;

export type FakeCoAPIServer = {
  readonly baseUrl: string;
  readonly fetch: typeof fetch;
  readonly close: () => Promise<void>;
  get lastAuthorization(): string | undefined;
  get requestCount(): number;
};

export async function createFakeCoAPIServer(
  handler: FakeCoAPIHandler,
): Promise<FakeCoAPIServer> {
  let lastAuthorization: string | undefined;
  let requestCount = 0;

  const server = createServer(async (req, res) => {
    requestCount += 1;
    lastAuthorization = req.headers.authorization;
    const response = await handler(req as IncomingMessage & { readonly url: string });
    const headers = response.headers ?? {};
    for (const [key, value] of Object.entries(headers)) {
      res.setHeader(key, value);
    }
    res.statusCode = response.status;
    if (response.body !== undefined) {
      res.end(response.body);
    } else {
      res.end();
    }
  });

  await new Promise<void>((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve());
  });
  const address = server.address();
  if (address === null || typeof address === 'string') {
    throw new Error('无法启动 fake Co API server。');
  }
  const baseUrl = `http://127.0.0.1:${address.port}`;

  return {
    baseUrl,
    fetch: (input, init) => fetch(input, init),
    close: () =>
      new Promise((resolve, reject) => {
        server.close((error) => {
          if (error) {
            reject(error);
            return;
          }
          resolve();
        });
      }),
    get lastAuthorization() {
      return lastAuthorization;
    },
    get requestCount() {
      return requestCount;
    },
  };
}

export function fakeCoAPIConfig(baseUrl: string) {
  const url = new URL(baseUrl);
  return {
    scheme: url.protocol.replace(':', ''),
    host: url.host,
    apiVersion: 'v1',
    requestTimeoutMs: 20_000,
    maxRetryCount: 2,
    baseRetryDelayMs: 1,
    maxRetryDelayMs: 8_000,
  };
}

export function jsonResponse(status: number, value: unknown, headers?: Record<string, string>): FakeCoAPIResponse {
  return {
    status,
    headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify(value),
  };
}

export function emptyResponse(status: number, headers?: Record<string, string>): FakeCoAPIResponse {
  return { status, headers };
}

export function pathOf(request: IncomingMessage): string {
  return new URL(request.url ?? '/', 'http://localhost').pathname;
}

export function queryOf(request: IncomingMessage): URLSearchParams {
  return new URL(request.url ?? '/', 'http://localhost').searchParams;
}

export function writeResponse(res: ServerResponse, response: FakeCoAPIResponse): void {
  const headers = response.headers ?? {};
  for (const [key, value] of Object.entries(headers)) {
    res.setHeader(key, value);
  }
  res.statusCode = response.status;
  if (response.body !== undefined) {
    res.end(response.body);
  } else {
    res.end();
  }
}
