import type { DesktopBridge } from '@coc-helper/contracts';

declare global {
  interface Window {
    readonly cocHelper: DesktopBridge;
  }
}

export {};
