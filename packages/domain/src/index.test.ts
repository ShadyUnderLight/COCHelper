import { describe, expect, it } from 'vitest';

import * as domain from './index';

describe('@coc-helper/domain placeholder', () => {
  it('尚未导出业务符号', () => {
    expect(Object.keys(domain)).toEqual([]);
  });
});
