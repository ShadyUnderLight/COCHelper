import { useClock } from '../use-clock';
import { clockedRefreshStatus } from '../official-session';
import {
  clanWarPhaseLabel,
  clanWarRefreshStatusLine,
  clanWarScoreLine,
  type OfficialClanWarView,
} from '../official-war-session';
import type { OfficialClanWarApi } from '../use-official-clan-war';
import { officialStatusClass } from './official-card-shared';

export type ClanWarCardProps = {
  readonly api: OfficialClanWarApi;
};

export function ClanWarCard({ api }: ClanWarCardProps) {
  const { view, refreshing, refresh } = api;
  const nowMs = useClock(view.refreshStatus === 'success' || view.refreshStatus === 'stale');
  const refreshStatus = clockedRefreshStatus(view.refreshStatus, view.fetchedAtMs, nowMs);
  const displayView: OfficialClanWarView = { ...view, refreshStatus };
  const statusLine = clanWarRefreshStatusLine(displayView);
  const scoreLine = displayView.war === null ? null : clanWarScoreLine(displayView.war);

  return (
    <section className="official-card" aria-label="当前部落对战">
      <header className="official-card-header">
        <h3>当前部落对战</h3>
        {displayView.sourceLabel !== null ? (
          <span className="official-source">{displayView.sourceLabel}</span>
        ) : null}
      </header>
      {statusLine !== null ? (
        <p className={officialStatusClass(displayView.refreshStatus)}>{statusLine}</p>
      ) : null}
      {displayView.lastQueryError !== null ? (
        <p className="error-text" role="alert">{displayView.lastQueryError}</p>
      ) : null}
      {displayView.commandError !== null ? (
        <p className="error-text" role="alert">{displayView.commandError}</p>
      ) : null}
      {displayView.refreshStatus === 'failedWithLastGood' ? (
        <p className="muted">已保留上次成功数据</p>
      ) : null}
      {displayView.war !== null ? (
        <div className="official-war-body">
          <p>{clanWarPhaseLabel(displayView.phase, displayView.war.state)}</p>
          {scoreLine !== null ? <p className="muted">{scoreLine}</p> : null}
        </div>
      ) : null}
      {displayView.unrecognizedKeys.length > 0 ? (
        <p className="muted">官方响应包含未识别字段：{displayView.unrecognizedKeys.join('、')}</p>
      ) : null}
      {displayView.canRefresh ? (
        <div className="action-row">
          <button type="button" disabled={refreshing} onClick={() => void refresh()}>
            {refreshing ? '正在刷新…' : '刷新当前部落对战'}
          </button>
        </div>
      ) : null}
    </section>
  );
}
