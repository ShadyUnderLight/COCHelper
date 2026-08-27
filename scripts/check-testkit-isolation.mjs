#!/usr/bin/env node
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ts = createRequire(import.meta.url)('typescript');

const defaultRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FORBIDDEN_PACKAGE = '@coc-helper/testkit';
const PACKAGED_MARKERS = [FORBIDDEN_PACKAGE, 'packages/testkit', 'COCHELPER_SWIFT_ORACLE', 'golden-oracle'];
const WORKSPACE_PACKAGES = {
  '@coc-helper/testkit': 'packages/testkit',
  '@coc-helper/wire': 'packages/wire',
  '@coc-helper/domain': 'packages/domain',
  '@coc-helper/contracts': 'packages/contracts',
  '@coc-helper/desktop': 'apps/desktop',
};

const PRODUCTION_TREES = [
  'apps/desktop/src',
  'packages/wire/src',
  'packages/domain/src',
  'packages/contracts/src',
];

const PRODUCTION_ENTRIES = [
  'apps/desktop/src/main/index.ts',
  'apps/desktop/src/preload/index.ts',
  'apps/desktop/src/renderer/index.ts',
  'packages/wire/src/index.ts',
  'packages/domain/src/index.ts',
  'packages/contracts/src/index.ts',
];

function walk(dir) {
  if (!existsSync(dir)) {
    return [];
  }
  const out = [];
  for (const entry of readdirSync(dir)) {
    if (entry === 'node_modules' || (entry.startsWith('.') && entry !== '.webpack')) {
      continue;
    }
    const full = path.join(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) {
      out.push(...walk(full));
    } else {
      out.push(full);
    }
  }
  return out;
}

export function extractImportSpecifiers(text, fileName = 'module.ts') {
  return collectModuleLoads(text, fileName)
    .filter((item) => item.kind === 'specifier')
    .map((item) => item.value);
}

export function extractUnsafeDynamicLoads(text, fileName = 'module.ts') {
  return collectModuleLoads(text, fileName)
    .filter((item) => item.kind === 'unsafe')
    .map((item) => item.reason);
}

function collectModuleLoads(text, fileName) {
  const sourceFile = ts.createSourceFile(
    fileName,
    text,
    ts.ScriptTarget.Latest,
    true,
    scriptKindFor(fileName),
  );
  const factories = new Set();
  const requirers = new Set(['require']);

  const seedImports = (node) => {
    if (
      ts.isImportDeclaration(node) &&
      node.importClause?.namedBindings &&
      ts.isNamedImports(node.importClause.namedBindings)
    ) {
      const spec = stringLiteralText(node.moduleSpecifier);
      if (spec === 'node:module' || spec === 'module') {
        for (const element of node.importClause.namedBindings.elements) {
          const imported = (element.propertyName ?? element.name).text;
          if (imported === 'createRequire') {
            factories.add(element.name.text);
          }
        }
      }
    }
    ts.forEachChild(node, seedImports);
  };

  const classifyCallee = (expr) => {
    if (ts.isIdentifier(expr)) {
      if (factories.has(expr.text)) {
        return 'factory';
      }
      if (requirers.has(expr.text)) {
        return 'requirer';
      }
      return null;
    }
    if (ts.isPropertyAccessExpression(expr) && ts.isIdentifier(expr.name)) {
      if (expr.name.text === 'createRequire') {
        return 'factory';
      }
      if (expr.name.text === 'require') {
        return 'requirer';
      }
    }
    if (ts.isCallExpression(expr) && classifyCallee(expr.expression) === 'factory') {
      return 'requirer';
    }
    return null;
  };

  const classifyExpr = (expr) => {
    if (ts.isIdentifier(expr)) {
      if (factories.has(expr.text)) {
        return 'factory';
      }
      if (requirers.has(expr.text)) {
        return 'requirer';
      }
      return null;
    }
    if (ts.isCallExpression(expr) && classifyCallee(expr.expression) === 'factory') {
      return 'requirer';
    }
    return classifyCallee(expr);
  };

  const bindNode = (node) => {
    if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name) && node.initializer) {
      const kind = classifyExpr(node.initializer);
      if (kind === 'factory') {
        factories.add(node.name.text);
      }
      if (kind === 'requirer') {
        requirers.add(node.name.text);
      }
    }
    if (
      ts.isBinaryExpression(node) &&
      node.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
      ts.isIdentifier(node.left)
    ) {
      const kind = classifyExpr(node.right);
      if (kind === 'factory') {
        factories.add(node.left.text);
      }
      if (kind === 'requirer') {
        requirers.add(node.left.text);
      }
    }
    ts.forEachChild(node, bindNode);
  };

  seedImports(sourceFile);
  let previous = -1;
  while (previous !== factories.size + requirers.size) {
    previous = factories.size + requirers.size;
    bindNode(sourceFile);
  }

  const loads = [];
  const visit = (node) => {
    loads.push(...loadsFromNode(node, classifyCallee));
    ts.forEachChild(node, visit);
  };
  visit(sourceFile);
  return loads;
}

function loadsFromNode(node, classifyCallee) {
  const loads = [];
  if (ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) {
    const specifier = stringLiteralText(node.moduleSpecifier);
    if (specifier !== null) {
      loads.push({ kind: 'specifier', value: specifier });
    }
    return loads;
  }
  if (ts.isImportEqualsDeclaration(node) && ts.isExternalModuleReference(node.moduleReference)) {
    const specifier = stringLiteralText(node.moduleReference.expression);
    if (specifier !== null) {
      loads.push({ kind: 'specifier', value: specifier });
    } else {
      loads.push({ kind: 'unsafe', reason: '非字面量 import =' });
    }
    return loads;
  }
  if (ts.isImportTypeNode(node) && ts.isLiteralTypeNode(node.argument)) {
    const specifier = stringLiteralText(node.argument.literal);
    if (specifier !== null) {
      loads.push({ kind: 'specifier', value: specifier });
    }
    return loads;
  }
  if (ts.isCallExpression(node)) {
    if (node.expression.kind === ts.SyntaxKind.ImportKeyword) {
      const specifier = stringLiteralText(node.arguments[0]);
      if (specifier !== null) {
        loads.push({ kind: 'specifier', value: specifier });
      } else {
        loads.push({ kind: 'unsafe', reason: '非字面量 import()' });
      }
      return loads;
    }
    const kind = classifyCallee(node.expression);
    if (kind === 'factory') {
      loads.push({ kind: 'unsafe', reason: 'createRequire()' });
      return loads;
    }
    if (kind === 'requirer') {
      const specifier = stringLiteralText(node.arguments[0]);
      if (specifier !== null) {
        loads.push({ kind: 'specifier', value: specifier });
      } else {
        loads.push({ kind: 'unsafe', reason: '非字面量 require()' });
      }
      return loads;
    }
  }
  return loads;
}

function scriptKindFor(fileName) {
  if (fileName.endsWith('.tsx')) {
    return ts.ScriptKind.TSX;
  }
  if (fileName.endsWith('.jsx')) {
    return ts.ScriptKind.JSX;
  }
  if (fileName.endsWith('.mts') || fileName.endsWith('.cts') || fileName.endsWith('.ts')) {
    return ts.ScriptKind.TS;
  }
  return ts.ScriptKind.JS;
}

function stringLiteralText(node) {
  if (!node) {
    return null;
  }
  if (ts.isStringLiteralLike(node)) {
    return node.text;
  }
  return null;
}

export function isTestkitPackageSpecifier(specifier) {
  return specifier === FORBIDDEN_PACKAGE || specifier.startsWith(`${FORBIDDEN_PACKAGE}/`);
}

function posixRelative(root, absolute) {
  return path.relative(root, absolute).split(path.sep).join('/');
}

export function isTestkitArchivePath(posix) {
  const normalized = posix.split(path.sep).join('/');
  return (
    normalized.includes('packages/testkit') ||
    normalized.includes('node_modules/@coc-helper/testkit') ||
    /(?:^|\/)@coc-helper\/testkit(?:\/|$)/.test(normalized)
  );
}

export function isTestkitFilesystemPath(absolute, workspaceRoot = defaultRoot) {
  const testkitRoot = path.resolve(workspaceRoot, 'packages/testkit');
  const resolved = path.resolve(absolute);
  return resolved === testkitRoot || resolved.startsWith(`${testkitRoot}${path.sep}`);
}

function resolveExistingFile(base) {
  const candidates = [base, `${base}.ts`, `${base}.js`, path.join(base, 'index.ts'), path.join(base, 'index.js')];
  for (const candidate of candidates) {
    if (existsSync(candidate) && statSync(candidate).isFile()) {
      return path.resolve(candidate);
    }
  }
  return path.resolve(base);
}

export function resolveWorkspaceSpecifier(fromRelative, specifier, workspaceRoot = defaultRoot) {
  if (isTestkitPackageSpecifier(specifier) || specifier.split(path.sep).join('/').includes('packages/testkit/')) {
    if (specifier.startsWith('.')) {
      return resolveExistingFile(path.join(workspaceRoot, path.dirname(fromRelative), specifier));
    }
    const rest = specifier.slice(FORBIDDEN_PACKAGE.length).replace(/^\//, '');
    const pkgRoot = path.join(workspaceRoot, WORKSPACE_PACKAGES[FORBIDDEN_PACKAGE]);
    return resolveExistingFile(rest ? path.join(pkgRoot, rest) : path.join(pkgRoot, 'src/index.ts'));
  }

  const names = Object.keys(WORKSPACE_PACKAGES).sort((left, right) => right.length - left.length);
  const matched = names.find((name) => specifier === name || specifier.startsWith(`${name}/`));
  if (matched) {
    const rest = specifier.slice(matched.length).replace(/^\//, '');
    const pkgRoot = path.join(workspaceRoot, WORKSPACE_PACKAGES[matched]);
    if (rest) {
      return resolveExistingFile(path.join(pkgRoot, rest));
    }
    const manifest = JSON.parse(readFileSync(path.join(pkgRoot, 'package.json'), 'utf8'));
    return resolveExistingFile(path.join(pkgRoot, manifest.main ?? 'src/index.ts'));
  }

  if (specifier.startsWith('.')) {
    return resolveExistingFile(path.join(workspaceRoot, path.dirname(fromRelative), specifier));
  }
  return null;
}

export function findForbiddenImportHits(text, fromRelative, workspaceRoot = defaultRoot) {
  const hits = [];
  for (const specifier of extractImportSpecifiers(text, fromRelative)) {
    if (isTestkitPackageSpecifier(specifier)) {
      hits.push(`${fromRelative} 不得 import ${specifier}`);
      continue;
    }
    const resolved = resolveWorkspaceSpecifier(fromRelative, specifier, workspaceRoot);
    if (resolved && isTestkitFilesystemPath(resolved, workspaceRoot)) {
      hits.push(`${fromRelative} 不得解析到 testkit（via ${specifier}）`);
    }
  }
  for (const reason of extractUnsafeDynamicLoads(text, fromRelative)) {
    hits.push(`${fromRelative} 不得使用无法静态解析的动态加载（${reason}）`);
  }
  return hits;
}

function isProductionSource(relative) {
  if (!/\.(ts|js|mjs|cjs|tsx)$/.test(relative)) {
    return false;
  }
  if (relative.includes('.test.') || relative.endsWith('.test.ts')) {
    return false;
  }
  if (relative.includes('.parity.') || relative.includes('.replay.')) {
    return false;
  }
  return PRODUCTION_TREES.some((tree) => relative === tree || relative.startsWith(`${tree}/`));
}

function packageHits(workspaceRoot) {
  const hits = [];
  const productionManifests = [
    ['apps/desktop/package.json', ['dependencies', 'devDependencies']],
    ['packages/wire/package.json', ['dependencies']],
    ['packages/domain/package.json', ['dependencies']],
    ['packages/contracts/package.json', ['dependencies']],
  ];
  for (const [relative, fields] of productionManifests) {
    const json = JSON.parse(readFileSync(path.join(workspaceRoot, relative), 'utf8'));
    for (const field of fields) {
      if (json[field]?.[FORBIDDEN_PACKAGE]) {
        hits.push(`${relative} ${field} 不得依赖 ${FORBIDDEN_PACKAGE}`);
      }
    }
  }
  return hits;
}

function sourceImportHits(workspaceRoot) {
  const hits = [];
  for (const tree of PRODUCTION_TREES) {
    for (const file of walk(path.join(workspaceRoot, tree))) {
      const relative = posixRelative(workspaceRoot, file);
      if (!isProductionSource(relative)) {
        continue;
      }
      hits.push(
        ...findForbiddenImportHits(readFileSync(file, 'utf8'), relative, workspaceRoot),
      );
    }
  }
  return hits;
}

function productionGraphHits(workspaceRoot) {
  const hits = [];
  const seen = new Set();
  const queue = [...PRODUCTION_ENTRIES];
  while (queue.length > 0) {
    const relative = queue.shift();
    if (seen.has(relative)) {
      continue;
    }
    seen.add(relative);
    const absolute = path.join(workspaceRoot, relative);
    if (!existsSync(absolute) || !statSync(absolute).isFile()) {
      continue;
    }
    if (isTestkitFilesystemPath(absolute, workspaceRoot)) {
      hits.push(`生产入口依赖图到达 testkit：${relative}`);
      continue;
    }
    if (!isProductionSource(relative) && !PRODUCTION_ENTRIES.includes(relative)) {
      continue;
    }
    const text = readFileSync(absolute, 'utf8');
    for (const reason of extractUnsafeDynamicLoads(text, relative)) {
      hits.push(`${relative} 不得使用无法静态解析的动态加载（${reason}）`);
    }
    const specifiers = extractImportSpecifiers(text, relative);
    for (const specifier of specifiers) {
      if (isTestkitPackageSpecifier(specifier)) {
        hits.push(`${relative} 不得 import ${specifier}`);
        continue;
      }
      const resolved = resolveWorkspaceSpecifier(relative, specifier, workspaceRoot);
      if (resolved === null) {
        continue;
      }
      queue.push(posixRelative(workspaceRoot, resolved));
    }
  }
  return hits;
}

function packagedHits(workspaceRoot) {
  const hits = [];
  const outputs = [
    path.join(workspaceRoot, 'apps/desktop/out'),
    path.join(workspaceRoot, 'apps/desktop/.webpack'),
  ];
  for (const dir of outputs) {
    if (!existsSync(dir)) {
      continue;
    }
    for (const file of walk(dir)) {
      const relative = posixRelative(workspaceRoot, file);
      if (file.endsWith('.swift')) {
        hits.push(`发布产物含 Swift 源：${relative}`);
      }
      if (relative.includes('golden-oracle') || isTestkitArchivePath(relative)) {
        hits.push(`发布产物含 golden-oracle / testkit：${relative}`);
      }
      if (file.endsWith('.asar')) {
        hits.push(...scanAsarArchive(file, relative, workspaceRoot));
        continue;
      }
      if (/\.(js|mjs|cjs|json)$/.test(file)) {
        hits.push(...markerHitsInText(readFileSync(file, 'utf8'), relative));
      }
    }
  }
  return hits;
}

export function scanAsarArchive(archivePath, label, workspaceRoot = defaultRoot) {
  const asar = loadAsarModule(workspaceRoot);
  const hits = [];
  const names = asar.listPackage(archivePath, { isPack: false });
  for (const name of names) {
    const posix = String(name).split(path.sep).join('/').replace(/^\//, '');
    if (posix.includes('golden-oracle') || isTestkitArchivePath(posix)) {
      hits.push(`发布产物 ${label} 含 golden-oracle / testkit：${posix}`);
    }
    if (posix.endsWith('.swift')) {
      hits.push(`发布产物 ${label} 含 Swift 源：${posix}`);
    }
    if (!/\.(js|mjs|cjs|json)$/.test(posix)) {
      continue;
    }
    try {
      const text = readAsarFile(asar, archivePath, posix, name);
      hits.push(...markerHitsInText(text, `${label}:${posix}`));
    } catch (error) {
      hits.push(`发布产物 ${label} 无法读取 ${posix}：${error instanceof Error ? error.message : String(error)}`);
    }
  }
  return hits;
}

function readAsarFile(asar, archivePath, posix, originalName) {
  const attempts = [...new Set([posix, String(originalName), `/${posix}`])];
  let lastError = null;
  for (const candidate of attempts) {
    try {
      return asar.extractFile(archivePath, candidate).toString('utf8');
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError ?? new Error(`无法读取 ${posix}`);
}

function markerHitsInText(text, label) {
  const hits = [];
  for (const marker of PACKAGED_MARKERS) {
    if (text.includes(marker)) {
      hits.push(`发布产物含 ${marker}：${label}`);
      break;
    }
  }
  return hits;
}

function loadAsarModule(workspaceRoot) {
  const fromDesktop = path.join(workspaceRoot, 'apps/desktop/package.json');
  const fromRoot = path.join(workspaceRoot, 'package.json');
  for (const manifest of [fromDesktop, fromRoot]) {
    try {
      return createRequire(manifest)('@electron/asar');
    } catch {
      continue;
    }
  }
  throw new Error('无法加载 @electron/asar，无法检查 app.asar');
}

export function collectTestkitIsolationHits(workspaceRoot = defaultRoot) {
  return [
    ...packageHits(workspaceRoot),
    ...sourceImportHits(workspaceRoot),
    ...productionGraphHits(workspaceRoot),
    ...packagedHits(workspaceRoot),
  ];
}

const invokedDirectly =
  process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  const hits = collectTestkitIsolationHits();
  if (hits.length > 0) {
    console.error('testkit / oracle 隔离检查失败:');
    for (const hit of hits) {
      console.error(`- ${hit}`);
    }
    process.exit(1);
  }
  console.log('testkit / oracle 隔离检查通过');
}
