export type LeagueTierContext = 'home' | 'builderBase' | 'capital' | 'leagueTier' | 'war';

export const LEAGUE_TIER_CONTEXTS: readonly LeagueTierContext[] = [
  'home',
  'builderBase',
  'capital',
  'leagueTier',
  'war',
];

export type LeagueTierSpec = {
  readonly id: number;
  readonly name: string;
};

export type LeagueTierContextSpec = {
  readonly context: LeagueTierContext;
  readonly tiers: readonly LeagueTierSpec[];
};

export type LeagueTierCatalog = {
  readonly schemaVersion: number;
  readonly gameVersion: string;
  readonly locale: string;
  readonly source: string;
  readonly contexts: readonly LeagueTierContextSpec[];
  readonly nameFor: (id: number, context: LeagueTierContext) => string | undefined;
};

export function createLeagueTierCatalog(input: {
  readonly schemaVersion: number;
  readonly gameVersion: string;
  readonly locale: string;
  readonly source: string;
  readonly contexts: readonly LeagueTierContextSpec[];
}): LeagueTierCatalog {
  const contexts = [...input.contexts];
  return {
    schemaVersion: input.schemaVersion,
    gameVersion: input.gameVersion,
    locale: input.locale,
    source: input.source,
    contexts,
    nameFor(id, context) {
      return contexts
        .find((entry) => entry.context === context)
        ?.tiers.find((tier) => tier.id === id)?.name;
    },
  };
}

export function leagueTierCatalogIsValid(catalog: LeagueTierCatalog): boolean {
  const contexts = catalog.contexts.map((entry) => entry.context);
  if (new Set(contexts).size !== contexts.length) {
    return false;
  }
  if (new Set(contexts).size !== LEAGUE_TIER_CONTEXTS.length) {
    return false;
  }
  for (const expected of LEAGUE_TIER_CONTEXTS) {
    if (!contexts.includes(expected)) {
      return false;
    }
  }
  return catalog.contexts.every((entry) => {
    const ids = entry.tiers.map((tier) => tier.id);
    return new Set(ids).size === ids.length;
  });
}

export function decodeLeagueTierCatalog(text: string): LeagueTierCatalog {
  const payload = JSON.parse(text) as {
    schemaVersion: number;
    gameVersion: string;
    locale?: string;
    source: string;
    contexts: Array<{ context: LeagueTierContext; tiers: Array<{ id: number; name: string }> }>;
  };
  return createLeagueTierCatalog({
    schemaVersion: payload.schemaVersion,
    gameVersion: payload.gameVersion,
    locale: payload.locale ?? 'zh-CN',
    source: payload.source,
    contexts: payload.contexts,
  });
}

export function loadLeagueTierCatalog(input: {
  readonly version: string;
  readonly text: string;
}): LeagueTierCatalog | null {
  try {
    const catalog = decodeLeagueTierCatalog(input.text);
    if (catalog.schemaVersion !== 1 || catalog.gameVersion !== input.version) {
      return null;
    }
    if (!leagueTierCatalogIsValid(catalog)) {
      return null;
    }
    return catalog;
  } catch {
    return null;
  }
}
