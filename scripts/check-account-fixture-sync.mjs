import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

export function collectFixtureFiles(directory) {
  const files = [];

  function visit(current, relativeDirectory) {
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      const relativePath = path.join(relativeDirectory, entry.name);
      const absolutePath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        visit(absolutePath, relativePath);
      } else if (entry.isFile()) {
        files.push(relativePath);
      } else {
        throw new Error(`fixture 目录包含不支持的文件类型：${absolutePath}`);
      }
    }
  }

  visit(directory, '');
  return files.sort();
}

export function checkFixtureSync(electronDirectory, swiftDirectory) {
  const electronFiles = collectFixtureFiles(electronDirectory);
  const swiftFiles = collectFixtureFiles(swiftDirectory);
  const electronSet = new Set(electronFiles);
  const swiftSet = new Set(swiftFiles);
  const missingInElectron = swiftFiles.filter((file) => !electronSet.has(file));
  const missingInSwift = electronFiles.filter((file) => !swiftSet.has(file));
  const mismatched = electronFiles.filter(
    (file) =>
      swiftSet.has(file) &&
      !readFileSync(path.join(electronDirectory, file)).equals(
        readFileSync(path.join(swiftDirectory, file)),
      ),
  );

  return { missingInElectron, missingInSwift, mismatched };
}

export function assertFixtureSync(electronDirectory, swiftDirectory) {
  const result = checkFixtureSync(electronDirectory, swiftDirectory);
  if (
    result.missingInElectron.length > 0 ||
    result.missingInSwift.length > 0 ||
    result.mismatched.length > 0
  ) {
    const details = [
      ...result.missingInElectron.map((file) => `Electron 缺少 ${file}`),
      ...result.missingInSwift.map((file) => `Swift 快照缺少 ${file}`),
      ...result.mismatched.map((file) => `内容不一致 ${file}`),
    ];
    throw new Error(`Electron/Swift account fixture 不一致：\n- ${details.join('\n- ')}`);
  }
  return result;
}

if (path.resolve(process.argv[1] ?? '') === fileURLToPath(import.meta.url)) {
  const electronDirectory = path.join(root, 'fixtures', 'account');
  const swiftDirectory = path.join(root, 'Tests', 'COCHelperCoreTests', 'Fixtures');
  assertFixtureSync(electronDirectory, swiftDirectory);
  console.log(`account fixture sync ok：${collectFixtureFiles(electronDirectory).length} files`);
}
