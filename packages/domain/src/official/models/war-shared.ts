import {
  asRecord,
  optionalDouble,
  optionalInt,
  optionalString,
  type JsonRecord,
} from '../json-decode';

export type ClanWarAttack = {
  readonly order: number | undefined;
  readonly attackerTag: string | undefined;
  readonly defenderTag: string | undefined;
  readonly stars: number | undefined;
  readonly destructionPercentage: number | undefined;
  readonly duration: number | undefined;
};

export type ClanWarMember = {
  readonly tag: string | undefined;
  readonly name: string | undefined;
  readonly mapPosition: number | undefined;
  readonly townhallLevel: number | undefined;
  readonly attacks: readonly ClanWarAttack[] | undefined;
  readonly opponentAttacks: number | undefined;
  readonly bestOpponentAttack: ClanWarAttack | undefined;
};

export type ClanWarParticipant = {
  readonly tag: string | undefined;
  readonly name: string | undefined;
  readonly badgeUrls: Readonly<Record<string, string>> | undefined;
  readonly clanLevel: number | undefined;
  readonly attacks: number | undefined;
  readonly stars: number | undefined;
  readonly destructionPercentage: number | undefined;
  readonly members: readonly ClanWarMember[] | undefined;
};

export function decodeClanWarAttack(value: unknown): ClanWarAttack {
  const record = asRecord(value, 'ClanWarAttack');
  return {
    order: optionalInt(record.order),
    attackerTag: optionalString(record.attackerTag),
    defenderTag: optionalString(record.defenderTag),
    stars: optionalInt(record.stars),
    destructionPercentage: optionalDouble(record.destructionPercentage),
    duration: optionalInt(record.duration),
  };
}

export function decodeClanWarMember(value: unknown): ClanWarMember {
  const record = asRecord(value, 'ClanWarMember');
  const attacksRaw = record.attacks;
  let attacks: readonly ClanWarAttack[] | undefined;
  if (attacksRaw !== undefined && attacksRaw !== null) {
    if (!Array.isArray(attacksRaw)) {
      throw new TypeError('attacks 必须是 array 或 null。');
    }
    attacks = attacksRaw.map(decodeClanWarAttack);
  }
  const bestRaw = record.bestOpponentAttack;
  return {
    tag: optionalString(record.tag),
    name: optionalString(record.name),
    mapPosition: optionalInt(record.mapPosition),
    townhallLevel: optionalInt(record.townhallLevel),
    attacks,
    opponentAttacks: optionalInt(record.opponentAttacks),
    bestOpponentAttack:
      bestRaw === undefined || bestRaw === null ? undefined : decodeClanWarAttack(bestRaw),
  };
}

export function decodeClanWarParticipant(value: unknown): ClanWarParticipant {
  const record = asRecord(value, 'ClanWarParticipant');
  const badgeRaw = record.badgeUrls;
  let badgeUrls: Readonly<Record<string, string>> | undefined;
  if (badgeRaw !== undefined && badgeRaw !== null) {
    badgeUrls = Object.fromEntries(
      Object.entries(asRecord(badgeRaw, 'badgeUrls')).map(([key, entry]) => {
        if (typeof entry !== 'string') {
          throw new TypeError(`badgeUrls.${key} 必须是 string。`);
        }
        return [key, entry];
      }),
    );
  }
  const membersRaw = record.members;
  let members: readonly ClanWarMember[] | undefined;
  if (membersRaw !== undefined && membersRaw !== null) {
    if (!Array.isArray(membersRaw)) {
      throw new TypeError('members 必须是 array 或 null。');
    }
    members = membersRaw.map(decodeClanWarMember);
  }
  return {
    tag: optionalString(record.tag),
    name: optionalString(record.name),
    badgeUrls,
    clanLevel: optionalInt(record.clanLevel),
    attacks: optionalInt(record.attacks),
    stars: optionalInt(record.stars),
    destructionPercentage: optionalDouble(record.destructionPercentage),
    members,
  };
}

export function decodeOptionalParticipant(value: unknown): ClanWarParticipant | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  return decodeClanWarParticipant(value);
}

export function decodeParticipantRecord(record: JsonRecord): ClanWarParticipant {
  return decodeClanWarParticipant(record);
}
