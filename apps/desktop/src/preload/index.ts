import { contextBridge, ipcRenderer } from 'electron';

import { createDesktopBridge } from './api';

const api = createDesktopBridge((channel, request) => ipcRenderer.invoke(channel, request));

contextBridge.exposeInMainWorld('cocHelper', api);
