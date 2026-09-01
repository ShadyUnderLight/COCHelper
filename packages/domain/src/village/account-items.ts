import type { AccountItem, AccountSnapshot } from '../account';

function flattenItem(item: AccountItem, out: AccountItem[]): void {
  out.push(item);
  for (const child of item.types) {
    flattenItem(child, out);
  }
  for (const child of item.modules) {
    flattenItem(child, out);
  }
}

/** 按 section 排序、条目顺序稳定展开 types/modules 嵌套项。 */
export function flattenAccountItems(snapshot: AccountSnapshot): readonly AccountItem[] {
  const result: AccountItem[] = [];
  for (const section of Object.keys(snapshot.objectSections).sort()) {
    for (const item of snapshot.objectSections[section] ?? []) {
      flattenItem(item, result);
    }
  }
  return result;
}
