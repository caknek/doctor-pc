// Doctor PC — proceso principal de Electron
// Ejecuta el motor PowerShell (engine/DoctorPC.ps1), muestra los informes y gestiona las actualizaciones desde GitHub Releases.
const { app, BrowserWindow, ipcMain, dialog, shell, Menu, protocol, net } = require('electron');
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');
const { pathToFileURL } = require('url');

let autoUpdater = null;
try { ({ autoUpdater } = require('electron-updater')); } catch (e) { autoUpdater = null; }

const ENGINE_DIR = app.isPackaged ? path.join(process.resourcesPath, 'engine') : path.join(__dirname, 'engine');
const SCRIPT = path.join(ENGINE_DIR, 'DoctorPC.ps1');
const INFORMES = path.join(app.getPath('documents'), 'DoctorPC', 'Informes');
const CONFIG = path.join(app.getPath('userData'), 'config.json');
const TEMP = path.join(app.getPath('temp'), 'DoctorPC');

const PAISES_POR_CODIGO = { VE: 'Venezuela', CO: 'Colombia', CL: 'Chile', MX: 'México', PE: 'Perú', AR: 'Argentina', EC: 'Ecuador', ES: 'España', US: 'Estados Unidos' };

let win = null;
let trabajo = null;        // análisis en curso
let estadoUpdate = { estado: 'inactivo' };

// ------------------------------------------------------------------ utilidades
function asegurarCarpeta(p) { try { fs.mkdirSync(p, { recursive: true }); } catch (e) { /* ya existe */ } }
function leerJson(ruta) {
  try { return JSON.parse(fs.readFileSync(ruta, 'utf8').replace(/^﻿/, '')); } catch (e) { return null; }
}
function enviar(canal, datos) { if (win && !win.isDestroyed()) win.webContents.send(canal, datos); }

function configPorDefecto() {
  let pais = 'Otro';
  try { pais = PAISES_POR_CODIGO[app.getLocaleCountryCode()] || 'Otro'; } catch (e) { /* sin país */ }
  return { pais, presupuesto: 50, sinLimite: false, usados: true, admin: true, modoJuegoSeg: 120, fuenteW: 0, carpetas: [], anonimo: false };
}
function cargarConfig() { return Object.assign(configPorDefecto(), leerJson(CONFIG) || {}); }
function guardarConfig(cfg) {
  asegurarCarpeta(path.dirname(CONFIG));
  fs.writeFileSync(CONFIG, JSON.stringify(Object.assign(cargarConfig(), cfg), null, 2), 'utf8');
}

function listarPaises() {
  const p = leerJson(path.join(ENGINE_DIR, 'datos', 'precios.json'));
  return p && p.paises ? Object.keys(p.paises) : ['Otro'];
}

function resumenInforme(rutaJson) {
  const j = leerJson(rutaJson);
  if (!j) return null;
  const html = rutaJson.replace(/\.json$/i, '.html');
  const d = j.Datos || {};
  const g = j.Diagnostico || {};
  const hall = Array.isArray(g.Hallazgos) ? g.Hallazgos : (g.Hallazgos ? [g.Hallazgos] : []);
  let mtime = 0;
  try { mtime = fs.statSync(rutaJson).mtimeMs; } catch (e) { /* nada */ }
  return {
    json: rutaJson,
    html: fs.existsSync(html) ? html : null,
    url: fs.existsSync(html) ? 'doctorpc://informes/' + encodeURIComponent(path.basename(html)) : null,
    nombre: path.basename(rutaJson, '.json'),
    equipo: d.Equipo || '',
    fecha: d.Fecha || '',
    creado: mtime,
    salud: g.Salud ? g.Salud.Puntos : null,
    etiqueta: g.Salud ? g.Salud.Etiqueta : '',
    pais: g.Pais || '',
    presupuesto: g.Plan ? g.Plan.Presupuesto : null,
    principales: hall.filter(h => h.Severidad !== 'info').slice(0, 3).map(h => ({ titulo: h.Titulo, severidad: h.Severidad })),
    reparaciones: [...new Set(hall.map(h => h.Reparacion).filter(Boolean))]
  };
}

function listarInformes() {
  asegurarCarpeta(INFORMES);
  let archivos = [];
  try { archivos = fs.readdirSync(INFORMES).filter(f => /^DoctorPC_.*\.json$/i.test(f)); } catch (e) { archivos = []; }
  return archivos.map(f => resumenInforme(path.join(INFORMES, f))).filter(Boolean).sort((a, b) => b.creado - a.creado);
}

// ------------------------------------------------------------------ motor PowerShell
function argumentosMotor(o, archivos) {
  const a = ['-ModoApp', '-ArchivoProgreso', archivos.progreso, '-ArchivoCancelar', archivos.cancelar, '-Salida', INFORMES];
  if (o.pais) a.push('-Pais', o.pais);
  a.push('-Presupuesto', String(o.sinLimite ? -1 : Math.max(0, Number(o.presupuesto) || 0)));
  a.push(o.usados ? '-IncluirUsados' : '-SoloNuevos');
  if (o.desdeJson) a.push('-DesdeJson', o.desdeJson);
  else {
    if (o.modoJuego) a.push('-ModoJuego', String(o.modoJuegoSeg || 120));
    if (Array.isArray(o.carpetas) && o.carpetas.length) a.push('-CarpetasJuegos', o.carpetas.join(';'));
    if (o.anonimo) a.push('-Anonimo');
  }
  if (Number(o.fuenteW) > 0) a.push('-FuenteWatts', String(Math.round(Number(o.fuenteW))));
  return a;
}

// Codifica un comando para powershell -EncodedCommand (UTF-16LE + Base64): evita problemas de comillas.
function comandoCodificado(texto) { return Buffer.from(texto, 'utf16le').toString('base64'); }
function citaPs(s) { return "'" + String(s).replace(/'/g, "''") + "'"; }

// Lanza el motor. Si "elevar", pide permisos de administrador (UAC) y espera a que termine.
function lanzarMotor(args, elevar, visible) {
  const base = ['-NoProfile', '-ExecutionPolicy', 'Bypass'];
  if (!elevar) {
    return spawn('powershell.exe', [...base, '-File', SCRIPT, ...args], { windowsHide: !visible });
  }
  const lista = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT, ...args].map(x => '"' + String(x).replace(/"/g, '').replace(/\\$/, '\\.') + '"').join(' ');
  const ventana = visible ? 'Normal' : 'Hidden';
  const cmd = `$ErrorActionPreference='Stop'; try { $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle ${ventana} -Wait -PassThru -ArgumentList ${citaPs(lista)}; exit $p.ExitCode } catch { [Console]::Error.WriteLine('UAC_RECHAZADO'); exit 1223 }`;
  return spawn('powershell.exe', [...base, '-EncodedCommand', comandoCodificado(cmd)], { windowsHide: true });
}

function procesarLinea(linea, estado) {
  if (!linea.startsWith('##')) return;
  const [tipo, ...p] = linea.slice(2).split('|');
  switch (tipo) {
    case 'PROGRESO': enviar('analisis', { tipo: 'progreso', pct: Number(p[0]) || 0, texto: p[1] || '' }); break;
    case 'AVISO': enviar('analisis', { tipo: 'aviso', texto: p[0] || '' }); break;
    case 'RESULTADO': estado.resultado = { html: p[0], json: p[1], salud: Number(p[2]), etiqueta: p[3] }; break;
    case 'ERROR': estado.error = p[0] || 'Error desconocido'; break;
    case 'CANCELADO': estado.cancelado = true; break;
    default: break;
  }
}

function iniciarAnalisis(opciones) {
  if (trabajo) return { ok: false, mensaje: 'Ya hay un análisis en curso.' };
  if (!fs.existsSync(SCRIPT)) return { ok: false, mensaje: 'No se encontró el motor de diagnóstico. Reinstala Doctor PC.' };
  asegurarCarpeta(TEMP); asegurarCarpeta(INFORMES);
  const id = Date.now();
  const archivos = { progreso: path.join(TEMP, `progreso_${id}.txt`), cancelar: path.join(TEMP, `cancelar_${id}.flag`) };
  fs.writeFileSync(archivos.progreso, '', 'utf8');
  const elevar = !!opciones.admin && !opciones.desdeJson;
  const proc = lanzarMotor(argumentosMotor(opciones, archivos), elevar, false);
  const estado = { offset: 0, resto: '', stderr: '', resultado: null, error: null, cancelado: false };

  const leer = () => {
    try {
      const buf = fs.readFileSync(archivos.progreso);
      if (buf.length > estado.offset) {
        const nuevo = estado.resto + buf.slice(estado.offset).toString('utf8');
        estado.offset = buf.length;
        const lineas = nuevo.split(/\r?\n/);
        estado.resto = lineas.pop();
        lineas.forEach(l => procesarLinea(l.replace(/^﻿/, '').trim(), estado));
      }
    } catch (e) { /* aún no existe */ }
  };
  const timer = setInterval(leer, 350);
  proc.stderr.on('data', d => { estado.stderr += d.toString(); });
  proc.stdout.on('data', () => { /* la salida útil va al archivo de progreso */ });

  trabajo = { proc, archivos, timer, estado, opciones };
  enviar('analisis', { tipo: 'inicio', modoJuego: !!opciones.modoJuego && !opciones.desdeJson, elevado: elevar });

  proc.on('close', codigo => {
    leer();
    if (estado.resto) { procesarLinea(estado.resto.trim(), estado); estado.resto = ''; }
    clearInterval(timer);
    const limpiar = () => { [archivos.progreso, archivos.cancelar, archivos.cancelar + '.empezar'].forEach(f => { try { fs.unlinkSync(f); } catch (e) { /* nada */ } }); };
    trabajo = null;
    if (estado.resultado) {
      const r = resumenInforme(estado.resultado.json) || {};
      enviar('analisis', { tipo: 'fin', informe: r });
    } else if (estado.cancelado) {
      enviar('analisis', { tipo: 'cancelado' });
    } else if (codigo === 1223 || /UAC_RECHAZADO/.test(estado.stderr)) {
      enviar('analisis', { tipo: 'error', codigo: 'uac', mensaje: 'No se concedió el permiso de administrador.' });
    } else {
      const detalle = estado.error || estado.stderr.split(/\r?\n/).filter(Boolean).slice(-3).join(' ') || `El motor terminó con código ${codigo}.`;
      enviar('analisis', { tipo: 'error', mensaje: detalle });
    }
    setTimeout(limpiar, 1000);
  });
  proc.on('error', err => {
    clearInterval(timer);
    trabajo = null;
    enviar('analisis', { tipo: 'error', mensaje: 'No se pudo iniciar PowerShell: ' + err.message });
  });
  return { ok: true };
}

function cancelarAnalisis() {
  if (!trabajo) return;
  try { fs.writeFileSync(trabajo.archivos.cancelar, '1'); } catch (e) { /* nada */ }
  // Si no es elevado, también podemos terminar el proceso directamente
  setTimeout(() => { if (trabajo && !trabajo.opciones.admin) { try { trabajo.proc.kill(); } catch (e) { /* nada */ } } }, 4000);
}

const REPARACIONES_CONSOLA = ['dism_sfc', 'chkdsk'];
function ejecutarReparacion(id) {
  const validas = ['dism_sfc', 'chkdsk', 'memoria', 'liberador', 'inicio', 'energia', 'graficos', 'actualizaciones'];
  if (!validas.includes(id)) return Promise.resolve({ ok: false, mensaje: 'Reparación desconocida.' });
  asegurarCarpeta(INFORMES);
  const consola = REPARACIONES_CONSOLA.includes(id);
  const args = consola ? ['-Accion', id, '-Salida', INFORMES] : ['-ModoApp', '-Accion', id, '-Salida', INFORMES];
  return new Promise(resolve => {
    const proc = lanzarMotor(args, consola, consola);
    let err = '';
    proc.stderr.on('data', d => { err += d.toString(); });
    proc.on('close', codigo => {
      if (codigo === 1223 || /UAC_RECHAZADO/.test(err)) resolve({ ok: false, mensaje: 'No se concedió el permiso de administrador.' });
      else if (consola) resolve({ ok: true, mensaje: 'Terminado. Revisa el resultado en la ventana que se abrió.' });
      else resolve({ ok: codigo === 0, mensaje: codigo === 0 ? 'Listo.' : 'No se pudo completar: ' + err.split(/\r?\n/).filter(Boolean).slice(-1)[0] });
    });
    proc.on('error', e => resolve({ ok: false, mensaje: e.message }));
  });
}

// ------------------------------------------------------------------ actualizaciones (GitHub Releases)
function textoNotas(n) {
  if (!n) return '';
  const t = Array.isArray(n) ? n.map(x => x.note || '').join('\n') : String(n);
  return t.replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').trim().slice(0, 1500);
}
function cambiarEstadoUpdate(e) { estadoUpdate = Object.assign({}, e); enviar('update', estadoUpdate); }

function configurarActualizador() {
  if (!autoUpdater) return;
  autoUpdater.autoDownload = false;
  autoUpdater.autoInstallOnAppQuit = true;
  autoUpdater.on('checking-for-update', () => cambiarEstadoUpdate({ estado: 'buscando' }));
  autoUpdater.on('update-available', info => cambiarEstadoUpdate({ estado: 'disponible', version: info.version, notas: textoNotas(info.releaseNotes), fecha: info.releaseDate }));
  autoUpdater.on('update-not-available', () => cambiarEstadoUpdate({ estado: 'al-dia' }));
  autoUpdater.on('download-progress', p => cambiarEstadoUpdate(Object.assign({}, estadoUpdate, { estado: 'descargando', pct: Math.round(p.percent || 0) })));
  autoUpdater.on('update-downloaded', info => cambiarEstadoUpdate({ estado: 'listo', version: info.version, notas: textoNotas(info.releaseNotes) }));
  autoUpdater.on('error', err => cambiarEstadoUpdate({ estado: 'error', mensaje: (err && err.message ? err.message : String(err)).split('\n')[0] }));
}

function buscarActualizacion() {
  if (!app.isPackaged || !autoUpdater) { cambiarEstadoUpdate({ estado: 'dev' }); return; }
  autoUpdater.checkForUpdates().catch(err => cambiarEstadoUpdate({ estado: 'error', mensaje: err.message }));
}

// ------------------------------------------------------------------ ventana
protocol.registerSchemesAsPrivileged([{ scheme: 'doctorpc', privileges: { standard: true, secure: true, supportFetchAPI: true } }]);

function crearVentana() {
  win = new BrowserWindow({
    width: 1200, height: 840, minWidth: 920, minHeight: 620,
    title: 'Doctor PC',
    icon: path.join(__dirname, 'renderer', 'icon.png'),
    backgroundColor: '#f4f6f9',
    autoHideMenuBar: true,
    show: false,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false, sandbox: true }
  });
  Menu.setApplicationMenu(null);
  win.once('ready-to-show', () => win.show());
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  win.webContents.setWindowOpenHandler(({ url }) => { if (/^https?:\/\//i.test(url)) shell.openExternal(url); return { action: 'deny' }; });
  win.webContents.on('will-navigate', (e, url) => { if (!url.startsWith('file:')) { e.preventDefault(); if (/^https?:\/\//i.test(url)) shell.openExternal(url); } });
  win.on('closed', () => { win = null; });
}

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => { if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });

  app.whenReady().then(() => {
    app.setAppUserModelId('com.caknek.doctorpc');
    // doctorpc://informes/<archivo>.html -> carpeta de informes (solo lectura, sin salir de esa carpeta)
    protocol.handle('doctorpc', req => {
      const u = new URL(req.url);
      const nombre = path.basename(decodeURIComponent(u.pathname));
      const ruta = path.join(INFORMES, nombre);
      if (u.hostname !== 'informes' || !fs.existsSync(ruta)) return new Response('No encontrado', { status: 404 });
      return net.fetch(pathToFileURL(ruta).toString());
    });

    // ---------------------------------------------------------- IPC
    ipcMain.handle('init', () => ({
      version: app.getVersion(),
      empaquetada: app.isPackaged,
      paises: listarPaises(),
      config: cargarConfig(),
      informes: listarInformes(),
      carpetaInformes: INFORMES,
      motorOk: fs.existsSync(SCRIPT),
      update: estadoUpdate
    }));
    ipcMain.handle('config:guardar', (e, cfg) => { guardarConfig(cfg || {}); return cargarConfig(); });
    ipcMain.handle('carpeta:elegir', async () => {
      const r = await dialog.showOpenDialog(win, { title: 'Carpeta donde tienes juegos', properties: ['openDirectory'] });
      return r.canceled ? null : r.filePaths[0];
    });
    ipcMain.handle('json:elegir', async () => {
      const r = await dialog.showOpenDialog(win, { title: 'Abrir datos de un equipo (Doctor PC .json)', filters: [{ name: 'Datos de Doctor PC', extensions: ['json'] }], properties: ['openFile'] });
      return r.canceled ? null : r.filePaths[0];
    });
    ipcMain.handle('analizar', (e, opciones) => iniciarAnalisis(opciones || {}));
    ipcMain.handle('cancelar', () => { cancelarAnalisis(); return true; });
    ipcMain.handle('empezar-ya', () => { if (trabajo) { try { fs.writeFileSync(trabajo.archivos.cancelar + '.empezar', '1'); } catch (e) { /* nada */ } } return true; });
    ipcMain.handle('informes:listar', () => listarInformes());
    ipcMain.handle('informe:navegador', (e, ruta) => (ruta && ruta.startsWith(INFORMES) ? shell.openPath(ruta) : 'Ruta no válida'));
    ipcMain.handle('informe:mostrar', (e, ruta) => { if (ruta && ruta.startsWith(INFORMES)) shell.showItemInFolder(ruta); return true; });
    ipcMain.handle('informe:borrar', async (e, rutaJson) => {
      if (!rutaJson || !rutaJson.startsWith(INFORMES)) return false;
      for (const f of [rutaJson, rutaJson.replace(/\.json$/i, '.html')]) { if (fs.existsSync(f)) { try { await shell.trashItem(f); } catch (err) { /* nada */ } } }
      return true;
    });
    ipcMain.handle('carpeta:informes', () => { asegurarCarpeta(INFORMES); return shell.openPath(INFORMES); });
    ipcMain.handle('reparar', (e, id) => ejecutarReparacion(String(id || '')));
    ipcMain.handle('externo', (e, url) => { if (/^https:\/\//i.test(url)) shell.openExternal(url); return true; });
    ipcMain.handle('update:buscar', () => { buscarActualizacion(); return true; });
    ipcMain.handle('update:descargar', () => { if (autoUpdater && app.isPackaged) autoUpdater.downloadUpdate().catch(err => cambiarEstadoUpdate({ estado: 'error', mensaje: err.message })); return true; });
    ipcMain.handle('update:instalar', () => { if (autoUpdater && app.isPackaged) setImmediate(() => autoUpdater.quitAndInstall(true, true)); return true; });

    configurarActualizador();
    crearVentana();
    if (app.isPackaged) setTimeout(buscarActualizacion, 5000);
  });

  app.on('window-all-closed', () => {
    if (trabajo) cancelarAnalisis();
    app.quit();
  });
}
