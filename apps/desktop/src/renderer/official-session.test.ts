import { describe, expect, it } from 'vitest';

import { OFFICIAL_STALE_THRESHOLD_MS } from '@coc-helper/contracts';

import { clanFixture, playerFixture } from './official-session.fixtures';
import { LOADING_RESOURCE, resourceFailure, resourceSuccess } from './resource-state';
import {
  clanAffiliationOf,
  clanRefreshStatusLine,
  clanTypeLabel,
  clockedRefreshStatus,
  officialPlayerSubjectKey,
  officialRefreshStatus,
  officialSourceLabel,
  playerRefreshStatusLine,
  toOfficialClanView,
  toOfficialPlayerView,
  warLogPublicLabel,
} from './official-session';

describe('official-session（#277-E1）', () => {
  it('refreshStatus 七态', () => {
    const now = 1_700_000_000_000;
    expect(officialRefreshStatus('never', false, undefined, now)).toBe('never');
    expect(officialRefreshStatus('loading', false, undefined, now)).toBe('loading');
    expect(officialRefreshStatus('skipped', false, undefined, now)).toBe('skipped');
    expect(officialRefreshStatus('success', true, now, now)).toBe('success');
    expect(officialRefreshStatus('success', true, now - OFFICIAL_STALE_THRESHOLD_MS - 1, now)).toBe(
      'stale',
    );
    expect(officialRefreshStatus('failed', true, now, now)).toBe('failedWithLastGood');
    expect(officialRefreshStatus('failed', false, undefined, now)).toBe('failedWithoutLastGood');
  });

  it('来源标签只在 success / failed-with-last-good 出现', () => {
    expect(officialSourceLabel('success', true)).toBe('官方 API 数据');
    expect(officialSourceLabel('failed', true)).toBe('缓存的官方 API 数据');
    expect(officialSourceLabel('failed', false)).toBeNull();
    expect(officialSourceLabel('never', false)).toBeNull();
    expect(officialSourceLabel('loading', false)).toBeNull();
  });

  it('部落归属：无 last-good 为 unknown，有 last-good 无 tag 为 none', () => {
    expect(clanAffiliationOf(null)).toBe('unknown');
    expect(clanAffiliationOf(playerFixture({ summary: null, currentClanTag: null }))).toBe(
      'unknown',
    );
    expect(
      clanAffiliationOf(
        playerFixture({
          currentClanTag: null,
          summary: { ...playerFixture().summary!, clanTag: null, clanName: null },
        }),
      ),
    ).toBe('none');
    expect(clanAffiliationOf(playerFixture())).toBe('tagged');
  });

  it('无玩家 tag 不能刷新；query 失败保留 last-good', () => {
    const ready = toOfficialPlayerView(resourceSuccess(playerFixture({ playerTag: null })), 0);
    expect(ready.canRefresh).toBe(false);
    const failed = toOfficialPlayerView(
      resourceFailure(resourceSuccess(playerFixture()), '查询失败'),
      1_700_000_000_000,
    );
    expect(failed.queryStatus).toBe('error');
    expect(failed.summary?.name).toBe('Hero');
    expect(failed.lastQueryError).toBe('查询失败');
  });

  it('loading 无数据时不把归属当成不在部落', () => {
    const view = toOfficialPlayerView(LOADING_RESOURCE, 0);
    expect(view.queryStatus).toBe('loading');
    expect(view.summary).toBeNull();
    expect(playerRefreshStatusLine(view)).toMatch(/正在加载/);
  });

  it('无 last-good 的 query 失败不得解释成缺少标签', () => {
    const view = toOfficialPlayerView(resourceFailure(LOADING_RESOURCE, '查询失败'), 0);
    expect(view.queryStatus).toBe('error');
    expect(view.lastQueryError).toBe('查询失败');
    expect(view.playerTag).toBeNull();
    expect(playerRefreshStatusLine(view)).toBe('官方玩家状态读取失败');
    expect(playerRefreshStatusLine(view)).not.toMatch(/缺少有效标签/);
  });

  it('tagged clan 本地 loading/error 不得伪装成尚未获取', () => {
    const loading = toOfficialClanView('tagged', '#CLAN01', LOADING_RESOURCE, 0);
    expect(loading.queryStatus).toBe('loading');
    expect(loading.canRefresh).toBe(true);
    expect(clanRefreshStatusLine(loading)).toBe('正在加载部落数据…');
    expect(clanRefreshStatusLine(loading)).not.toMatch(/尚未获取/);
    const failed = toOfficialClanView(
      'tagged',
      '#CLAN01',
      resourceFailure(LOADING_RESOURCE, '部落查询失败'),
      0,
    );
    expect(failed.queryStatus).toBe('error');
    expect(failed.lastQueryError).toBe('部落查询失败');
    expect(clanRefreshStatusLine(failed)).toBeNull();
    const never = toOfficialClanView(
      'tagged',
      '#CLAN01',
      resourceSuccess(clanFixture({ state: null, summary: null })),
      0,
    );
    expect(never.queryStatus).toBe('ready');
    expect(clanRefreshStatusLine(never)).toMatch(/尚未获取部落数据/);
  });

  it('clockedRefreshStatus 只把 success/stale 投影到当前时刻', () => {
    const fetched = 1_700_000_000_000;
    expect(clockedRefreshStatus('success', fetched, fetched)).toBe('success');
    expect(
      clockedRefreshStatus('success', fetched, fetched + OFFICIAL_STALE_THRESHOLD_MS + 1),
    ).toBe('stale');
    expect(clockedRefreshStatus('failedWithoutLastGood', fetched, fetched)).toBe(
      'failedWithoutLastGood',
    );
  });

  it('切村时不得把旧 village 的 summary 投影给新 village', () => {
    const view = toOfficialPlayerView(resourceSuccess(playerFixture({ villageId: 'v1' })), 0, 'v2');
    expect(view.queryStatus).toBe('loading');
    expect(view.summary).toBeNull();
    expect(view.currentClanTag).toBeNull();
  });

  it('同一 village 的 playerTag 与当前 tag 不一致时丢弃旧摘要', () => {
    const view = toOfficialPlayerView(
      resourceSuccess(playerFixture({ villageId: 'v1', playerTag: '#AAA' })),
      0,
      'v1',
      '#BBB',
    );
    expect(view.queryStatus).toBe('loading');
    expect(view.summary).toBeNull();
    expect(view.playerTag).toBeNull();
    expect(view.currentClanTag).toBeNull();
  });

  it('officialPlayerSubjectKey 把 village tag 算进 identity', () => {
    const session = 'session-a';
    expect(officialPlayerSubjectKey(session, 'v1', '#AAA')).not.toBe(
      officialPlayerSubjectKey(session, 'v1', '#BBB'),
    );
    expect(officialPlayerSubjectKey(session, 'v1', '#AAA')).toBe(
      officialPlayerSubjectKey(session, 'v1', '#AAA'),
    );
  });

  it('clan unknown/none 不消费 clan 资源态', () => {
    const unknown = toOfficialClanView('unknown', null, LOADING_RESOURCE, 0);
    expect(unknown.canRefresh).toBe(false);
    expect(unknown.queryStatus).toBe('idle');
    const none = toOfficialClanView('none', null, LOADING_RESOURCE, 0);
    expect(none.affiliation).toBe('none');
    expect(none.canRefresh).toBe(false);
  });

  it('clan payload 与当前 clanTag 不一致时丢弃旧摘要', () => {
    const view = toOfficialClanView('tagged', '#CLAN02', resourceSuccess(clanFixture()), 0);
    expect(view.queryStatus).toBe('loading');
    expect(view.summary).toBeNull();
    expect(view.clanTag).toBe('#CLAN02');
  });

  it('部落类型与对战日志文案', () => {
    expect(clanTypeLabel('open')).toBe('任何人都可加入');
    expect(clanTypeLabel('inviteOnly')).toBe('只有被批准才能加入');
    expect(clanTypeLabel('closed')).toBe('不可加入');
    expect(clanTypeLabel('weird')).toBe('未知');
    expect(warLogPublicLabel(true)).toBe('公开');
    expect(warLogPublicLabel(false)).toBe('不公开');
    expect(warLogPublicLabel(null)).toBeNull();
  });
});
