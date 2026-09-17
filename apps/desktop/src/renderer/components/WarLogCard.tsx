import { useClock } from '../use-clock';
import { clockedRefreshStatus } from '../official-session';
import {
  warLogEntryLabel,
  warLogRefreshStatusLine,
  warLogShowsEmptyHistory,
  type OfficialWarLogView,
} from '../official-war-session';
import type { OfficialWarLogApi } from '../use-official-war-log';
import { officialStatusClass } from './official-card-shared';
import { OfficialWarLogEntryDetails } from './official-war-details';

export type WarLogCardProps = {
  readonly api: OfficialWarLogApi;
};

export function WarLogCard({ api }: WarLogCardProps) {
  const { view, refreshing, loadingMore, refresh, loadMore } = api;
  const nowMs = useClock(view.refreshStatus === 'success' || view.refreshStatus === 'stale');
  const refreshStatus = clockedRefreshStatus(view.refreshStatus, view.fetchedAtMs, nowMs);
  const displayView: OfficialWarLogView = { ...view, refreshStatus };
  const statusLine = warLogRefreshStatusLine(displayView);
  const moreLabel =
    displayView.moreState === 'serverMore'
      ? loadingMore
        ? '正在加载更多…'
        : '加载更多'
      : displayView.moreState === 'localHidden'
        ? '查看更多'
        : null;

  return (
    <section className="official-card" aria-label="部落对战日志">
      <header className="official-card-header">
        <h3>部落对战日志</h3>
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
      {warLogShowsEmptyHistory(displayView) ? <p className="muted">没有历史部落对战记录</p> : null}
      {displayView.visibleEntries.length > 0 ? (
        <ul className="official-list official-war-log-list">
          {displayView.visibleEntries.map((entry, index) => (
            <li key={`${entry.endTime ?? 'unknown'}-${index}`}>
              <p>{warLogEntryLabel(entry)}</p>
              <OfficialWarLogEntryDetails entry={entry} />
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
            {refreshing ? '正在刷新…' : '刷新部落对战日志'}
          </button>
        ) : null}
        {moreLabel !== null ? (
          <button
            type="button"
            disabled={displayView.moreState === 'serverMore' ? api.remoteBusy : false}
            onClick={() => void loadMore()}
          >
            {moreLabel}
          </button>
        ) : null}
      </div>
    </section>
  );
}
