// Puente del overlay en juegos: solo recibe datos
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('overlay', {
  onDatos: fn => ipcRenderer.on('datos', (e, d) => fn(d)),
  onAlerta: fn => ipcRenderer.on('alerta', (e, d) => fn(d))
});
