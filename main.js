// Doctor PC — proceso principal de Electron
// Ejecuta el motor PowerShell (engine/*.ps1), muestra los informes y gestiona las actualizaciones desde GitHub Releases.
const { app, BrowserWindow, ipcMain, dialog, shell, Menu, protocol, net, Notification, clipboard, nativeTheme } = require('electron');
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');
const { pathToFileURL } = require('url');

let autoUpdater = null;
try { ({ autoUpdater } = require('electron-updater')); } catch (e) { autoUpdater = null; }

const ENGINE_DIR = app.isPackaged ? path.join(process.resourcesPath, 'engine') : path.join(__dirname, 'engine');
const SCRIPT = path.join(ENGINE_DIR, 'DoctorPC.ps1');
const SCRIPT_MONITOR = path.join(ENGINE_DIR, 'monitor.ps1');
const SCRIPT_LIMPIEZA = path.join(ENGINE_DIR, 'limpieza.ps1');
const SCRIPT_DISCO = path.join(ENGINE_DIR, 'prueba-disco.ps1');
const BASE_DOCS = path.join(app.getPath('documents'), 'DoctorPC');
const INFORMES = path.join(BASE_DOCS, 'Informes');
const REGISTRO = path.join(INFORMES, 'registro_cambios.log');
const CONFIG = path.join(app.getPath('userData'), 'config.json');
const TEMP = path.join(app.getPath('temp'), 'DoctorPC');

const PAISES_POR_CODIGO = { VE: 'Venezuela', CO: 'Colombia', CL: 'Chile', MX: 'México', PE: 'Perú', AR: 'Argentina', EC: 'Ecuador', ES: 'España', US: 'Estados Unidos' };

let win = null;
let trabajo = null;        // análisis en curso
let monitor = null;        // proceso del monitor en vivo
let ocupado = null;        // limpieza o prueba de disco en curso
let estadoUpdate = { estado: 'inactivo' };

// ------------------------------------------------------------------ utilidades
function asegurarCarpeta(p) { try { fs.mkdirSync(p, { recursive: true }); } catch (e) { /* ya existe */ } }
function leerJson(ruta) {
  try { return JSON.parse(fs.readFileSync(ruta, 'utf8').replace(/^﻿/, '')); } catch (e) { return null; }
}
function enviar(canal, datos) { if (win && !win.isDestroyed()) win.webContents.send(canal, datos); }
function comoLista(x) { return Array.isArray(x) ? x : (x == null ? [] : [x]); }
function dentroDe(base, ruta) { const r = path.resolve(String(ruta || '')); return r.toLowerCase().startsWith(path.resolve(base).toLowerCase() + path.sep); }

function configPorDefecto() {
  let pais = 'Otro';
  try { pais = PAISES_POR_CODIGO[app.getLocaleCountryCode()] || 'Otro'; } catch (e) { /* sin país */ }
  return {
    pais, presupuesto: 50, sinLimite: false, usados: true, admin: true, modoJuegoSeg: 120, fuenteW: 0, carpetas: [], anonimo: false,
    tema: 'sistema', acento: 'azul', animaciones: true, notificaciones: true, bienvenida: false,
    tecnico: { activo: false, nombre: '', whatsapp: '', correo: '' }
  };
}
function cargarConfig() {
  const c = Object.assign(configPorDefecto(), leerJson(CONFIG) || {});
  c.tecnico = Object.assign(configPorDefecto().tecnico, c.tecnico || {});
  return c;
}
function guardarConfig(cfg) {
  asegurarCarpeta(path.dirname(CONFIG));
  const c = Object.assign(cargarConfig(), cfg);
  fs.writeFileSync(CONFIG, JSON.stringify(c, null, 2), 'utf8');
  aplicarTema(c);
  return c;
}
function aplicarTema(c) { nativeTheme.themeSource = c.tema === 'claro' ? 'light' : c.tema === 'oscuro' ? 'dark' : 'system'; }
function textoTecnico(c) {
  const t = c.tecnico || {};
  if (!t.activo || !String(t.nombre || '').trim()) return '';
  return [t.nombre, t.whatsapp ? 'WhatsApp ' + t.whatsapp : '', t.correo].map(x => String(x || '').replace(/\|/g, ' ').trim()).filter(Boolean).join('|');
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
  const hall = comoLista(g.Hallazgos);
  let mtime = 0;
  try { mtime = fs.statSync(rutaJson).mtimeMs; } catch (e) { /* nada */ }
  const ram = d.Ram ? (d.Ram.InstaladaGB || d.Ram.TotalGB) : null;
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
    conteo: ['critico', 'alto', 'medio', 'bajo'].reduce((a, s) => (a[s] = hall.filter(h => h.Severidad === s).length, a), {}),
    principales: hall.filter(h => h.Severidad !== 'info').slice(0, 3).map(h => ({ titulo: h.Titulo, severidad: h.Severidad })),
    reparaciones: [...new Set(hall.map(h => h.Reparacion).filter(Boolean))],
    juegos: comoLista(d.Juegos).length,
    equipoInfo: {
      cpu: d.Cpu ? d.Cpu.Nombre : '',
      gpu: comoLista(d.Gpus).filter(x => x && !x.Virtual).map(x => x.Nombre).join(' + '),
      ram: ram ? Math.round(ram) + ' GB' : '',
      discos: comoLista(d.Discos).map(x => `${x.Tipo} ${Math.round(x.TamanoGB)} GB`).join(' · '),
      windows: d.Sistema ? `${d.Sistema.Windows || ''} ${d.Sistema.VersionWindows || ''}`.trim() : '',
      modelo: d.Sistema ? `${d.Sistema.Fabricante || ''} ${d.Sistema.Modelo || ''}`.trim() : ''
    }
  };
}

function datosInforme(rutaJson) {
  if (!dentroDe(INFORMES, rutaJson)) return null;
  const j = leerJson(rutaJson);
  if (!j) return null;
  const g = j.Diagnostico || {};
  return {
    resumen: resumenInforme(rutaJson),
    hallazgos: comoLista(g.Hallazgos).map(h => ({ id: h.Id, titulo: h.Titulo, severidad: h.Severidad, categoria: h.Categoria })),
    juegos: comoLista(g.Juegos).map(x => ({ nombre: x.Nombre, estado: x.Estado, nivel: x.Nivel })),
    plan: comoLista(g.Plan && g.Plan.Dentro).map(c => ({ nombre: c.Nombre, min: c.Precio && c.Precio.Min, max: c.Precio && c.Precio.Max })),
    texto: g.Resumen || ''
  };
}

function listarInformes() {
  asegurarCarpeta(INFORMES);
  let archivos = [];
  try { archivos = fs.readdirSync(INFORMES).filter(f => /^DoctorPC_.*\.json$/i.test(f)); } catch (e) { archivos = []; }
  return archivos.map(f => resumenInforme(path.join(INFORMES, f))).filter(Boolean).sort((a, b) => b.creado - a.creado);
}

// ------------------------------------------------------------------ PowerShell
function comandoCodificado(texto) { return Buffer.from(texto, 'utf16le').toString('base64'); }
function citaPs(s) { return "'" + String(s).replace(/'/g, "''") + "'"; }

// Lanza un script. Si "elevar", pide permisos de administrador (UAC) y espera a que termine.
function lanzarScript(script, args, elevar, visible) {
  const base = ['-NoProfile', '-ExecutionPolicy', 'Bypass'];
  if (!elevar) return spawn('powershell.exe', [...base, '-File', script, ...args], { windowsHide: !visible });
  const lista = [...base, '-File', script, ...args].map(x => '"' + String(x).replace(/"/g, '').replace(/\\$/, '\\.') + '"').join(' ');
  const ventana = visible ? 'Normal' : 'Hidden';
  const cmd = `$ErrorActionPreference='Stop'; try { $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle ${ventana} -Wait -PassThru -ArgumentList ${citaPs(lista)}; exit $p.ExitCode } catch { [Console]::Error.WriteLine('UAC_RECHAZADO'); exit 1223 }`;
  return spawn('powershell.exe', [...base, '-EncodedCommand', comandoCodificado(cmd)], { windowsHide: true });
}
const esUacRechazado = (codigo, err) => codigo === 1223 || /UAC_RECHAZADO/.test(err || '');

// Sigue un archivo de progreso con líneas ##TIPO|a|b
function seguirProgreso(ruta, alLinea) {
  const est = { offset: 0, resto: '' };
  const leer = () => {
    try {
      const buf = fs.readFileSync(ruta);
      if (buf.length > est.offset) {
        const nuevo = est.resto + buf.slice(est.offset).toString('utf8');
        est.offset = buf.length;
        const lineas = nuevo.split(/\r?\n/);
        est.resto = lineas.pop();
        lineas.forEach(l => { l = l.replace(/^﻿/, '').trim(); if (l.startsWith('##')) { const [t, ...p] = l.slice(2).split('|'); alLinea(t, p); } });
      }
    } catch (e) { /* aún no existe */ }
  };
  const timer = setInterval(leer, 350);
  return { parar: () => { clearInterval(timer); leer(); if (est.resto.trim().startsWith('##')) { const [t, ...p] = est.resto.trim().slice(2).split('|'); alLinea(t, p); } } };
}

function barraTareas(pct) { if (win && !win.isDestroyed()) win.setProgressBar(pct == null ? -1 : Math.max(0, Math.min(1, pct / 100))); }

function avisar(titulo, cuerpo) {
  const c = cargarConfig();
  if (!c.notificaciones || !Notification.isSupported() || (win && win.isFocused())) return;
  const n = new Notification({ title: titulo, body: cuerpo, icon: path.join(__dirname, 'renderer', 'icon.png') });
  n.on('click', () => { if (win) { if (win.isMinimized()) win.restore(); win.show(); win.focus(); } });
  n.show();
}

// ------------------------------------------------------------------ análisis
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
  const tec = textoTecnico(cargarConfig());
  if (tec) a.push('-Tecnico', tec);
  return a;
}

function iniciarAnalisis(opciones) {
  if (trabajo) return { ok: false, mensaje: 'Ya hay un análisis en curso.' };
  if (!fs.existsSync(SCRIPT)) return { ok: false, mensaje: 'No se encontró el motor de diagnóstico. Reinstala Doctor PC.' };
  asegurarCarpeta(TEMP); asegurarCarpeta(INFORMES);
  const id = Date.now();
  const archivos = { progreso: path.join(TEMP, `progreso_${id}.txt`), cancelar: path.join(TEMP, `cancelar_${id}.flag`) };
  fs.writeFileSync(archivos.progreso, '', 'utf8');
  const elevar = !!opciones.admin && !opciones.desdeJson;
  const proc = lanzarScript(SCRIPT, argumentosMotor(opciones, archivos), elevar, false);
  const estado = { stderr: '', resultado: null, error: null, cancelado: false };

  const seg = seguirProgreso(archivos.progreso, (tipo, p) => {
    if (tipo === 'PROGRESO') { const pct = Number(p[0]) || 0; barraTareas(pct); enviar('analisis', { tipo: 'progreso', pct, texto: p[1] || '' }); }
    else if (tipo === 'AVISO') enviar('analisis', { tipo: 'aviso', texto: p[0] || '' });
    else if (tipo === 'RESULTADO') estado.resultado = { html: p[0], json: p[1], salud: Number(p[2]), etiqueta: p[3] };
    else if (tipo === 'ERROR') estado.error = p[0] || 'Error desconocido';
    else if (tipo === 'CANCELADO') estado.cancelado = true;
  });
  proc.stderr.on('data', d => { estado.stderr += d.toString(); });
  proc.stdout.on('data', () => { /* la salida útil va al archivo de progreso */ });

  trabajo = { proc, archivos, estado, opciones };
  barraTareas(1);
  enviar('analisis', { tipo: 'inicio', modoJuego: !!opciones.modoJuego && !opciones.desdeJson, elevado: elevar, desdeJson: !!opciones.desdeJson });

  proc.on('close', codigo => {
    seg.parar();
    barraTareas(null);
    trabajo = null;
    if (estado.resultado) {
      const r = resumenInforme(estado.resultado.json) || {};
      enviar('analisis', { tipo: 'fin', informe: r });
      if (!opciones.desdeJson) avisar('Análisis terminado', `Salud del equipo: ${r.salud}/100 (${r.etiqueta}). Toca para ver el informe.`);
    } else if (estado.cancelado) {
      enviar('analisis', { tipo: 'cancelado' });
    } else if (esUacRechazado(codigo, estado.stderr)) {
      enviar('analisis', { tipo: 'error', codigo: 'uac', mensaje: 'No se concedió el permiso de administrador.' });
    } else {
      const detalle = estado.error || estado.stderr.split(/\r?\n/).filter(Boolean).slice(-3).join(' ') || `El motor terminó con código ${codigo}.`;
      enviar('analisis', { tipo: 'error', mensaje: detalle });
    }
    setTimeout(() => { [archivos.progreso, archivos.cancelar, archivos.cancelar + '.empezar'].forEach(f => { try { fs.unlinkSync(f); } catch (e) { /* nada */ } }); }, 1000);
  });
  proc.on('error', err => { seg.parar(); barraTareas(null); trabajo = null; enviar('analisis', { tipo: 'error', mensaje: 'No se pudo iniciar PowerShell: ' + err.message }); });
  return { ok: true };
}

function cancelarAnalisis() {
  if (!trabajo) return;
  try { fs.writeFileSync(trabajo.archivos.cancelar, '1'); } catch (e) { /* nada */ }
  setTimeout(() => { if (trabajo && !trabajo.opciones.admin) { try { trabajo.proc.kill(); } catch (e) { /* nada */ } } }, 4000);
}

// ------------------------------------------------------------------ reparaciones
const REPARACIONES_CONSOLA = ['dism_sfc', 'chkdsk'];
function ejecutarReparacion(id) {
  const validas = ['dism_sfc', 'chkdsk', 'memoria', 'liberador', 'inicio', 'energia', 'graficos', 'actualizaciones'];
  if (!validas.includes(id)) return Promise.resolve({ ok: false, mensaje: 'Reparación desconocida.' });
  asegurarCarpeta(INFORMES);
  const consola = REPARACIONES_CONSOLA.includes(id);
  const args = consola ? ['-Accion', id, '-Salida', INFORMES] : ['-ModoApp', '-Accion', id, '-Salida', INFORMES];
  return new Promise(resolve => {
    const proc = lanzarScript(SCRIPT, args, consola, consola);
    let err = '';
    proc.stderr.on('data', d => { err += d.toString(); });
    proc.on('close', codigo => {
      if (esUacRechazado(codigo, err)) resolve({ ok: false, mensaje: 'No se concedió el permiso de administrador.' });
      else if (consola) resolve({ ok: true, mensaje: 'Terminado. Revisa el resultado en la ventana que se abrió.' });
      else resolve({ ok: codigo === 0, mensaje: codigo === 0 ? 'Listo.' : 'No se pudo completar: ' + (err.split(/\r?\n/).filter(Boolean).slice(-1)[0] || codigo) });
    });
    proc.on('error', e => resolve({ ok: false, mensaje: e.message }));
  });
}

// ------------------------------------------------------------------ monitor en vivo
function iniciarMonitor() {
  if (monitor || !fs.existsSync(SCRIPT_MONITOR)) return !!monitor;
  const proc = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT_MONITOR, '-PadrePid', String(process.pid)], { windowsHide: true });
  let resto = '';
  proc.stdout.on('data', d => {
    const t = resto + d.toString('utf8');
    const lineas = t.split(/\r?\n/);
    resto = lineas.pop();
    for (const l of lineas) { if (l.startsWith('{')) { try { enviar('monitor', JSON.parse(l)); } catch (e) { /* línea incompleta */ } } }
  });
  proc.on('close', () => { if (monitor === proc) monitor = null; });
  proc.on('error', () => { monitor = null; });
  monitor = proc;
  return true;
}
function detenerMonitor() { if (monitor) { try { monitor.kill(); } catch (e) { /* nada */ } monitor = null; } }

// ------------------------------------------------------------------ limpieza
function ejecutarLimpieza(modo, elementos) {
  if (ocupado) return Promise.resolve({ ok: false, mensaje: 'Hay otra tarea en curso.' });
  asegurarCarpeta(TEMP); asegurarCarpeta(INFORMES);
  const salida = path.join(TEMP, `limpieza_${Date.now()}.json`);
  const sel = (elementos || []).filter(x => /^[a-z_]+$/.test(x));
  const elevar = modo === 'limpiar' && sel.includes('temp_windows');
  const args = ['-Modo', modo, '-Salida', salida, '-Registro', REGISTRO];
  if (sel.length) args.push('-Elementos', sel.join(','));
  ocupado = 'limpieza';
  return new Promise(resolve => {
    const proc = lanzarScript(SCRIPT_LIMPIEZA, args, elevar, false);
    let err = '';
    proc.stderr.on('data', d => { err += d.toString(); });
    proc.on('close', codigo => {
      ocupado = null;
      const r = leerJson(salida);
      try { fs.unlinkSync(salida); } catch (e) { /* nada */ }
      if (r) resolve({ ok: true, datos: r });
      else if (esUacRechazado(codigo, err)) resolve({ ok: false, mensaje: 'No se concedió el permiso de administrador.' });
      else resolve({ ok: false, mensaje: 'No se pudo completar la limpieza.' });
    });
    proc.on('error', e => { ocupado = null; resolve({ ok: false, mensaje: e.message }); });
  });
}

// ------------------------------------------------------------------ prueba de disco
function listarUnidades() {
  return new Promise(resolve => {
    const p = spawn('powershell.exe', ['-NoProfile', '-Command', "Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { '{0}|{1}|{2}' -f $_.DeviceID, $_.Size, $_.VolumeName }"], { windowsHide: true });
    let o = '';
    p.stdout.on('data', d => { o += d.toString(); });
    p.on('close', () => resolve(o.split(/\r?\n/).filter(Boolean).map(l => { const [letra, tam, nombre] = l.split('|'); return { letra, gb: Math.round(Number(tam) / 1073741824), nombre }; })));
    p.on('error', () => resolve([{ letra: 'C:', gb: 0, nombre: '' }]));
  });
}
function pruebaDisco(unidad) {
  if (ocupado) return Promise.resolve({ ok: false, mensaje: 'Hay otra tarea en curso.' });
  asegurarCarpeta(TEMP);
  const id = Date.now();
  const salida = path.join(TEMP, `disco_${id}.json`);
  const progreso = path.join(TEMP, `disco_${id}.txt`);
  fs.writeFileSync(progreso, '', 'utf8');
  ocupado = 'disco';
  const seg = seguirProgreso(progreso, (tipo, p) => { if (tipo === 'PROGRESO') { barraTareas(Number(p[0])); enviar('disco', { pct: Number(p[0]) || 0, texto: p[1] || '' }); } });
  return new Promise(resolve => {
    const proc = lanzarScript(SCRIPT_DISCO, ['-Unidad', String(unidad || 'C').slice(0, 1), '-Salida', salida, '-ArchivoProgreso', progreso], false, false);
    let err = '';
    proc.stderr.on('data', d => { err += d.toString(); });
    proc.on('close', codigo => {
      seg.parar(); barraTareas(null); ocupado = null;
      const r = leerJson(salida);
      [salida, progreso].forEach(f => { try { fs.unlinkSync(f); } catch (e) { /* nada */ } });
      if (r && r.Ok) { resolve({ ok: true, datos: r }); avisar('Prueba de disco terminada', `${r.Tipo}: lectura ${r.LecturaSecuencial} MB/s`); }
      else if (r) resolve({ ok: false, mensaje: r.Error || 'La prueba no devolvió resultados.' });
            else resolve({ ok: false, mensaje: 'No se pudo completar la prueba.' });
    });
    proc.on('error', e => { seg.parar(); barraTareas(null); ocupado = null; resolve({ ok: false, mensaje: e.message }); });
  });
}

// ------------------------------------------------------------------ PDF y compartir
async function exportarPdf(rutaHtml) {
  if (!dentroDe(INFORMES, rutaHtml) || !fs.existsSync(rutaHtml)) return { ok: false, mensaje: 'No se encontró el informe.' };
  const def = path.join(app.getPath('documents'), path.basename(rutaHtml).replace(/\.html$/i, '.pdf'));
  const r = await dialog.showSaveDialog(win, { title: 'Guardar informe en PDF', defaultPath: def, filters: [{ name: 'PDF', extensions: ['pdf'] }] });
  if (r.canceled || !r.filePath) return { ok: false, cancelado: true };
  const temaAntes = nativeTheme.themeSource;
  nativeTheme.themeSource = 'light';
  const w = new BrowserWindow({ show: false, width: 1100, height: 1400, webPreferences: { sandbox: true, javascript: true } });
  try {
    await w.loadFile(rutaHtml);
    await w.webContents.executeJavaScript("document.querySelectorAll('details').forEach(d => d.open = true); document.querySelectorAll('nav,button,.noprint').forEach(e => e.style.display = 'none'); true");
    const pdf = await w.webContents.printToPDF({ printBackground: true, pageSize: 'A4', margins: { top: 0.4, bottom: 0.4, left: 0.4, right: 0.4 } });
    fs.writeFileSync(r.filePath, pdf);
    shell.showItemInFolder(r.filePath);
    return { ok: true, ruta: r.filePath };
  } catch (e) {
    return { ok: false, mensaje: e.message };
  } finally {
    w.destroy();
    nativeTheme.themeSource = temaAntes;
  }
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
  autoUpdater.on('update-available', info => {
    cambiarEstadoUpdate({ estado: 'disponible', version: info.version, notas: textoNotas(info.releaseNotes), fecha: info.releaseDate });
    avisar('Nueva versión de Doctor PC', `La versión ${info.version} está disponible. Ábrela desde "Acerca de".`);
  });
  autoUpdater.on('update-not-available', () => cambiarEstadoUpdate({ estado: 'al-dia' }));
  autoUpdater.on('download-progress', p => { barraTareas(p.percent); cambiarEstadoUpdate(Object.assign({}, estadoUpdate, { estado: 'descargando', pct: Math.round(p.percent || 0) })); });
  autoUpdater.on('update-downloaded', info => { barraTareas(null); cambiarEstadoUpdate({ estado: 'listo', version: info.version, notas: textoNotas(info.releaseNotes) }); });
  autoUpdater.on('error', err => { barraTareas(null); cambiarEstadoUpdate({ estado: 'error', mensaje: (err && err.message ? err.message : String(err)).split('\n')[0] }); });
}

function buscarActualizacion() {
  if (!app.isPackaged || !autoUpdater) { cambiarEstadoUpdate({ estado: 'dev' }); return; }
  autoUpdater.checkForUpdates().catch(err => cambiarEstadoUpdate({ estado: 'error', mensaje: err.message }));
}

// ------------------------------------------------------------------ ventana
protocol.registerSchemesAsPrivileged([{ scheme: 'doctorpc', privileges: { standard: true, secure: true, supportFetchAPI: true } }]);

function crearVentana() {
  const oscuro = nativeTheme.shouldUseDarkColors;
  win = new BrowserWindow({
    width: 1260, height: 860, minWidth: 980, minHeight: 640,
    title: 'Doctor PC',
    icon: path.join(__dirname, 'renderer', 'icon.png'),
    backgroundColor: oscuro ? '#0d1117' : '#f3f5fb',
    autoHideMenuBar: true,
    show: false,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false, sandbox: true }
  });
  Menu.setApplicationMenu(null);
  win.once('ready-to-show', () => win.show());
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  win.webContents.setWindowOpenHandler(({ url }) => { if (/^https?:\/\//i.test(url)) shell.openExternal(url); return { action: 'deny' }; });
  win.webContents.on('will-navigate', (e, url) => { if (!url.startsWith('file:')) { e.preventDefault(); if (/^https?:\/\//i.test(url)) shell.openExternal(url); } });
  win.on('closed', () => { win = null; detenerMonitor(); });
}

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => { if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });

  app.whenReady().then(() => {
    app.setAppUserModelId('com.caknek.doctorpc');
    aplicarTema(cargarConfig());
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
    ipcMain.handle('config:guardar', (e, cfg) => guardarConfig(cfg || {}));
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
    ipcMain.handle('informe:datos', (e, ruta) => datosInforme(ruta));
    ipcMain.handle('informe:navegador', (e, ruta) => (dentroDe(INFORMES, ruta) ? shell.openPath(ruta) : 'Ruta no válida'));
    ipcMain.handle('informe:mostrar', (e, ruta) => { if (dentroDe(INFORMES, ruta)) shell.showItemInFolder(ruta); return true; });
    ipcMain.handle('informe:pdf', (e, ruta) => exportarPdf(ruta));
    ipcMain.handle('informe:borrar', async (e, rutaJson) => {
      if (!dentroDe(INFORMES, rutaJson)) return false;
      for (const f of [rutaJson, rutaJson.replace(/\.json$/i, '.html')]) { if (fs.existsSync(f)) { try { await shell.trashItem(f); } catch (err) { /* nada */ } } }
      return true;
    });
    ipcMain.handle('carpeta:informes', () => { asegurarCarpeta(INFORMES); return shell.openPath(INFORMES); });
    ipcMain.handle('copiar', (e, texto) => { clipboard.writeText(String(texto || '')); return true; });
    ipcMain.handle('whatsapp', (e, texto) => { shell.openExternal('https://wa.me/?text=' + encodeURIComponent(String(texto || '').slice(0, 3500))); return true; });
    ipcMain.handle('reparar', (e, id) => ejecutarReparacion(String(id || '')));
    ipcMain.handle('monitor:iniciar', () => iniciarMonitor());
    ipcMain.handle('monitor:detener', () => { detenerMonitor(); return true; });
    ipcMain.handle('limpieza', (e, modo, elementos) => ejecutarLimpieza(modo === 'limpiar' ? 'limpiar' : 'analizar', elementos));
    ipcMain.handle('disco:unidades', () => listarUnidades());
    ipcMain.handle('disco:probar', (e, unidad) => pruebaDisco(unidad));
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
    detenerMonitor();
    app.quit();
  });
}
