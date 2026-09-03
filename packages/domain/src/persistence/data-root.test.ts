import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import {
  ELECTRON_DATA_ROOT_NAME,
  resolveElectronDataRoot,
  resolveElectronPersistencePaths,
} from './data-root';

describe('electron data root', () => {
  it('使用新的 COCHelperElectron 根而非旧 COCHelper', () => {
    const root = resolveElectronDataRoot('/tmp/home');
    expect(root).toContain(ELECTRON_DATA_ROOT_NAME);
    expect(root).not.toMatch(/Application Support\/COCHelper$/);
    const paths = resolveElectronPersistencePaths('/tmp/home');
    expect(paths?.villages).toBe(join(root!, 'villages-v1.json'));
    expect(paths?.snapshotHistory).toBe(join(root!, 'snapshot-history-v1.json'));
    expect(paths?.manualTracker).toBe(join(root!, 'manual-tracker-v1.json'));
    expect(paths?.apiTokenEncrypted).toBe(join(root!, 'api-token.enc'));
    expect(paths?.clans).toBe(join(root!, 'clans-v1.json'));
    expect(paths?.trackedClans).toBe(join(root!, 'tracked-clans-v1.json'));
    expect(paths?.playerStates).toBe(join(root!, 'player-states-v1.json'));
    expect(paths?.selection).toBe(join(root!, 'selection-v1.json'));
  });
});
