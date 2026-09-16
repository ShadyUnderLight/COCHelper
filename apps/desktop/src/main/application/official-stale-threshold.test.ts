import { describe, expect, it } from 'vitest';

import { OFFICIAL_STALE_THRESHOLD_MS as CONTRACTS_STALE_THRESHOLD_MS } from '@coc-helper/contracts';
import { OFFICIAL_STALE_THRESHOLD_MS as DOMAIN_STALE_THRESHOLD_MS } from '@coc-helper/domain';

describe('official stale threshold 边界', () => {
  it('contracts 与 domain 的 OFFICIAL_STALE_THRESHOLD_MS 同值', () => {
    expect(CONTRACTS_STALE_THRESHOLD_MS).toBe(DOMAIN_STALE_THRESHOLD_MS);
    expect(CONTRACTS_STALE_THRESHOLD_MS).toBe(24 * 3600 * 1000);
  });
});
