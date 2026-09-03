import { asRecord, optionalString } from '../json-decode';

export type OfficialPaginatedPage<Item> = {
  readonly items: readonly Item[];
  readonly before: string | undefined;
  readonly after: string | undefined;
};

export function createOfficialPaginatedPage<Item>(
  items: readonly Item[],
  before: string | undefined = undefined,
  after: string | undefined = undefined,
): OfficialPaginatedPage<Item> {
  return { items, before, after };
}

export function decodeOfficialPaginatedPage<Item>(
  value: unknown,
  decodeItem: (entry: unknown) => Item,
): OfficialPaginatedPage<Item> {
  const record = asRecord(value, 'OfficialPaginatedPage');
  const itemsRaw = record.items;
  if (!Array.isArray(itemsRaw)) {
    throw new TypeError('items 必填且必须是 array。');
  }
  const items = itemsRaw.map(decodeItem);
  const pagingRaw = record.paging;
  if (pagingRaw === undefined || pagingRaw === null) {
    return { items, before: undefined, after: undefined };
  }
  const paging = asRecord(pagingRaw, 'paging');
  const cursorsRaw = paging.cursors;
  if (cursorsRaw === undefined || cursorsRaw === null) {
    return { items, before: undefined, after: undefined };
  }
  const cursors = asRecord(cursorsRaw, 'cursors');
  return {
    items,
    before: optionalString(cursors.before),
    after: optionalString(cursors.after),
  };
}
