import { useClock } from '../use-clock';
import { clockedRefreshStatus } from '../official-session';
import {
  capitalRaidRefreshStatusLine,
  capitalRaidSeasonLabel,
  capitalRaidShowsEmptyHistory,
  type OfficialCapitalRaidView,
} from '../official-war-session';
import type { OfficialCapitalRaidApi } from '../use-official-capital-raid';
import { officialStatusClass } from './official-card-shared';
import { OfficialCapitalRaidSeasonDetails } from './official-war-details';

export type CapitalRaidCardProps = {
  readonly api: OfficialCapitalRaidApi;
};

export function CapitalRaidCard({ api }: CapitalRaidCardProps) {
  const { view, refreshing, loadingMore, refresh, loadMore } = api;
  const nowMs = useClock(view.refreshStatus === 'success' || view.refreshStatus === 'stale');
  const refreshStatus = clockedRefreshStatus(view.refreshStatus, view.fetchedAtMs, nowMs);
  const displayView: OfficialCapitalRaidView = { ...view, refreshStatus };
  const statusLine = capitalRaidRefreshStatusLine(displayView);

  return (
    <section className="official-card" aria-label="突袭周末">
      <header className="official-card-header">
        <h3>突袭周末</h3>
        {displayView.sourceLabel !== null ? (
          <span className="official-source">{displayView.sourceLabel}</span>
        ) : null}
      </header>
      {statusLine !== null ? (
        <p className={officialStatusClass(displayView.refreshStatus)}>{statusLine}</p>
      ) : null}
      {displayView.lastQueryError !== null ? (
        <p className="error-text" role="alert">
          {displayView.lastQueryError}
        </p>
      ) : null}
      {displayView.commandError !== null ? (
        <p className="error-text" role="alert">
          {displayView.commandError}
        </p>
      ) : null}
      {displayView.refreshStatus === 'failedWithLastGood' ? (
        <p className="muted">已保留上次成功数据</p>
      ) : null}
      {capitalRaidShowsEmptyHistory(displayView) ? <p className="muted">暂无突袭周末记录</p> : null}
      {displayView.seasons.length > 0 ? (
        <ul className="official-list official-capital-raid-list">
          {displayView.seasons.map((season, index) => (
            <li key={`${season.startTime ?? 'unknown'}-${index}`}>
              <p>{capitalRaidSeasonLabel(season)}</p>
              <OfficialCapitalRaidSeasonDetails season={season} />
            </li>
          ))}
        </ul>
      ) : null}
      {displayView.unrecognizedKeys.length > 0 ? (
        <p className="muted">官方响应包含未识别字段：{displayView.unrecognizedKeys.join('、')}</p>
      ) : null}
      <div className="action-row">
        {displayView.canRefresh ? (
          <button type="button" disabled={api.remoteBusy} onClick={() => void refresh()}>
            {refreshing ? '正在刷新…' : '刷新突袭周末'}
          </button>
        ) : null}
        {displayView.canLoadMore ? (
          <button type="button" disabled={api.remoteBusy} onClick={() => void loadMore()}>
            {loadingMore ? '正在加载更多…' : '加载更多'}
          </button>
        ) : null}
      </div>
    </section>
  );
}
