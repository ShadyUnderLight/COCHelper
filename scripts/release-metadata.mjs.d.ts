export const RELEASE_MANIFEST_PROTOCOL: string;
export const RELEASE_CHANNELS: readonly string[];

export type ReleaseMetadata = {
  readonly schemaVersion: number;
  readonly protocol: string;
  readonly release: {
    readonly channel: string;
    readonly version: string;
    readonly buildNumber: string;
  };
  readonly app: {
    readonly name: string;
    readonly productName: string;
    readonly version: string;
    readonly buildNumber: string;
  };
  readonly source: {
    readonly commitSha: string;
    readonly dirty: boolean;
    readonly untrackedInputs: readonly string[];
  };
  readonly catalog: {
    readonly version: string;
    readonly schemaVersion: number;
    readonly gameVersion: string;
    readonly buildTag: string;
    readonly locale: string;
  };
  readonly toolchain: {
    readonly node: string;
    readonly packageManager: string;
    readonly electron: string;
  };
};

export function readReleaseMetadata(
  repoRoot: string,
  environment?: NodeJS.ProcessEnv,
  provenanceReader?: (repoRoot: string) => ReleaseMetadata['source'],
): ReleaseMetadata;
export function validateSemver(value: string): string;
export function parseBuildNumber(value: string, channel?: string): string;
export function assertReleaseSourceClean(metadata: ReleaseMetadata): ReleaseMetadata;
export function readCatalogManifest(repoRoot: string, requestedVersion?: string | null): ReleaseMetadata['catalog'];
export function readResolvedElectronVersion(repoRoot: string): string | null;
