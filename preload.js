// Puente seguro entre la interfaz y el proceso principal
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('doctor', {
  init: () => ipcRenderer.invoke('init'),
  guardarConfig: cfg => ipcRenderer.invoke('config:guardar', cfg),
  elegirCarpeta: () => ipcRenderer.invoke('carpeta:elegir'),
  elegirJson: () => ipcRenderer.invoke('json:elegir'),
  analizar: opciones => ipcRenderer.invoke('analizar', opciones),
  cancelar: () => ipcRenderer.invoke('cancelar'),
  empezarYa: () => ipcRenderer.invoke('empezar-ya'),
  informes: () => ipcRenderer.invoke('informes:listar'),
  abrirEnNavegador: ruta => ipcRenderer.invoke('informe:navegador', ruta),
  mostrarArchivo: ruta => ipcRenderer.invoke('informe:mostrar', ruta),
  borrarInforme: ruta => ipcRenderer.invoke('informe:borrar', ruta),
  abrirCarpetaInformes: () => ipcRenderer.invoke('carpeta:informes'),
  reparar: id => ipcRenderer.invoke('reparar', id),
  externo: url => ipcRenderer.invoke('externo', url),
  buscarUpdate: () => ipcRenderer.invoke('update:buscar'),
  descargarUpdate: () => ipcRenderer.invoke('update:descargar'),
  instalarUpdate: () => ipcRenderer.invoke('update:instalar'),
  onAnalisis: fn => ipcRenderer.on('analisis', (e, d) => fn(d)),
  onUpdate: fn => ipcRenderer.on('update', (e, d) => fn(d))
});
