export type TrackerBase = 'home' | 'builder';

export type TrackerCategory =
  | 'buildings'
  | 'traps'
  | 'troops'
  | 'spells'
  | 'siegeMachines'
  | 'heroes'
  | 'equipment'
  | 'pets'
  | 'guardians';

export type TrackerDisplayCategory = 'defense' | 'walls' | 'military' | 'craftTable';

const TRACKER_CATEGORY_TITLES: Record<TrackerCategory, string> = {
  buildings: '建筑与防御',
  traps: '陷阱',
  troops: '兵种',
  spells: '法术',
  siegeMachines: '攻城机器',
  heroes: '英雄',
  equipment: '装备',
  pets: '战宠',
  guardians: '守卫',
};

const TRACKER_DISPLAY_CATEGORY_TITLES: Record<TrackerDisplayCategory, string> = {
  defense: '防御建筑',
  walls: '城墙',
  military: '军事设施',
  craftTable: '精制台',
};

/** 快照 section 名 → 追踪类别；未知类别返回 undefined。 */
export function trackerCategoryFromSection(section: string): TrackerCategory | undefined {
  const canonical = section.endsWith('2') ? section.slice(0, -1) : section;
  switch (canonical) {
    case 'buildings':
      return 'buildings';
    case 'traps':
      return 'traps';
    case 'units':
      return 'troops';
    case 'spells':
      return 'spells';
    case 'siege_machines':
      return 'siegeMachines';
    case 'heroes':
      return 'heroes';
    case 'equipment':
      return 'equipment';
    case 'pets':
      return 'pets';
    case 'guardians':
      return 'guardians';
    default:
      return undefined;
  }
}

export function trackerCategoryTitle(category: TrackerCategory): string {
  return TRACKER_CATEGORY_TITLES[category];
}

export function trackerDisplayCategoryTitle(category: TrackerDisplayCategory): string {
  return TRACKER_DISPLAY_CATEGORY_TITLES[category];
}
