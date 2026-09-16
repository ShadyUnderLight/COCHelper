import { useClock } from '../use-clock';
import type { OfficialPlayerView } from '../official-session';
import { clockedRefreshStatus, playerRefreshStatusLine } from '../official-session';

export type OfficialPlayerCardProps = {
  readonly view: OfficialPlayerView;
  readonly refreshing: boolean;
  readonly onRefresh: () => void;
};

export function OfficialPlayerCard({ view, refreshing, onRefresh }: OfficialPlayerCardProps) {
  const nowMs = useClock();
  const refreshStatus = clockedRefreshStatus(view.refreshStatus, view.fetchedAtMs, nowMs);
  const displayView = { ...view, refreshStatus };
  const statusLine = playerRefreshStatusLine(displayView);
  const showEndpointStatus =
    displayView.queryStatus !== 'loading' &&
    !(displayView.queryStatus === 'error' && displayView.summary === null);
  const showLastGoodHint =
    displayView.refreshStatus === 'failedWithLastGood' && displayView.fetchedAtMs !== null;
  const missingTag =
    displayView.queryStatus === 'ready' &&
    displayView.playerTag === null &&
    (displayView.refreshStatus === null || displayView.refreshStatus === 'never');

  return (
    <section className="official-card" aria-label="官方玩家数据">
      <header className="official-card-header">
        <h3>
          官方玩家数据{displayView.sourceLabel === null ? '' : ` · ${displayView.sourceLabel}`}
        </h3>
      </header>
      {displayView.queryStatus === 'loading' ? (
        <p className="muted">正在加载官方玩家数据…</p>
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
      {showEndpointStatus ? (
        <p className={statusClass(displayView.refreshStatus)}>{statusLine}</p>
      ) : null}
      {missingTag ? <p className="muted">请先在账号数据页导入该村庄的账号 JSON</p> : null}
      {showLastGoodHint ? <p className="muted">已保留上次成功数据</p> : null}
      {displayView.refreshStatus === 'never' ||
      displayView.refreshStatus === 'skipped' ||
      displayView.refreshStatus === 'failedWithoutLastGood' ? (
        <p className="muted">刷新失败或尚未获取不会影响本地导入数据与升级追踪。</p>
      ) : null}
      {displayView.summary !== null ? <PlayerSummaryGrid summary={displayView.summary} /> : null}
      {displayView.unrecognizedKeys.length > 0 ? (
        <p className="muted">官方响应包含未识别字段：{displayView.unrecognizedKeys.join('、')}</p>
      ) : null}
      <div className="action-row">
        <button type="button" disabled={!displayView.canRefresh || refreshing} onClick={onRefresh}>
          {refreshing ? '正在刷新…' : '刷新官方数据'}
        </button>
      </div>
    </section>
  );
}

function PlayerSummaryGrid(props: { readonly summary: OfficialPlayerView['summary'] }) {
  const summary = props.summary;
  if (summary === null) {
    return null;
  }
  const items: ReadonlyArray<readonly [string, string | null]> = [
    ['名称', summary.name],
    ['标签', summary.tag],
    ['大本营等级', summary.townHallLevel === null ? null : `${summary.townHallLevel}级`],
    ['建筑大师大本营', summary.builderHallLevel === null ? null : `${summary.builderHallLevel}级`],
    ['经验等级', summary.expLevel === null ? null : String(summary.expLevel)],
    ['奖杯', summary.trophies === null ? null : String(summary.trophies)],
    ['最佳奖杯', summary.bestTrophies === null ? null : String(summary.bestTrophies)],
    ['部落', summary.clanName],
    ['部落标签', summary.clanTag],
  ];
  return (
    <dl className="official-metrics">
      {items.map(([title, value]) => (
        <div key={title} className="official-metric">
          <dt>{title}</dt>
          <dd>{value ?? '—'}</dd>
        </div>
      ))}
    </dl>
  );
}

function statusClass(
  status: OfficialPlayerView['refreshStatus'],
): 'muted' | 'notice-text' | 'error-text' | 'official-ok' {
  switch (status) {
    case 'stale':
      return 'notice-text';
    case 'failedWithLastGood':
    case 'failedWithoutLastGood':
      return 'error-text';
    case 'success':
      return 'official-ok';
    default:
      return 'muted';
  }
}
