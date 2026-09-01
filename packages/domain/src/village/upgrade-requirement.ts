import type { CatalogItem, CatalogLevel } from '../catalog/types';
import type { TrackerBase } from './tracker';

export type UpgradeRequirement =
  | { readonly kind: 'townHall'; readonly level: number }
  | { readonly kind: 'builderHall'; readonly level: number }
  | { readonly kind: 'laboratory'; readonly level: number }
  | { readonly kind: 'starLaboratory'; readonly level: number }
  | { readonly kind: 'heroHall'; readonly level: number }
  | { readonly kind: 'blacksmith'; readonly level: number };

export function upgradeRequirementRequiredLevel(req: UpgradeRequirement): number {
  return req.level;
}

export function catalogLevelRequirements(
  level: CatalogLevel,
  base: string | null | undefined,
): readonly UpgradeRequirement[] {
  switch (base) {
    case 'home': {
      const out: UpgradeRequirement[] = [];
      if (level.requiredTownHallLevel !== null) {
        out.push({ kind: 'townHall', level: level.requiredTownHallLevel });
      }
      if (level.requiredLaboratoryLevel !== null) {
        out.push({ kind: 'laboratory', level: level.requiredLaboratoryLevel });
      }
      if (level.requiredHeroTavernLevel !== null && level.requiredHeroTavernLevel > 0) {
        out.push({ kind: 'heroHall', level: level.requiredHeroTavernLevel });
      }
      if (level.requiredBlacksmithLevel !== null && level.requiredBlacksmithLevel > 0) {
        out.push({ kind: 'blacksmith', level: level.requiredBlacksmithLevel });
      }
      return out;
    }
    case 'builder': {
      const out: UpgradeRequirement[] = [];
      if (level.requiredTownHallLevel !== null) {
        out.push({ kind: 'builderHall', level: level.requiredTownHallLevel });
      }
      if (level.requiredLaboratoryLevel !== null) {
        out.push({ kind: 'starLaboratory', level: level.requiredLaboratoryLevel });
      }
      return out;
    }
    default:
      return [];
  }
}

export function catalogItemRequirements(item: CatalogItem): readonly UpgradeRequirement[] {
  return item.levels.flatMap((level) => catalogLevelRequirements(level, item.base));
}

export function upgradeRequirementLabel(
  req: UpgradeRequirement,
  base: TrackerBase | string | null | undefined,
): string {
  const name = upgradeRequirementName(req, base);
  return `所需${name}等级 ${req.level}级`;
}

function upgradeRequirementName(
  req: UpgradeRequirement,
  base: TrackerBase | string | null | undefined,
): string {
  switch (req.kind) {
    case 'townHall':
      return base === 'builder' ? '建筑大师大本营' : '大本营';
    case 'builderHall':
      return '建筑大师大本营';
    case 'laboratory':
      return base === 'builder' ? '星空实验室' : '实验室';
    case 'starLaboratory':
      return '星空实验室';
    case 'heroHall':
      return '英雄殿堂';
    case 'blacksmith':
      return '铁匠铺';
  }
}
