import type { BuildingGroup } from './building-group-projection';
import type { VillageCategoryCompletion, VillageDetailGroup } from './village-detail-projection';
import { villageDetailParentedRows } from './village-detail-projection';

export type VillageDetailFlatRow =
  | {
      readonly kind: 'sectionHeader';
      readonly groupID: string;
      readonly stats: VillageCategoryCompletion | null | undefined;
    }
  | {
      readonly kind: 'craftTable';
      readonly groupID: string;
      readonly stats: VillageCategoryCompletion | null | undefined;
    }
  | {
      readonly kind: 'groupHeader';
      readonly groupID: string;
    }
  | {
      readonly kind: 'instance';
      readonly groupID: string;
      readonly instanceID: string;
      readonly leadingDivider: boolean;
    }
  | {
      readonly kind: 'legacy';
      readonly itemID: string;
      readonly groupID: string;
      readonly indented: boolean;
      readonly leadingDivider: boolean;
    };

export function villageDetailFlatRowId(row: VillageDetailFlatRow): string {
  switch (row.kind) {
    case 'sectionHeader':
      return `section:${row.groupID}`;
    case 'craftTable':
      return `craft:${row.groupID}`;
    case 'groupHeader':
      return `groupHeader:${row.groupID}`;
    case 'instance':
      return `instance:${row.groupID}:${row.instanceID}`;
    case 'legacy':
      return `legacy:${row.itemID}`;
  }
}

export function buildVillageDetailFlatRows(input: {
  readonly displayGroups: readonly VillageDetailGroup[];
  readonly statsByKey: Readonly<Record<string, VillageCategoryCompletion>>;
  readonly groupByInstanceID: Readonly<Record<string, BuildingGroup>>;
}): VillageDetailFlatRow[] {
  const rows: VillageDetailFlatRow[] = [];
  for (const group of input.displayGroups) {
    if (group.displayCategory === 'craftTable') {
      rows.push({
        kind: 'craftTable',
        groupID: group.id,
        stats: input.statsByKey[group.id],
      });
      continue;
    }

    rows.push({
      kind: 'sectionHeader',
      groupID: group.id,
      stats: input.statsByKey[group.id],
    });

    const orderedGroups: BuildingGroup[] = [];
    const seenGroupIDs = new Set<string>();
    const fallbackItems = [];
    for (const item of group.items) {
      const buildingGroup = input.groupByInstanceID[rawRecordID(item.id)];
      if (buildingGroup !== undefined) {
        if (!seenGroupIDs.has(buildingGroup.id)) {
          seenGroupIDs.add(buildingGroup.id);
          orderedGroups.push(buildingGroup);
        }
      } else {
        fallbackItems.push(item);
      }
    }

    for (const buildingGroup of orderedGroups) {
      rows.push({ kind: 'groupHeader', groupID: buildingGroup.id });
      buildingGroup.instances.forEach((instance, index) => {
        rows.push({
          kind: 'instance',
          groupID: buildingGroup.id,
          instanceID: instance.id,
          leadingDivider: index > 0,
        });
      });
    }

    const parented = villageDetailParentedRows(fallbackItems);
    parented.forEach((row, index) => {
      rows.push({
        kind: 'legacy',
        itemID: row.item.id,
        groupID: group.id,
        indented: false,
        leadingDivider: index > 0,
      });
      for (const child of row.children) {
        rows.push({
          kind: 'legacy',
          itemID: child.id,
          groupID: group.id,
          indented: true,
          leadingDivider: true,
        });
      }
    });
  }
  return rows;
}

export function groupBuildingGroupsByInstanceID(
  buildingGroups: readonly BuildingGroup[],
): Record<string, BuildingGroup> {
  const entries = buildingGroups.flatMap((group) =>
    group.instances.map((instance) => [instance.id, group] as const),
  );
  const result: Record<string, BuildingGroup> = {};
  for (const [instanceID, group] of entries) {
    if (result[instanceID] === undefined) {
      result[instanceID] = group;
    }
  }
  return result;
}

export function rawRecordID(id: string): string {
  return id.startsWith('agg:') ? id.slice(4) : id;
}

export const VillageDetailFlatRowProjection = {
  build: buildVillageDetailFlatRows,
  groupByInstanceID: groupBuildingGroupsByInstanceID,
  rawRecordID,
};
