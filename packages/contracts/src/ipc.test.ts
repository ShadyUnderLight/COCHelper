import { describe, expect, it } from 'vitest';

import {
  APP_HEALTH_CHANNEL,
  APP_IPC_BRIDGE_KEYS,
  APP_IPC_CHANNELS,
  APP_SNAPSHOT_CHANNEL,
  DESKTOP_BRIDGE_KEYS,
  IMPORT_COMMIT_CHANNEL,
  IMPORT_DISCARD_CHANNEL,
  IMPORT_PREPARE_CHANNEL,
  MANUAL_ADJUST_CHANNEL,
  MANUAL_CANCEL_CHANNEL,
  MANUAL_IPC_BRIDGE_KEYS,
  MANUAL_IPC_CHANNELS,
  MANUAL_RECONCILE_CHANNEL,
  MANUAL_SETTLE_CHANNEL,
  MANUAL_START_CHANNEL,
  MANUAL_STATE_CHANNEL,
  OFFICIAL_IPC_BRIDGE_KEYS,
  OFFICIAL_IPC_CHANNELS,
  PLAYER_STATE_CHANNEL,
  CLAN_STATE_CHANNEL,
  CLAN_WAR_STATE_CHANNEL,
  WAR_LOG_STATE_CHANNEL,
  CAPITAL_RAID_STATE_CHANNEL,
  API_REFRESH_CHANNEL,
  WAR_LOG_LOAD_MORE_CHANNEL,
  CAPITAL_RAID_LOAD_MORE_CHANNEL,
  OPERATION_PROGRESS_CHANNEL,
  PROJECTION_IPC_BRIDGE_KEYS,
  PROJECTION_IPC_CHANNELS,
  RECOVERY_EXPORT_CHANNEL,
  RECOVERY_IPC_BRIDGE_KEYS,
  RECOVERY_IPC_CHANNELS,
  RECOVERY_RECOVER_JOURNAL_CHANNEL,
  RECOVERY_RESET_CHANNEL,
  RECOVERY_RESTORE_CHANNEL,
  RECOVERY_RESTORE_SAVED_CHANNEL,
  RECOVERY_STATUS_CHANNEL,
  REQUEST_CANCEL_CHANNEL,
  REQUEST_ID_MAX_LENGTH,
  STATE_CHANGED_CHANNEL,
  UPGRADE_OVERVIEW_CHANNEL,
  VILLAGE_DETAIL_CHANNEL,
  VILLAGE_SELECT_CHANNEL,
  isCancelRequest,
  isRequestId,
} from './ipc';

describe('@coc-helper/contracts IPC', () => {
  it('登记 health、cancel 与 E3-02 业务通道', () => {
    expect(APP_HEALTH_CHANNEL).toBe('app.health');
    expect(REQUEST_CANCEL_CHANNEL).toBe('request.cancel');
    expect(APP_SNAPSHOT_CHANNEL).toBe('app.snapshot');
    expect(VILLAGE_SELECT_CHANNEL).toBe('village.select');
    expect(IMPORT_PREPARE_CHANNEL).toBe('import.prepare');
    expect(IMPORT_COMMIT_CHANNEL).toBe('import.commit');
    expect(IMPORT_DISCARD_CHANNEL).toBe('import.discard');
    expect(STATE_CHANGED_CHANNEL).toBe('state.changed');
    expect(UPGRADE_OVERVIEW_CHANNEL).toBe('upgrade.overview');
    expect(VILLAGE_DETAIL_CHANNEL).toBe('village.detail');
    expect(PLAYER_STATE_CHANNEL).toBe('player.state');
    expect(CLAN_STATE_CHANNEL).toBe('clan.state');
    expect(CLAN_WAR_STATE_CHANNEL).toBe('clanWar.state');
    expect(WAR_LOG_STATE_CHANNEL).toBe('warLog.state');
    expect(CAPITAL_RAID_STATE_CHANNEL).toBe('capitalRaid.state');
    expect(API_REFRESH_CHANNEL).toBe('api.refresh');
    expect(WAR_LOG_LOAD_MORE_CHANNEL).toBe('warLog.loadMore');
    expect(CAPITAL_RAID_LOAD_MORE_CHANNEL).toBe('capitalRaid.loadMore');
    expect(OPERATION_PROGRESS_CHANNEL).toBe('operation.progress');
    expect(RECOVERY_STATUS_CHANNEL).toBe('recovery.status');
    expect(RECOVERY_EXPORT_CHANNEL).toBe('recovery.export');
    expect(RECOVERY_RESTORE_CHANNEL).toBe('recovery.restore');
    expect(RECOVERY_RESTORE_SAVED_CHANNEL).toBe('recovery.restoreSaved');
    expect(RECOVERY_RESET_CHANNEL).toBe('recovery.reset');
    expect(RECOVERY_RECOVER_JOURNAL_CHANNEL).toBe('recovery.recoverJournal');
    expect(REQUEST_ID_MAX_LENGTH).toBe(128);
    expect(APP_IPC_CHANNELS).toEqual([
      APP_SNAPSHOT_CHANNEL,
      VILLAGE_SELECT_CHANNEL,
      IMPORT_PREPARE_CHANNEL,
      IMPORT_COMMIT_CHANNEL,
      IMPORT_DISCARD_CHANNEL,
      STATE_CHANGED_CHANNEL,
    ]);
    expect(PROJECTION_IPC_CHANNELS).toEqual([UPGRADE_OVERVIEW_CHANNEL, VILLAGE_DETAIL_CHANNEL]);
    expect(MANUAL_IPC_CHANNELS).toEqual([
      MANUAL_STATE_CHANNEL,
      MANUAL_START_CHANNEL,
      MANUAL_CANCEL_CHANNEL,
      MANUAL_ADJUST_CHANNEL,
      MANUAL_SETTLE_CHANNEL,
      MANUAL_RECONCILE_CHANNEL,
    ]);
    expect(OFFICIAL_IPC_CHANNELS).toEqual([
      PLAYER_STATE_CHANNEL,
      CLAN_STATE_CHANNEL,
      CLAN_WAR_STATE_CHANNEL,
      WAR_LOG_STATE_CHANNEL,
      CAPITAL_RAID_STATE_CHANNEL,
      API_REFRESH_CHANNEL,
      WAR_LOG_LOAD_MORE_CHANNEL,
      CAPITAL_RAID_LOAD_MORE_CHANNEL,
      OPERATION_PROGRESS_CHANNEL,
    ]);
    expect(RECOVERY_IPC_CHANNELS).toEqual([
      RECOVERY_STATUS_CHANNEL,
      RECOVERY_EXPORT_CHANNEL,
      RECOVERY_RESTORE_CHANNEL,
      RECOVERY_RESTORE_SAVED_CHANNEL,
      RECOVERY_RESET_CHANNEL,
      RECOVERY_RECOVER_JOURNAL_CHANNEL,
    ]);
    const appKeysWithoutEvent = APP_IPC_BRIDGE_KEYS.filter((key) => key !== 'onStateChanged');
    const officialKeysWithoutEvent = OFFICIAL_IPC_BRIDGE_KEYS.filter(
      (key) => key !== 'onOperationProgress',
    );
    expect(DESKTOP_BRIDGE_KEYS).toEqual([
      'health',
      'cancel',
      ...appKeysWithoutEvent,
      ...PROJECTION_IPC_BRIDGE_KEYS,
      ...MANUAL_IPC_BRIDGE_KEYS,
      ...officialKeysWithoutEvent,
      ...RECOVERY_IPC_BRIDGE_KEYS,
      'onOperationProgress',
      'onStateChanged',
    ]);
  });

  it('只接受可打印、有限长度的 requestId DTO', () => {
    expect(isRequestId('request-1')).toBe(true);
    expect(isRequestId('')).toBe(false);
    expect(isRequestId('x'.repeat(REQUEST_ID_MAX_LENGTH + 1))).toBe(false);
    expect(isRequestId('request\n1')).toBe(false);
    expect(isCancelRequest({ requestId: 'request-1' })).toBe(true);
    expect(isCancelRequest({ requestId: 'request-1', extra: true })).toBe(false);
    expect(isCancelRequest(Object.create(null))).toBe(false);
  });
});
