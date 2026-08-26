import { describe, expect, it } from 'vitest';

import * as wire from './index';

describe('@coc-helper/wire placeholder', () => {
  it('尚未导出业务符号', () => {
    expect(Object.keys(wire)).toEqual([]);
  });
});
