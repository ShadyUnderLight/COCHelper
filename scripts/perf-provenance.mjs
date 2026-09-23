import { execFileSync } from 'node:child_process';

const INPUT_PATHS = [
  'apps',
  'packages',
  'scripts',
  'fixtures',
  'e2e/fixtures',
  ':(exclude)apps/**/node_modules/**',
  ':(exclude)packages/**/node_modules/**',
  ':(exclude)apps/desktop/out/**',
  ':(exclude)apps/desktop/.webpack/**',
];

export function provenanceFromGitOutputs({ commitSha, statusOutput, untrackedInputs }) {
  const normalizedUntrackedInputs = [...new Set(untrackedInputs)].sort();
  return {
    commitSha,
    dirty: statusOutput.trim().length > 0 || normalizedUntrackedInputs.length > 0,
    untrackedInputs: normalizedUntrackedInputs,
  };
}

export function readGitProvenance(repoRoot) {
  let commitSha = 'unknown';
  let statusOutput = '';
  let untrackedInputs = [];
  try {
    commitSha = execFileSync('git', ['rev-parse', 'HEAD'], {
      cwd: repoRoot,
      encoding: 'utf8',
    }).trim();
  } catch {
    // Preserve the unknown commit while still trying to report untracked inputs.
  }
  try {
    statusOutput = execFileSync('git', ['status', '--porcelain=v1', '--untracked-files=all'], {
      cwd: repoRoot,
      encoding: 'utf8',
    });
  } catch {
    statusOutput = 'git status failed';
  }
  try {
    const raw = execFileSync(
      'git',
      ['ls-files', '--others', '--full-name', '--', ...INPUT_PATHS],
      { cwd: repoRoot, encoding: 'utf8' },
    );
    untrackedInputs = raw.split('\n').filter((value) => value.length > 0);
  } catch {
    untrackedInputs = ['git ls-files failed'];
  }
  return provenanceFromGitOutputs({ commitSha, statusOutput, untrackedInputs });
}
