import { describe, expect, it } from 'vitest';

import { provenanceFromGitOutputs } from './perf-provenance.mjs';

describe('perf provenance', () => {
  it('普通 dirty 状态会使 provenance dirty', () => {
    expect(
      provenanceFromGitOutputs({
        commitSha: 'current',
        statusOutput: ' M apps/desktop/src/main/index.ts\n',
        untrackedInputs: [],
      }),
    ).toMatchObject({ commitSha: 'current', dirty: true, untrackedInputs: [] });
  });

  it('未跟踪 fixture/source 输入会使 provenance dirty', () => {
    expect(
      provenanceFromGitOutputs({
        commitSha: 'current',
        statusOutput: '',
        untrackedInputs: ['e2e/fixtures/perf-new.json', 'apps/desktop/src/generated.ts'],
      }),
    ).toMatchObject({
      commitSha: 'current',
      dirty: true,
      untrackedInputs: ['apps/desktop/src/generated.ts', 'e2e/fixtures/perf-new.json'],
    });
  });
});
