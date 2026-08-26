import path from 'node:path';

export function normalizeRendererPathname(pathname: string): string {
  const stripped = pathname.replace(/^\/main_window(?=\/|$)/, '');
  return stripped === '' ? '/' : stripped;
}

export function resolveRendererAsset(rendererRoot: string, pathname: string): string | null {
  let decoded: string;
  try {
    decoded = decodeURIComponent(normalizeRendererPathname(pathname));
  } catch {
    return null;
  }
  if (decoded.includes('\0')) {
    return null;
  }
  const relative = decoded === '/' ? 'index.html' : decoded.replace(/^\/+/, '');
  const root = path.resolve(rendererRoot);
  const resolved = path.resolve(root, relative);
  const prefix = root.endsWith(path.sep) ? root : root + path.sep;
  if (resolved !== root && !resolved.startsWith(prefix)) {
    return null;
  }
  return resolved;
}
