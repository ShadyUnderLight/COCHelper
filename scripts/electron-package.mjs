import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import path from 'node:path';

function packagedResourcesPath(binary) {
  return process.platform === 'darwin'
    ? path.join(path.dirname(binary), '..', 'Resources')
    : path.join(path.dirname(binary), 'resources');
}

export function readPackagedBuildProvenance(binary) {
  const file = path.join(packagedResourcesPath(binary), 'perf-build-provenance.json');
  if (!existsSync(file)) {
    return null;
  }
  try {
    const value = JSON.parse(readFileSync(file, 'utf8'));
    if (
      typeof value?.commitSha !== 'string' ||
      typeof value?.dirty !== 'boolean' ||
      typeof value?.generatedAt !== 'string'
    ) {
      return null;
    }
    return value;
  } catch {
    return null;
  }
}

function findPackagedBinaries(outDir, result = []) {
  if (!existsSync(outDir)) {
    return result;
  }
  const entries = readdirSync(outDir);
  for (const entry of entries) {
    const full = path.join(outDir, entry);
    const stat = statSync(full);
    if (stat.isDirectory()) {
      if (entry.endsWith('.app')) {
        const binary = path.join(full, 'Contents/MacOS/COCHelper');
        if (existsSync(binary)) {
          result.push(binary);
        }
        continue;
      }
      findPackagedBinaries(full, result);
    } else if (entry === 'COCHelper' && (stat.mode & 0o111) !== 0) {
      result.push(full);
    }
  }
  return result;
}

export function resolvePackagedBinary(projectRoot, expectedCommitSha = null) {
  const outDir = path.join(projectRoot, 'apps/desktop/out');
  const candidates = findPackagedBinaries(outDir);
  const binary =
    expectedCommitSha === null
      ? candidates[0]
      : candidates.find((candidate) => {
          const provenance = readPackagedBuildProvenance(candidate);
          return provenance?.commitSha === expectedCommitSha && provenance.dirty === false;
        });
  if (binary === undefined) {
    throw new Error(
      expectedCommitSha === null
        ? '未找到 packaged app。请先运行 pnpm package。'
        : `未找到与源码 ${expectedCommitSha} 匹配且干净的 packaged app。请先运行 pnpm package。`,
    );
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
