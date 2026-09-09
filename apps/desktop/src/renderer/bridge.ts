import type { DesktopBridge } from '@coc-helper/contracts';

export function getDesktopBridge(): DesktopBridge {
  if (typeof window === 'undefined' || window.cocHelper === undefined) {
    throw new Error('DesktopBridge 未注入（preload 未就绪）。');
  }
  return window.cocHelper;
}
