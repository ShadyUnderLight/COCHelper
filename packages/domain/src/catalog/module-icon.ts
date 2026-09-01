import type { CatalogAssetRef } from './types';

export type ModuleUpgradeIconKind = 'health' | 'damage' | 'effect';

const EXPORT_NAMES: Record<ModuleUpgradeIconKind, string> = {
  health: 'info_icon_hp',
  damage: 'info_icon_damage',
  effect: 'info_icon_time_boosted',
};

export const MODULE_UPGRADE_ICON_MAPPINGS: Readonly<Record<string, ModuleUpgradeIconKind>> = {
  '102000033': 'health',
  '102000034': 'damage',
  '102000035': 'effect',
  '102000036': 'health',
  '102000037': 'damage',
  '102000038': 'effect',
  '102000039': 'health',
  '102000040': 'damage',
  '102000041': 'effect',
};

export function moduleUpgradeIconKind(dataID: bigint): ModuleUpgradeIconKind | undefined {
  return MODULE_UPGRADE_ICON_MAPPINGS[dataID.toString()];
}

export function moduleUpgradeIconAsset(dataID: bigint): CatalogAssetRef | undefined {
  const kind = moduleUpgradeIconKind(dataID);
  if (kind === undefined) {
    return undefined;
  }
  const exportName = EXPORT_NAMES[kind];
  return {
    container: 'sc/ui.sc',
    exportName,
    renderedPath: `icons/ui/${exportName}.png`,
    missingReason: null,
  };
}

export function moduleUpgradeIconRenderedPath(dataID: bigint): string | undefined {
  return moduleUpgradeIconAsset(dataID)?.renderedPath ?? undefined;
}
