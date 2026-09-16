import type { OfficialPlayerView } from '../official-session';
import { playerRefreshStatusLine } from '../official-session';

export type OfficialPlayerCardProps = {
  readonly view: OfficialPlayerView;
  readonly refreshing: boolean;
  readonly onRefresh: () => void;
};

export function OfficialPlayerCard({ view, refreshing, onRefresh }: OfficialPlayerCardProps) {
  const statusLine = playerRefreshStatusLine(view);
  const showLastGoodHint = view.refreshStatus === 'failedWithLastGood' && view.fetchedAtMs !== null;
  const missingTag =
    view.queryStatus === 'ready' &&
    view.playerTag === null &&
    (view.refreshStatus === null || view.refreshStatus === 'never');

  return (
    <section className="official-card" aria-label="官方玩家数据">
      <header className="official-card-header">
        <h3>官方玩家数据{view.sourceLabel === null ? '' : ` · ${view.sourceLabel}`}</h3>
      </header>
      {view.queryStatus === 'loading' ? <p className="muted">正在加载官方玩家数据…</p> : null}
      {view.lastQueryError !== null ? (
        <p className="error-text" role="alert">
          {view.lastQueryError}
        </p>
      ) : null}
      {view.commandError !== null ? (
        <p className="error-text" role="alert">
          {view.commandError}
        </p>
      ) : null}
      {view.queryStatus !== 'loading' ? (
        <p className={statusClass(view.refreshStatus)}>{statusLine}</p>
      ) : null}
      {missingTag ? <p className="muted">请先在账号数据页导入该村庄的账号 JSON</p> : null}
      {view.lastErrorReason !== null && view.refreshStatus === 'failedWithoutLastGood' ? (
        <p className="muted">{view.lastErrorReason}</p>
      ) : null}
      {showLastGoodHint ? <p className="muted">已保留上次成功数据</p> : null}
      {view.refreshStatus === 'never' ||
      view.refreshStatus === 'skipped' ||
      view.refreshStatus === 'failedWithoutLastGood' ? (
        <p className="muted">刷新失败或尚未获取不会影响本地导入数据与升级追踪。</p>
      ) : null}
      {view.summary !== null ? <PlayerSummaryGrid summary={view.summary} /> : null}
      {view.unrecognizedKeys.length > 0 ? (
        <p className="muted">官方响应包含未识别字段：{view.unrecognizedKeys.join('、')}</p>
      ) : null}
      <div className="action-row">
        <button type="button" disabled={!view.canRefresh || refreshing} onClick={onRefresh}>
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
