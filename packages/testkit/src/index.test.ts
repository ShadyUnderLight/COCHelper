import { describe, expect, it } from 'vitest';

import * as testkit from './index';

describe('@coc-helper/testkit placeholder', () => {
  it('尚未导出业务符号', () => {
    expect(Object.keys(testkit)).toEqual([]);
  });
});
