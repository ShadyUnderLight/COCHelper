import { COVERAGE_CONTRACT_FIELD } from '../account/types';

export const SNAPSHOT_HISTORY_OBJECT_SECTIONS = [
  'helpers',
  'guardians',
  'buildings',
  'traps',
  'decos',
  'obstacles',
  'units',
  'siege_machines',
  'heroes',
  'spells',
  'pets',
  'equipment',
  'buildings2',
  'traps2',
  'decos2',
  'obstacles2',
  'units2',
  'heroes2',
] as const;

export const SNAPSHOT_HISTORY_NUMERIC_SECTIONS = [
  'house_parts',
  'skins',
  'sceneries',
  'skins2',
  'sceneries2',
] as const;

export const SNAPSHOT_HISTORY_TIMER_FIELDS = [
  'timer',
  'helper_timer',
  'helper_cooldown',
] as const;

export const SNAPSHOT_HISTORY_ITEM_FIELDS = [
  'data',
  'lvl',
  'cnt',
  'timer',
  'helper_timer',
  'helper_cooldown',
  'helper_recurrent',
  'gear_up',
  'weapon',
  'types',
  'modules',
] as const;

export const SNAPSHOT_HISTORY_ALL_SECTIONS = new Set<string>([
  ...SNAPSHOT_HISTORY_OBJECT_SECTIONS,
  ...SNAPSHOT_HISTORY_NUMERIC_SECTIONS,
]);

export const SNAPSHOT_HISTORY_BUILDER_SECTIONS = new Set<string>(
  [...SNAPSHOT_HISTORY_OBJECT_SECTIONS, ...SNAPSHOT_HISTORY_NUMERIC_SECTIONS].filter((section) =>
    section.endsWith('2'),
  ),
);

export const SNAPSHOT_HISTORY_HOME_SECTIONS = new Set<string>(
  [...SNAPSHOT_HISTORY_OBJECT_SECTIONS, ...SNAPSHOT_HISTORY_NUMERIC_SECTIONS].filter(
    (section) => !section.endsWith('2'),
  ),
);

export { COVERAGE_CONTRACT_FIELD as SNAPSHOT_COVERAGE_CONTRACT_FIELD };
