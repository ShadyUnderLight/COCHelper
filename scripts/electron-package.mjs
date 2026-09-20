import { existsSync, readdirSync, statSync } from 'node:fs';
import path from 'node:path';

export function findPackagedBinary(outDir) {
  if (!existsSync(outDir)) {
    return null;
  }
  const entries = readdirSync(outDir);
  for (const entry of entries) {
    const full = path.join(outDir, entry);
    const stat = statSync(full);
    if (stat.isDirectory()) {
      if (entry.endsWith('.app')) {
        const binary = path.join(full, 'Contents/MacOS/COCHelper');
        if (existsSync(binary)) {
          return binary;
        }
      }
      const nested = findPackagedBinary(full);
      if (nested !== null) {
        return nested;
      }
    } else if (entry === 'COCHelper' && (stat.mode & 0o111) !== 0) {
      return full;
    }
  }
  return null;
}

export function resolvePackagedBinary(projectRoot) {
  const outDir = path.join(projectRoot, 'apps/desktop/out');
  const binary = findPackagedBinary(outDir);
  if (binary === null) {
    throw new Error('未找到 packaged app。请先运行 pnpm package。');
  }

  const posix = binary.split(path.sep).join('/');
  if (!posix.includes('/out/')) {
    throw new Error(`packaged app 必须来自 out/ 产物，实际: ${binary}`);
  }
  if (process.platform === 'darwin' && !posix.includes('.app/Contents/MacOS/')) {
    throw new Error(`macOS packaged app 必须启动 .app 内二进制，实际: ${binary}`);
  }
  return binary;
}
