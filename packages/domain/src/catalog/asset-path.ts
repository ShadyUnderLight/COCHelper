import { resolve, sep } from 'node:path';

const RENDERED_PATH_RE = /^icons\/[^/]+\/[^/]+\.png$/;
const VERSION_SEGMENT_RE = /^\d+\.\d+(\.\d+)?$/;
const MAX_FILENAME_BYTES = 200;

/** 契约 R-D：renderedPath 严格格式校验（对齐 Tools/game_catalog/contract.py）。 */
export function renderedPathFormatOk(renderedPath: string): boolean {
  if (!RENDERED_PATH_RE.test(renderedPath)) {
    return false;
  }
  const parts = renderedPath.split('/');
  if (parts.includes('.') || parts.includes('..')) {
    return false;
  }
  if (renderedPath.includes('%') || renderedPath.includes('\\')) {
    return false;
  }
  if (VERSION_SEGMENT_RE.test(parts[1]!)) {
    return false;
  }
  const exportKey = parts[2]!.slice(0, -4);
  if (exportKey === '' || exportKey === '.' || exportKey === '..') {
    return false;
  }
  return Buffer.byteLength(parts[2]!, 'utf8') <= MAX_FILENAME_BYTES;
}

/** catalog protocol 路径解析：只允许 bundled root 内的 PNG。 */
export function resolveCatalogAssetPath(
  catalogRoot: string,
  version: string,
  pathname: string,
): string | null {
  let decoded: string;
  try {
    decoded = decodeURIComponent(pathname);
  } catch {
    return null;
  }
  if (decoded.includes('\0')) {
    return null;
  }
  const relative = decoded.replace(/^\/+/, '');
  if (relative === '' || relative.includes('..')) {
    return null;
  }
  if (!relative.startsWith(`${version}/`)) {
    return null;
  }
  const assetRelative = relative.slice(version.length + 1);
  if (!renderedPathFormatOk(assetRelative)) {
    return null;
  }
  const root = resolve(catalogRoot);
  const resolved = resolve(root, version, assetRelative);
  const prefix = root.endsWith(sep) ? root : root + sep;
  if (resolved !== root && !resolved.startsWith(prefix)) {
    return null;
  }
  return resolved;
}

export function catalogAssetUrl(
  protocol: string,
  host: string,
  version: string,
  renderedPath: string,
): string {
  return `${protocol}://${host}/${version}/${renderedPath}`;
}

export function isAllowedCatalogAssetUrl(url: string, protocol: string, host: string): boolean {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return false;
  }
  return parsed.protocol === `${protocol}:` && parsed.hostname === host;
}
