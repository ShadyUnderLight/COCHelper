import type { CoAPIConfig } from './co-api-config';

export type QueryItem = {
  readonly name: string;
  readonly value: string;
};

/** 单段 path percent-encoding（对齐 CoAPIURLBuilder.encodePathComponent）。 */
export function encodePathComponent(raw: string): string {
  return encodeURIComponent(raw);
}

/** 构建官方 API endpoint URL（对齐 CoAPIURLBuilder.endpoint）。 */
export function buildCoAPIEndpoint(
  config: CoAPIConfig,
  path: string,
  queryItems?: readonly QueryItem[],
): URL {
  const trimmedPath = path.startsWith('/') ? path.slice(1) : path;
  const encodedSegments = trimmedPath
    .split('/')
    .filter((segment) => segment.length > 0)
    .map(encodePathComponent);
  const versionedPath = `/${config.apiVersion}${encodedSegments.length > 0 ? `/${encodedSegments.join('/')}` : ''}`;
  const url = new URL(`${config.scheme}://${config.host}${versionedPath}`);
  if (queryItems !== undefined && queryItems.length > 0) {
    for (const item of queryItems) {
      url.searchParams.append(item.name, item.value);
    }
  }
  return url;
}
