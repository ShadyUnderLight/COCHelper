import type {
  CapitalRaidSeasonWire,
  ClanWarMemberWire,
  ClanWarParticipantWire,
  ClanWarWire,
  WarLogEntryWire,
} from '@coc-helper/contracts';

import {
  clanWarMemberRowLabel,
  clanWarParticipantHasMembers,
  OFFICIAL_DETAIL_ROW_LIMIT,
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

function capitalRaidMemberRows(season: CapitalRaidSeasonWire): readonly string[] {
  return (season.members ?? []).map((member) => {
    const name = member.name ?? member.tag ?? '未知成员';
    const loot =
      member.capitalResourcesLooted === undefined ? null : `掠夺 ${member.capitalResourcesLooted}`;
    const attacks = member.attacks === undefined ? null : `进攻 ${member.attacks} 次`;
    return [name, loot, attacks].filter((part) => part !== null).join(' · ');
  });
}

function capitalRaidAttackLogRows(season: CapitalRaidSeasonWire): readonly string[] {
  return (season.attackLog ?? []).map((entry) => {
    const defender = entry.defender?.name ?? entry.defender?.tag ?? '未知部落';
    const districts = entry.districtsDestroyed ?? entry.districtCount;
    const attacks = entry.attackCount;
    const parts = [
      `防守方 ${defender}`,
      attacks === undefined ? null : `进攻 ${attacks} 次`,
      districts === undefined ? null : `摧毁城区 ${districts}`,
    ].filter((part) => part !== null);
    return parts.join(' · ');
  });
}

function capitalRaidDefenseLogRows(season: CapitalRaidSeasonWire): readonly string[] {
  return (season.defenseLog ?? []).map((entry) => {
    const attacker = entry.attacker?.name ?? entry.attacker?.tag ?? '未知部落';
    const districts = entry.districtsDestroyed ?? entry.districtCount;
    const attacks = entry.attackCount;
    const parts = [
      `进攻方 ${attacker}`,
      attacks === undefined ? null : `进攻 ${attacks} 次`,
      districts === undefined ? null : `被摧毁城区 ${districts}`,
    ].filter((part) => part !== null);
    return parts.join(' · ');
  });
}

export function OfficialCapitalRaidSeasonDetails(props: {
  readonly season: CapitalRaidSeasonWire;
}) {
  const { season } = props;
  return (
    <>
      <SimpleRowList title="成员突袭" rows={capitalRaidMemberRows(season)} />
      <SimpleRowList title="进攻日志" rows={capitalRaidAttackLogRows(season)} />
      <SimpleRowList title="防守日志" rows={capitalRaidDefenseLogRows(season)} />
    </>
  );
}
