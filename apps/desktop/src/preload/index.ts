import { contextBridge, ipcRenderer } from 'electron';

import { createDesktopBridge } from './api';

const api = createDesktopBridge(
  (channel, request) => ipcRenderer.invoke(channel, request),
  (channel, request) => ipcRenderer.send(channel, request),
  (channel, listener) => {
    const handler = (_event: Electron.IpcRendererEvent, payload: unknown) => {
      listener(payload);
    };
    ipcRenderer.on(channel, handler);
    return () => {
      ipcRenderer.removeListener(channel, handler);
    };
  },
);

contextBridge.exposeInMainWorld('cocHelper', api);
