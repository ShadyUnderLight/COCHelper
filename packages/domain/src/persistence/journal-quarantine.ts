import { existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs';

import { atomicWriteFile } from './atomic-write';

export function quarantinedJournalPath(journalURL: string): string {
  return `${journalURL}.quarantined`;
}

/**
 * 仅在用户显式 restore/reset 路径调用：把活跃 journal 原子复制到 .quarantined 后再删源。
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
 * 启动恢复前：若仅有 quarantine 而无活跃 journal，则复活隔离件再交给 recoverIfNeeded。
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
