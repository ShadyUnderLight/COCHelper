import { once } from 'node:events';
import { createConnection } from 'node:net';

import { afterEach, describe, expect, it } from 'vitest';

import { startPerfFixtureApiServer } from './perf-fixture-server.mjs';

const pages = ['page-1.json', 'page-2.json'];
const pageData = {
  'page-1.json': { items: [{ id: 1 }], after: 'cursor-1' },
  'page-2.json': { items: [{ id: 2 }], after: undefined },
};

function serverOptions(closeTimeoutMs = 5_000) {
  return {
    warLogPages: pages,
    capitalRaidPages: pages,
    readPage: (file: string) => pageData[file as keyof typeof pageData],
    readText: (file: string) => JSON.stringify(pageData[file as keyof typeof pageData]),
    closeTimeoutMs,
  };
}

describe('perf fixture server', () => {
  const servers: Array<{ close: () => Promise<unknown> }> = [];

  afterEach(async () => {
    for (const server of servers.splice(0)) {
      await server.close().catch(() => undefined);
    }
  });

  it('未知 after cursor 返回 404', async () => {
    const server = await startPerfFixtureApiServer(serverOptions());
    servers.push(server);
    const response = await fetch(`http://127.0.0.1:${server.port}/v1/clans/%23X/warlog?after=unknown`);
    expect(response.status).toBe(404);
    await server.close();
  });

  it('close 超时后销毁连接并报告 forced cleanup', async () => {
    const server = await startPerfFixtureApiServer(serverOptions(20));
    servers.push(server);
    const socket = createConnection(server.port, '127.0.0.1');
    await once(socket, 'connect');

    await expect(server.close()).rejects.toThrow(/强制销毁/);
    socket.destroy();
  });
});
