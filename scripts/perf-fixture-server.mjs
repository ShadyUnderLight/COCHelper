import { createServer } from 'node:http';

function withTimeout(task, timeoutMs, fallback) {
  let timer;
  return Promise.race([
    task,
    new Promise((resolve) => {
      timer = setTimeout(() => resolve(fallback), timeoutMs);
    }),
  ]).finally(() => {
    if (timer !== undefined) clearTimeout(timer);
  });
}

export async function startPerfFixtureApiServer({
  warLogPages,
  capitalRaidPages,
  readPage,
  readText,
  closeTimeoutMs = 5_000,
}) {
  const requests = [];
  const sockets = new Set();
  const server = createServer((request, response) => {
    const requestUrl = new URL(request.url ?? '/', 'http://127.0.0.1');
    const pathname = decodeURIComponent(requestUrl.pathname);
    const endpoint = pathname.endsWith('/warlog')
      ? 'warLog'
      : pathname.endsWith('/capitalraidseasons')
        ? 'capitalRaid'
        : null;
    if (endpoint === null) {
      response.writeHead(404).end();
      return;
    }
    const files = endpoint === 'warLog' ? warLogPages : capitalRaidPages;
    const after = requestUrl.searchParams.get('after');
    let pageIndex = 0;
    if (after !== null) {
      const previousIndex = files.findIndex((file) => readPage(file).after === after);
      if (previousIndex < 0) {
        response.writeHead(404).end();
        return;
      }
      pageIndex = previousIndex + 1;
    }
    const file = files[pageIndex];
    if (file === undefined) {
      response.writeHead(404).end();
      return;
    }
    requests.push({ endpoint, after, file, url: requestUrl.toString() });
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(readText(file));
  });
  server.on('connection', (socket) => {
    sockets.add(socket);
    socket.once('close', () => sockets.delete(socket));
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  if (address === null || typeof address === 'string') {
    throw new Error('fixture API server 没有有效监听地址');
  }
  let closed = false;
  let closePromise = null;
  const requestClose = () => {
    closePromise ??= new Promise((resolve) => {
      server.close((error) =>
        resolve(error === undefined ? { kind: 'closed' } : { kind: 'error', error }),
      );
    });
    return closePromise;
  };
  return {
    port: address.port,
    requests,
    async close() {
      if (closed) return { forced: false };
      const result = await withTimeout(requestClose(), closeTimeoutMs, { kind: 'timeout' });
      if (result.kind === 'closed') {
        closed = true;
        return { forced: false };
      }
      if (result.kind === 'error') {
        throw result.error;
      }

      for (const socket of sockets) socket.destroy();
      server.closeIdleConnections?.();
      server.closeAllConnections?.();
      const forcedResult = await withTimeout(
        requestClose(),
        closeTimeoutMs,
        { kind: 'timeout' },
      );
      if (forcedResult.kind === 'closed') {
        closed = true;
        throw new Error(`fixture API server close 超时，已强制销毁 ${sockets.size} 个连接`);
      }
      if (forcedResult.kind === 'error') {
        throw forcedResult.error;
      }
      throw new Error(`fixture API server close 超时，强制销毁后仍有 ${sockets.size} 个连接`);
    },
  };
}
