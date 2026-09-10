/**
 * 受控剪贴板适配（#277-D 快捷导入）。
 * - 文本只由 Main 读取，绝不经过 renderer / preload / 日志。
 * - 内容只用于当前导入流程，不落盘、不进诊断。
 * - 本适配器是哑管道，不做长度截断：输入上限由 SnapshotImportService.quickPrepare
 *   在进入 domain parser 前用共享 MAX_IMPORT_TEXT_LENGTH 强制执行。
 */

export type ClipboardPort = {
  readText(): string | null;
};

function readElectronClipboardText(): string | null {
  try {
    // vitest（node）下 electron 导出的 clipboard 为 undefined：守卫后回 null。
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const electron = require('electron') as {
      clipboard?: { readText?: () => string };
    };
    const readText = electron.clipboard?.readText;
    if (typeof readText !== 'function') {
      return null;
    }
    return readText.call(electron.clipboard);
  } catch {
    return null;
  }
}

export const electronClipboardPort: ClipboardPort = {
  readText: readElectronClipboardText,
};

/** 测试/故事书用：返回固定文本，不碰系统剪贴板。 */
export function createFixedClipboardPort(text: string | null): ClipboardPort {
  return {
    readText: () => text,
  };
}
