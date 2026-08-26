import path from 'node:path';
import { pathToFileURL } from 'node:url';

import { net, protocol } from 'electron';

import { APP_HOST, APP_PROTOCOL } from './security-policy';
import { resolveRendererAsset } from './protocol-path';

export function registerAppScheme(): void {
  protocol.registerSchemesAsPrivileged([
    {
      scheme: APP_PROTOCOL,
      privileges: {
        standard: true,
        secure: true,
        supportFetchAPI: true,
        corsEnabled: true,
        stream: true,
      },
    },
  ]);
}

export function installAppProtocolHandler(): void {
  const rendererRoot = path.join(__dirname, '../renderer/main_window');
  protocol.handle(APP_PROTOCOL, (request) => {
    let parsed: URL;
    try {
      parsed = new URL(request.url);
    } catch {
      return new Response('Bad Request', { status: 400 });
    }
    if (parsed.hostname !== APP_HOST) {
      return new Response('Forbidden', { status: 403 });
    }
    const asset = resolveRendererAsset(rendererRoot, parsed.pathname);
    if (asset === null) {
      return new Response('Forbidden', { status: 403 });
    }
    return net
      .fetch(pathToFileURL(asset).href)
      .catch(() => new Response('Not Found', { status: 404 }));
  });
}
