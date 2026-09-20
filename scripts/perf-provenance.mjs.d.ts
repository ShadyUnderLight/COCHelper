export type PerfProvenance = {
  readonly commitSha: string;
  readonly dirty: boolean;
  readonly untrackedInputs: readonly string[];
};

export function readGitProvenance(repoRoot: string): PerfProvenance;
