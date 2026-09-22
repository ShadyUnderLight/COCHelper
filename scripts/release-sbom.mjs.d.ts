export const SBOM_PROTOCOL: string;

export function readProductionDependencyTree(repoRoot: string): Record<string, unknown>;
export function buildCycloneDxBom(input: {
  readonly metadata: {
    readonly app: { readonly productName: string; readonly version: string };
  };
  readonly dependencyTree: Record<string, unknown>;
  readonly resolvedElectronVersion?: string | null;
}): Record<string, unknown>;
