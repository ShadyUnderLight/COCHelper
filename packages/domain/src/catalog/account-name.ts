export type AccountNameCatalog = {
  readonly count: number;
  readonly nameFor: (section: string, dataID: bigint) => string | undefined;
  readonly nameForNumericSection: (section: string, dataID: bigint) => string | undefined;
};

export function createAccountNameCatalog(
  names: Readonly<Record<string, string>>,
): AccountNameCatalog {
  const entries = { ...names };
  return {
    count: Object.keys(entries).length,
    nameFor(section, dataID) {
      const exact = entries[key(section, dataID)];
      if (exact !== undefined) {
        return exact;
      }
      if (dataID >= 102_000_000n && dataID < 103_000_000n) {
        return entries[key('modules', dataID)];
      }
      if (dataID >= 103_000_000n && dataID < 104_000_000n) {
        return entries[key('types', dataID)];
      }
      return undefined;
    },
    nameForNumericSection(section, dataID) {
      return entries[key(section, dataID)];
    },
  };
}

export function decodeAccountNameCatalog(text: string): AccountNameCatalog {
  const payload = JSON.parse(text) as { entries: Record<string, string> };
  return createAccountNameCatalog(payload.entries ?? {});
}

export const EMPTY_ACCOUNT_NAME_CATALOG = createAccountNameCatalog({});

function key(section: string, dataID: bigint): string {
  return `${section}:${dataID.toString()}`;
}
