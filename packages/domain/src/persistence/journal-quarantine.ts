import { existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs';

import { atomicWriteFile } from './atomic-write';

export function quarantinedJournalPath(journalURL: string): string {
  return `${journalURL}.quarantined`;
}

/**
 * 仅在用户显式 restore/reset 路径调用：把活跃 journal 原子复制到 .quarantined 后再删源。
 * `.quarantined` 语义 = 禁止启动自动 replay；只有 recovery.recoverJournal 才可 revive。
 */
export function quarantinePendingJournal(journalURL: string): void {
  if (!existsSync(journalURL)) {
    return;
  }
  const quarantineURL = quarantinedJournalPath(journalURL);
  const data = readFileSync(journalURL);
  atomicWriteFile(quarantineURL, data);
  rmSync(journalURL);
}

export function quarantinePendingJournals(journalURLs: readonly string[]): void {
  for (const journalURL of journalURLs) {
    quarantinePendingJournal(journalURL);
  }
}

/**
 * 仅用户显式 recovery.recoverJournal 调用。
 * bootstrap 不得调用：否则 reset/restore 写盘成功后的 crash 会把旧事务 replay 回新 villages。
 * 返回是否复活了 journal。
 */
export function reviveQuarantinedJournalIfNeeded(journalURL: string): boolean {
  if (existsSync(journalURL)) {
    return false;
  }
  const quarantineURL = quarantinedJournalPath(journalURL);
  if (!existsSync(quarantineURL)) {
    return false;
  }
  const data = readFileSync(quarantineURL);
  atomicWriteFile(journalURL, data);
  return true;
}

export function removeQuarantinedJournal(journalURL: string): void {
  const quarantineURL = quarantinedJournalPath(journalURL);
  if (existsSync(quarantineURL)) {
    rmSync(quarantineURL);
  }
}

/** 测试辅助：直接写入 quarantine 证据。 */
export function writeQuarantineFixture(journalURL: string, data: Uint8Array): void {
  writeFileSync(quarantinedJournalPath(journalURL), data);
}
