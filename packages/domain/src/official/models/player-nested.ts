import { asRecord, optionalInt, optionalString } from '../json-decode';

export type PlayerClan = {
  readonly tag: string | undefined;
  readonly name: string | undefined;
  readonly clanLevel: number | undefined;
  readonly badgeUrls: Readonly<Record<string, string>> | undefined;
};

export function decodePlayerClan(value: unknown): PlayerClan | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  const record = asRecord(value, 'PlayerClan');
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
  return {
    tag: optionalString(record.tag),
    name: optionalString(record.name),
    clanLevel: optionalInt(record.clanLevel),
    badgeUrls,
  };
}
