import { execFileSync } from 'node:child_process';

export const SBOM_PROTOCOL = 'cochelper-cyclonedx-sbom-v1';

export function readProductionDependencyTree(repoRoot) {
  const output = execFileSync(
    'pnpm',
    [
      '--reporter=silent',
      'list',
      '--filter',
      '@coc-helper/desktop',
      '--prod',
      '--depth',
      'Infinity',
      '--json',
    ],
    { cwd: repoRoot, encoding: 'utf8' },
  );
  try {
    const parsed = JSON.parse(output);
    const root = Array.isArray(parsed) ? parsed[0] : null;
    if (root === null || typeof root !== 'object') {
      throw new Error('pnpm list 没有返回 desktop dependency tree');
    }
    return root;
  } catch (error) {
    throw new Error('无法解析 pnpm production dependency tree。', { cause: error });
  }
}

export function buildCycloneDxBom({ metadata, dependencyTree, resolvedElectronVersion = null }) {
  const components = new Map();
  const addComponent = (name, rawVersion, source = 'registry') => {
    if (typeof name !== 'string' || name.length === 0 || typeof rawVersion !== 'string') {
      return;
    }
    const version = rawVersion.startsWith('link:') ? '0.0.0' : rawVersion;
    const key = `${name}@${version}`;
    if (components.has(key)) {
      return;
    }
    const scope = name.startsWith('@') ? name.slice(1).split('/')[0] : null;
    const packageName = scope === null ? name : name.slice(scope.length + 2);
    components.set(key, {
      type: 'library',
      ...(scope === null ? {} : { group: scope }),
      name: packageName,
      version,
      purl: `pkg:npm/${scope === null ? packageName : `%40${scope}/${packageName}`}@${version}`,
      properties: [{ name: 'cochelper:source', value: source }],
    });
  };

  const visit = (node) => {
    if (node === null || typeof node !== 'object') {
      return;
    }
    const dependencies = node.dependencies;
    if (dependencies === null || typeof dependencies !== 'object') {
      return;
    }
    for (const [name, dependency] of Object.entries(dependencies)) {
      if (dependency === null || typeof dependency !== 'object') {
        continue;
      }
      const source = typeof dependency.version === 'string' && dependency.version.startsWith('link:')
        ? 'workspace'
        : 'registry';
      addComponent(name, dependency.version, source);
      visit(dependency);
    }
  };
  visit(dependencyTree);

  if (resolvedElectronVersion !== null) {
    addComponent('electron', resolvedElectronVersion, 'runtime');
  }

  return {
    bomFormat: 'CycloneDX',
    specVersion: '1.5',
    version: 1,
    metadata: {
      component: {
        type: 'application',
        name: metadata.app.productName,
        version: metadata.app.version,
        'bom-ref': `application:${metadata.app.productName}@${metadata.app.version}`,
      },
    },
    components: [...components.values()].sort((left, right) => {
      const leftKey = `${left.group ?? ''}/${left.name}@${left.version}`;
      const rightKey = `${right.group ?? ''}/${right.name}@${right.version}`;
      return leftKey.localeCompare(rightKey);
    }),
  };
}
