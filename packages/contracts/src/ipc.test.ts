import { describe, expect, it } from 'vitest';

import { APP_HEALTH_CHANNEL, DESKTOP_BRIDGE_KEYS } from './ipc';

describe('@coc-helper/contracts IPC stub', () => {
  it('只登记 app.health 通道', () => {
    expect(APP_HEALTH_CHANNEL).toBe('app.health');
    expect(DESKTOP_BRIDGE_KEYS).toEqual(['health']);
  });
});
