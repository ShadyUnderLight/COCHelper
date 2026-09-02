export type SnapshotHistoryStoreError =
  | { readonly kind: 'unavailable'; readonly message: string }
  | { readonly kind: 'corrupt'; readonly message: string }
  | { readonly kind: 'unsupportedSchema'; readonly version: number }
  | { readonly kind: 'invalidEntry'; readonly message: string }
  | { readonly kind: 'writeFailed'; readonly message: string };

export type SnapshotHistoryServiceError =
  | { readonly kind: 'historyUnavailable'; readonly message: string }
  | { readonly kind: 'lineageConflict'; readonly message: string };

export function snapshotHistoryStoreErrorMessage(error: SnapshotHistoryStoreError): string {
  switch (error.kind) {
    case 'unavailable':
      return `历史不可用：${error.message}`;
    case 'corrupt':
      return `历史文件损坏：${error.message}`;
    case 'unsupportedSchema':
      return `历史文件版本不受支持：${String(error.version)}`;
    case 'invalidEntry':
      return `历史文件内容无效：${error.message}`;
    case 'writeFailed':
      return `历史写入失败：${error.message}`;
  }
}

export function snapshotHistoryServiceErrorMessage(error: SnapshotHistoryServiceError): string {
  switch (error.kind) {
    case 'historyUnavailable':
      return `历史不可用，导入已拒绝：${error.message}`;
    case 'lineageConflict':
      return `历史身份冲突，导入已拒绝：${error.message}`;
  }
}
