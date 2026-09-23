import path from 'node:path';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import { assertFixtureSync, collectFixtureFiles } from './check-account-fixture-sync.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function comparableManifest(file) {
  const manifest = JSON.parse(readFileSync(file, 'utf8'));
  return {
    protocolVersion: manifest.protocolVersion,
    fixtureVersion: manifest.fixtureVersion,
    cases: manifest.cases.map(({ fixture, ...entry }) => ({
      ...entry,
      fixture: path.basename(fixture),
    })),
  };
}

export function assertGoldenFixtureSync(electronDirectory, swiftDirectory, swiftManifest) {
  assertFixtureSync(electronDirectory, swiftDirectory, {
    ignore: (relativePath) => relativePath === 'manifest.json',
  });
  const electronManifest = comparableManifest(path.join(electronDirectory, 'manifest.json'));
  const referenceManifest = comparableManifest(swiftManifest);
  if (JSON.stringify(electronManifest) !== JSON.stringify(referenceManifest)) {
    throw new Error('Electron/Swift golden manifest registry 不一致（仅允许 fixture 路径前缀变化）。');
  }
  return electronManifest;
}

if (path.resolve(process.argv[1] ?? '') === fileURLToPath(import.meta.url)) {
  const electronDirectory = path.join(root, 'fixtures', 'golden');
  const swiftDirectory = path.join(root, 'Tests', 'Golden', 'Fixtures');
  const swiftManifest = path.join(root, 'Tests', 'Golden', 'manifest.json');
  assertGoldenFixtureSync(electronDirectory, swiftDirectory, swiftManifest);
  console.log(
    `golden fixture sync ok：${collectFixtureFiles(electronDirectory, {
      ignore: (relativePath) => relativePath === 'manifest.json',
    }).length} files; manifest registry ok`,
  );
}
