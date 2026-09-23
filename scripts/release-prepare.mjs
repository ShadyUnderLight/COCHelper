import { parseArgs } from 'node:util';
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

import {
  assertReleaseSourceClean,
  readReleaseMetadata,
  readResolvedElectronVersion,
  validateSemver,
} from './release-metadata.mjs';
import { buildCycloneDxBom, readProductionDependencyTree, SBOM_PROTOCOL } from './release-sbom.mjs';

export const ARTIFACT_MANIFEST_PROTOCOL = 'cochelper-artifact-manifest-v1';

const NATIVE_BUILD_ENV_KEYS = Object.freeze([
  'PATH',
  'HOME',
  'TMPDIR',
  'TMP',
  'TEMP',
  'LANG',
  'LC_ALL',
  'LC_CTYPE',
  'PYTHON',
  'CC',
  'CXX',
  'CFLAGS',
  'CXXFLAGS',
  'LDFLAGS',
  'ARCHFLAGS',
  'SDKROOT',
  'DEVELOPER_DIR',
  'MACOSX_DEPLOYMENT_TARGET',
]);

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

export function artifactRole(relativePath) {
  const lower = relativePath.toLowerCase();
  if (lower.endsWith('.dmg') || lower.endsWith('.zip') || lower.endsWith('.exe')) {
    return 'installer';
  }
  if (lower.endsWith('.deb') || lower.endsWith('.rpm') || lower.endsWith('.appimage')) {
    return 'installer';
  }
  return 'supporting';
}

export function createArtifactManifest({ metadata, files, generatedAt, commands, evidence }) {
  return {
    schemaVersion: 1,
    protocol: ARTIFACT_MANIFEST_PROTOCOL,
    generatedAt,
    release: metadata.release,
    app: metadata.app,
    source: metadata.source,
    catalog: metadata.catalog,
    toolchain: metadata.toolchain,
    validation: {
      cleanCheckout: metadata.source.dirty === false,
      commands,
      packagedE2eEvidence: evidence.e2e ?? null,
      performanceEvidence: evidence.performance ?? null,
      formalCandidateEligible:
        metadata.release.channel === 'candidate' &&
        metadata.source.dirty === false &&
        evidence.e2e !== null &&
        evidence.performance !== null,
    },
    artifacts: files.map((file) => ({
      path: file.path,
      bytes: file.bytes,
      role: artifactRole(file.path),
    })),
    sbom: {
      protocol: SBOM_PROTOCOL,
      path: 'sbom.cdx.json',
    },
  };
}

export function createNativeBuildEnvironment(sourceEnvironment = process.env) {
  const environment = {};
  for (const key of NATIVE_BUILD_ENV_KEYS) {
    const value = sourceEnvironment[key];
    if (typeof value === 'string') {
      environment[key] = value;
    }
  }
  environment.npm_config_loglevel = 'error';
  return environment;
}

function main() {
  const { values } = parseArgs({
    options: {
      version: { type: 'string' },
      'build-number': { type: 'string' },
      output: { type: 'string', default: 'release-artifacts' },
      platform: { type: 'string', default: 'darwin' },
      arch: { type: 'string', default: 'arm64' },
      'skip-checks': { type: 'boolean', default: false },
      'formal-candidate': { type: 'boolean', default: false },
      'e2e-evidence': { type: 'string' },
      'perf-evidence': { type: 'string' },
    },
  });
  const version = validateSemver(values.version ?? '');
  const buildNumber = values['build-number'];
  if (buildNumber === undefined || !/^\d+$/.test(buildNumber) || Number(buildNumber) <= 0) {
    throw new Error(`必须提供大于 0 的 --build-number：${String(buildNumber)}`);
  }
  const formalCandidate = values['formal-candidate'] === true;
  const e2eEvidence = nonEmpty(values['e2e-evidence']);
  const performanceEvidence = nonEmpty(values['perf-evidence']);
  if (formalCandidate && (e2eEvidence === null || performanceEvidence === null)) {
    throw new Error('formal candidate 必须同时提供 --e2e-evidence 和 --perf-evidence。');
  }

  const environment = {
    ...process.env,
    COCHELPER_RELEASE_CHANNEL: formalCandidate ? 'candidate' : 'pre-cutover',
    COCHELPER_RELEASE_VERSION: version,
    COCHELPER_BUILD_NUMBER: buildNumber,
    ...(e2eEvidence === null ? {} : { COCHELPER_RELEASE_E2E_EVIDENCE: e2eEvidence }),
    ...(performanceEvidence === null
      ? {}
      : { COCHELPER_RELEASE_PERF_EVIDENCE: performanceEvidence }),
  };
  const metadata = readReleaseMetadata(root, environment);
  assertReleaseSourceClean(metadata);

  const outputDirectory = resolveOutputDirectory(values.output, version, buildNumber);
  rmSync(outputDirectory, { recursive: true, force: true });
  mkdirSync(outputDirectory, { recursive: true });

  const commands = [];
  if (values['skip-checks'] !== true) {
    runStep(root, environment, 'pnpm install --frozen-lockfile', ['install', '--frozen-lockfile']);
    commands.push('pnpm install --frozen-lockfile');
    for (const command of [
      'format',
      'lint',
      'typecheck',
      'test',
      'check:renderer-isolation',
      'check:secrets',
    ]) {
      runStep(root, environment, `pnpm ${command}`, [command]);
      commands.push(`pnpm ${command}`);
    }
  }
  prepareDmgNativeDependency(root, environment, values.platform, commands);
  const makeArgs = ['make', `--platform=${values.platform}`, `--arch=${values.arch}`];
  const forgeOutput = path.join(root, 'apps/desktop/out/make');
  rmSync(forgeOutput, { recursive: true, force: true });
  runStep(root, environment, `pnpm ${makeArgs.join(' ')}`, makeArgs);
  commands.push(`pnpm ${makeArgs.join(' ')}`);

  const sourceAfterBuild = readReleaseMetadata(root, environment);
  assertReleaseSourceClean(sourceAfterBuild);
  if (sourceAfterBuild.source.commitSha !== metadata.source.commitSha) {
    throw new Error('构建期间源码 commit 发生变化，拒绝生成候选制品。');
  }

  const copiedFiles = copyFiles(forgeOutput, path.join(outputDirectory, 'artifacts'));
  if (copiedFiles.length === 0) {
    throw new Error(`Forge make 没有生成制品：${forgeOutput}`);
  }
  const dependencyTree = readProductionDependencyTree(root);
  const sbom = buildCycloneDxBom({
    metadata,
    dependencyTree,
    resolvedElectronVersion: readResolvedElectronVersion(root),
  });
  writeJson(path.join(outputDirectory, 'release-manifest.json'), {
    ...metadata,
    validation: {
      cleanCheckout: metadata.source.dirty === false,
      formalCandidateRequested: formalCandidate,
      packagedE2eEvidence: e2eEvidence,
      performanceEvidence,
    },
  });
  writeJson(path.join(outputDirectory, 'sbom.cdx.json'), sbom);
  writeJson(
    path.join(outputDirectory, 'artifact-manifest.json'),
    createArtifactManifest({
      metadata,
      files: copiedFiles,
      generatedAt: new Date().toISOString(),
      commands,
      evidence: { e2e: e2eEvidence, performance: performanceEvidence },
    }),
  );
  process.stdout.write(`COCHELPER_RELEASE_PREPARED ${outputDirectory}\n`);
}

function nonEmpty(value) {
  const trimmed = value?.trim();
  return trimmed === undefined || trimmed.length === 0 ? null : trimmed;
}

function resolveOutputDirectory(value, version, buildNumber) {
  const requested = value ?? 'release-artifacts';
  const absolute = path.resolve(root, requested);
  if (absolute === root || absolute === path.join(root, '.git')) {
    throw new Error(`release output 不能覆盖仓库根目录：${absolute}`);
  }
  return value === undefined || value === 'release-artifacts'
    ? path.join(absolute, `${version}-${buildNumber}`)
    : absolute;
}

function runStep(cwd, environment, label, args) {
  runExecutable(cwd, environment, label, 'pnpm', args);
}

function prepareDmgNativeDependency(cwd, environment, platform, commands) {
  if (platform !== 'darwin') {
    return;
  }
  const nodeGyp = path.join(cwd, 'node_modules/.bin/node-gyp');
  if (!existsSync(nodeGyp)) {
    throw new Error('macOS DMG 构建需要 node-gyp；依赖安装不完整。');
  }
  const nativeBuildEnvironment = createNativeBuildEnvironment(environment);
  for (const dependency of [
    { name: 'macos-alias', output: 'build/Release/volume.node' },
    { name: 'fs-xattr', output: 'build/Release/xattr.node' },
  ]) {
    const dependencyRoot = path.join(cwd, 'node_modules', dependency.name);
    if (!existsSync(dependencyRoot)) {
      throw new Error(`macOS DMG 构建需要 ${dependency.name}；依赖安装不完整。`);
    }
    runExecutable(
      dependencyRoot,
      nativeBuildEnvironment,
      `node-gyp rebuild ${dependency.name}（DMG maker 原生依赖）`,
      nodeGyp,
      ['rebuild'],
    );
    if (!existsSync(path.join(dependencyRoot, dependency.output))) {
      throw new Error(`${dependency.name} native binding 构建后仍缺失：${dependency.output}`);
    }
    commands.push(`node_modules/.bin/node-gyp rebuild (${dependency.name})`);
  }
}

function runExecutable(cwd, environment, label, executable, args) {
  process.stdout.write(`\n== ${label} ==\n`);
  const result = spawnSync(executable, args, { cwd, env: environment, stdio: 'inherit' });
  if (result.status !== 0) {
    throw new Error(`${label} 失败，exit=${String(result.status)}`);
  }
}

function copyFiles(sourceRoot, destinationRoot) {
  const files = [];
  if (!statIfExists(sourceRoot)?.isDirectory()) {
    return files;
  }
  const visit = (current, relative = '') => {
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      const sourcePath = path.join(current, entry.name);
      const childRelative = path.posix.join(relative.split(path.sep).join('/'), entry.name);
      if (entry.isDirectory()) {
        visit(sourcePath, childRelative);
        continue;
      }
      if (!entry.isFile()) {
        continue;
      }
      if (!isPackagedArtifact(childRelative)) {
        continue;
      }
      const destinationPath = path.join(destinationRoot, childRelative);
      mkdirSync(path.dirname(destinationPath), { recursive: true });
      copyFileSync(sourcePath, destinationPath);
      files.push({ path: path.posix.join('artifacts', childRelative), bytes: statSync(sourcePath).size });
    }
  };
  visit(sourceRoot);
  return files.sort((left, right) => left.path.localeCompare(right.path));
}

function isPackagedArtifact(relativePath) {
  const lower = relativePath.toLowerCase();
  return ['.dmg', '.zip', '.exe', '.deb', '.rpm', '.appimage'].some((suffix) =>
    lower.endsWith(suffix),
  );
}

function statIfExists(filePath) {
  try {
    return statSync(filePath);
  } catch {
    return null;
  }
}

function writeJson(filePath, value) {
  writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

if (process.argv[1] !== undefined && pathToFileURL(process.argv[1]).href === import.meta.url) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`release prepare failed: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  }
}
