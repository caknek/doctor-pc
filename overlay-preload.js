// Puente del overlay en juegos: recibe datos e informa de su tamaño
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('overlay', {
  onDatos: fn => ipcRenderer.on('datos', (e, d) => fn(d)),
  onAlerta: fn => ipcRenderer.on('alerta', (e, d) => fn(d)),
  tam: (w, h) => ipcRenderer.send('overlay:tam', { w, h })
});
