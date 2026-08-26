import { contextBridge, ipcRenderer } from 'electron';

import { createDesktopBridge } from './api';

const api = createDesktopBridge(
  (channel, request) => ipcRenderer.invoke(channel, request),
  (channel, request) => ipcRenderer.send(channel, request),
);

contextBridge.exposeInMainWorld('cocHelper', api);
