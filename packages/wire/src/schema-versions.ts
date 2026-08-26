/** WA-7 schemaVersion 注册表。不做 store 加载状态机。 */
export const schemaVersions = {
  villageStore: { current: 1 },
  snapshotHistory: {
    envelope: 1,
    entry: 1,
    observationWithSectionEvidence: 2,
    observationWithTimerAllowlist: 3,
    observationWithTimerSchema: 4,
    observationWithoutCoverageMetadata: 5,
    observationWithSourceUniverse: 6,
    observation: 6,
    fingerprint: 1,
    integrity: 1,
  },
  manualTracker: {
    envelope: 1,
    store: 1,
    village: 1,
  },
  gameCatalogManifest: { min: 1, max: 2 },
  leagueTierCatalog: 1,
  craftTableCatalog: 1,
  seasonalPhaseTable: 1,
} as const;

export const parserVersions = {
  accountSnapshot: 'account-json-0.1',
  playerSnapshot: 'player-snapshot-0.2',
  clanSnapshot: 'clan-snapshot-0.4',
  clanWar: 'clan-war-0.3',
  clanWarLog: 'clan-war-log-0.4',
  clanCapital: 'clan-capital-0.3',
} as const;
