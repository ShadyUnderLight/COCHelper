import {
  clanRefreshStatusLine,
  clanTypeLabel,
  warLogPublicLabel,
  type OfficialClanView,
} from '../official-session';

export type ClanCardProps = {
  readonly view: OfficialClanView;
  readonly refreshing: boolean;
  readonly onRefresh: () => void;
};

export function ClanCard({ view, refreshing, onRefresh }: ClanCardProps) {
  const statusLine = clanRefreshStatusLine(view);
  const showRefresh = view.affiliation === 'tagged';

  return (
    <section className="official-card" aria-label="部落数据">
      <header className="official-card-header">
        <h3>部落数据</h3>
        {view.sourceLabel !== null ? (
          <span className="official-source">{view.sourceLabel}</span>
        ) : null}
      </header>
      {statusLine !== null ? <p className={statusClass(view)}>{statusLine}</p> : null}
      {view.affiliation === 'unknown' ? (
        <p className="muted">先刷新官方玩家数据即可显示部落信息。</p>
      ) : null}
      {view.lastQueryError !== null ? (
        <p className="error-text" role="alert">
          {view.lastQueryError}
        </p>
      ) : null}
      {view.refreshStatus === 'failedWithLastGood' ? (
        <p className="muted">已保留上次成功数据</p>
      ) : null}
      {view.summary !== null ? <ClanSummaryGrid view={view} /> : null}
      {view.unrecognizedKeys.length > 0 ? (
        <p className="muted">官方响应包含未识别字段：{view.unrecognizedKeys.join('、')}</p>
      ) : null}
      {showRefresh ? (
        <div className="action-row">
          <button type="button" disabled={!view.canRefresh || refreshing} onClick={onRefresh}>
            {refreshing ? '正在刷新…' : '刷新部落数据'}
          </button>
        </div>
      ) : null}
    </section>
  );
}

function ClanSummaryGrid(props: { readonly view: OfficialClanView }) {
  const summary = props.view.summary;
  if (summary === null) {
    return null;
  }
  const items: ReadonlyArray<readonly [string, string | null]> = [
    ['名称', summary.name],
    ['标签', summary.tag],
    ['等级', summary.clanLevel === null ? null : String(summary.clanLevel)],
    ['成员数', summary.members === null ? null : String(summary.members)],
    ['类型', clanTypeLabel(summary.type)],
    ['部落对战胜利次数', summary.warWins === null ? null : String(summary.warWins)],
    ['部落对战日志', warLogPublicLabel(summary.isWarLogPublic)],
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
  view: OfficialClanView,
): 'muted' | 'notice-text' | 'error-text' | 'official-ok' {
  if (view.affiliation !== 'tagged') {
    return 'muted';
  }
  switch (view.refreshStatus) {
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
