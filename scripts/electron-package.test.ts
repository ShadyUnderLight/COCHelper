import { chmodSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { afterEach, describe, expect, it } from 'vitest';

import { readPackagedBuildProvenance, resolvePackagedBinary } from './electron-package.mjs';

function binaryAndResources(root: string, name: string) {
  if (process.platform === 'darwin') {
    const app = path.join(root, name, 'COCHelper.app');
    return {
      binary: path.join(app, 'Contents', 'MacOS', 'COCHelper'),
      resources: path.join(app, 'Contents', 'Resources'),
    };
  }
  const app = path.join(root, name);
  return {
    binary: path.join(app, 'COCHelper'),
    resources: path.join(app, 'resources'),
  };
}

describe('packaged Electron provenance', () => {
  const roots: string[] = [];

  afterEach(() => {
    for (const root of roots.splice(0)) {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it('读取并校验 packaged provenance', () => {
    const root = mkdtempSync(path.join(tmpdir(), 'coc-electron-package-'));
    roots.push(root);
    const artifact = binaryAndResources(root, 'artifact');
    mkdirSync(path.dirname(artifact.binary), { recursive: true });
    mkdirSync(artifact.resources, { recursive: true });
    writeFileSync(artifact.binary, 'binary');
    chmodSync(artifact.binary, 0o755);
    writeFileSync(
      path.join(artifact.resources, 'perf-build-provenance.json'),
      JSON.stringify({ commitSha: 'abc123', dirty: false, generatedAt: '2026-09-20T00:00:00.000Z' }),
    );

    expect(readPackagedBuildProvenance(artifact.binary)).toEqual({
      commitSha: 'abc123',
      dirty: false,
      generatedAt: '2026-09-20T00:00:00.000Z',
    });
  });

  it('按 expected commit 选择匹配且干净的 binary，不接受旧或 dirty 产物', () => {
    const projectRoot = mkdtempSync(path.join(tmpdir(), 'coc-electron-package-'));
    roots.push(projectRoot);
    const outRoot = path.join(projectRoot, 'apps', 'desktop', 'out');
    const old = binaryAndResources(outRoot, 'a-old');
    const current = binaryAndResources(outRoot, 'b-current');
    for (const artifact of [old, current]) {
      mkdirSync(path.dirname(artifact.binary), { recursive: true });
      mkdirSync(artifact.resources, { recursive: true });
      writeFileSync(artifact.binary, 'binary');
      chmodSync(artifact.binary, 0o755);
    }
    writeFileSync(
      path.join(old.resources, 'perf-build-provenance.json'),
      JSON.stringify({ commitSha: 'old', dirty: false, generatedAt: '2026-09-20T00:00:00.000Z' }),
    );
    writeFileSync(
      path.join(current.resources, 'perf-build-provenance.json'),
      JSON.stringify({ commitSha: 'current', dirty: false, generatedAt: '2026-09-20T00:00:00.000Z' }),
    );

    expect(resolvePackagedBinary(projectRoot, 'current')).toBe(current.binary);
    expect(() => resolvePackagedBinary(projectRoot, 'missing')).toThrow(/匹配且干净/);
  });
});
