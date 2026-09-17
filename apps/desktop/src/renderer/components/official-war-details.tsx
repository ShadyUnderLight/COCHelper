import type {
  CapitalRaidSeasonWire,
  ClanWarMemberWire,
  ClanWarParticipantWire,
  ClanWarWire,
  WarLogEntryWire,
} from '@coc-helper/contracts';

import {
  capitalRaidAttackLogRows,
  capitalRaidDefenseLogRows,
  capitalRaidMemberRows,
  clanWarMemberRowLabel,
  clanWarParticipantHasMembers,
  OFFICIAL_DETAIL_ROW_LIMIT,
  type CapitalRaidLogRow,
} from '../official-war-session';

function limitedRows<T>(items: readonly T[] | undefined): readonly T[] {
  if (items === undefined) {
    return [];
  }
  return items.slice(0, OFFICIAL_DETAIL_ROW_LIMIT);
}

function MemberList(props: {
  readonly title: string;
  readonly members: readonly ClanWarMemberWire[];
}) {
  if (props.members.length === 0) {
    return null;
  }
  const rows = limitedRows(props.members);
  const truncated = props.members.length > rows.length;
  return (
    <details className="official-details">
      <summary>
        {props.title}（{props.members.length}）
      </summary>
      <ul className="official-list">
        {rows.map((member, index) => (
          <li key={`${member.tag ?? member.name ?? 'member'}-${index}`}>
            {clanWarMemberRowLabel(member)}
          </li>
        ))}
      </ul>
      {truncated ? <p className="muted">仅显示前 {OFFICIAL_DETAIL_ROW_LIMIT} 条成员记录</p> : null}
    </details>
  );
}

function ParticipantMembers(props: {
  readonly title: string;
  readonly participant: ClanWarParticipantWire | undefined;
}) {
  if (!clanWarParticipantHasMembers(props.participant)) {
    return null;
  }
  return <MemberList title={props.title} members={props.participant?.members ?? []} />;
}

export function OfficialClanWarDetails(props: { readonly war: ClanWarWire }) {
  const { war } = props;
  return (
    <>
      <ParticipantMembers title="我方成员进攻" participant={war.clan} />
      <ParticipantMembers title="对方成员进攻" participant={war.opponent} />
    </>
  );
}

export function OfficialWarLogEntryDetails(props: { readonly entry: WarLogEntryWire }) {
  const { entry } = props;
  return (
    <>
      <ParticipantMembers title="我方成员" participant={entry.clan} />
      <ParticipantMembers title="对方成员" participant={entry.opponent} />
    </>
  );
}

function SimpleRowList(props: { readonly title: string; readonly rows: readonly string[] }) {
  if (props.rows.length === 0) {
    return null;
  }
  const visible = props.rows.slice(0, OFFICIAL_DETAIL_ROW_LIMIT);
  const truncated = props.rows.length > visible.length;
  return (
    <details className="official-details">
      <summary>
        {props.title}（{props.rows.length}）
      </summary>
      <ul className="official-list">
        {visible.map((row, index) => (
          <li key={`${props.title}-${index}`}>{row}</li>
        ))}
      </ul>
      {truncated ? <p className="muted">仅显示前 {OFFICIAL_DETAIL_ROW_LIMIT} 条记录</p> : null}
    </details>
  );
}

function CapitalRaidLogList(props: {
  readonly title: string;
  readonly rows: readonly CapitalRaidLogRow[];
}) {
  if (props.rows.length === 0) {
    return null;
  }
  const visible = props.rows.slice(0, OFFICIAL_DETAIL_ROW_LIMIT);
  const truncated = props.rows.length > visible.length;
  return (
    <details className="official-details">
      <summary>
        {props.title}（{props.rows.length}）
      </summary>
      <ul className="official-list">
        {visible.map((row, index) => (
          <li
            key={`${props.title}-${index}`}
            className={row.kind === 'district' ? 'official-detail-subrow' : undefined}
          >
            {row.label}
          </li>
        ))}
      </ul>
      {truncated ? <p className="muted">仅显示前 {OFFICIAL_DETAIL_ROW_LIMIT} 条记录</p> : null}
    </details>
  );
}

export function OfficialCapitalRaidSeasonDetails(props: {
  readonly season: CapitalRaidSeasonWire;
}) {
  const { season } = props;
  return (
    <>
      <SimpleRowList title="成员突袭" rows={capitalRaidMemberRows(season)} />
      <CapitalRaidLogList title="进攻日志" rows={capitalRaidAttackLogRows(season)} />
      <CapitalRaidLogList title="防守日志" rows={capitalRaidDefenseLogRows(season)} />
    </>
  );
}
