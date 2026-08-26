import { existsSync } from 'node:fs';
import path from 'node:path';

/** 从 cwd 向上找到同时含 `Tests/Golden` 与 `packages/testkit` 的仓库根。 */
export function findRepoRoot(start = process.cwd()): string {
  let current = path.resolve(start);
  while (true) {
    if (
      existsSync(path.join(current, 'Tests/Golden')) &&
      existsSync(path.join(current, 'packages/testkit'))
    ) {
      return current;
    }
    const parent = path.dirname(current);
    if (parent === current) {
      throw new Error(`找不到仓库根（从 ${start} 向上查找）。`);
    }
    current = parent;
  }
}

export function goldenRoot(repoRoot = findRepoRoot()): string {
  return path.join(repoRoot, 'Tests/Golden');
}

export function goldenFixturesRoot(repoRoot = findRepoRoot()): string {
  return path.join(goldenRoot(repoRoot), 'Fixtures');
}

export function goldenManifestPath(repoRoot = findRepoRoot()): string {
  return path.join(goldenRoot(repoRoot), 'manifest.json');
}

export function testRegistryPath(repoRoot = findRepoRoot()): string {
  return path.join(repoRoot, 'packages/testkit/registry.json');
}
