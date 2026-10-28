// Doctor PC — proceso principal de Electron
// Ejecuta el motor PowerShell (engine/*.ps1), muestra los informes y gestiona las actualizaciones desde GitHub Releases.
const { app, BrowserWindow, ipcMain, dialog, shell, Menu, protocol, net, Notification, clipboard, nativeTheme, Tray, globalShortcut, screen, nativeImage } = require('electron');
const os = require('os');
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
const SENSORES_EXE = path.join(ENGINE_DIR, 'sensores', 'DoctorPC.Sensores.exe');
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
let tray = null;
let salirDeVerdad = false;
const iniciarOculto = process.argv.includes('--oculto');

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
    sonidos: true, volumen: 60,
    overlay: 'auto', overlayPos: 'sup-izq', overlayTam: 'normal', overlayFps: true,
    alertas: true, umbralCpu: 90, umbralGpu: 85, sensoresAvanzados: false,
    bandeja: true, iniciarConWindows: false, avisoBandeja: false,
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
    tienePerfil: !!g.Perfil,
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
    texto: g.Resumen || '',
    perfil: g.Perfil || null,
    ajustes: (j.Datos && j.Datos.Ajustes) || null,
    temperaturas: comoLista(j.Datos && j.Datos.Temperaturas),
    muestreo: j.Datos && j.Datos.Muestreo ? { modoJuego: !!j.Datos.Muestreo.ModoJuego, temps: j.Datos.Muestreo.Temps || null, segundos: j.Datos.Muestreo.Segundos } : null,
    juegosDetalle: comoLista(g.Juegos).map(x => ({ nombre: x.Nombre, estado: x.Estado, nivel: x.Nivel, enHDD: !!x.EnHDD, minGpu: x.MinGpu, recGpu: x.RecGpu, minCpu: x.MinCpu, recCpu: x.RecCpu, minRam: x.MinRam, recRam: x.RecRam, bajoMin: comoLista(x.BajoMinimo), bajoRec: comoLista(x.BajoRecomendado), notas: comoLista(x.Notas), catalogo: x.Catalogo })),
    idsHallazgos: comoLista(g.Hallazgos).map(h => h.Id),
    bloqueadas: comoLista(g.Plan && g.Plan.Bloqueadas).map(b => ({ nombre: b.Nombre, motivo: b.Motivo })),
    sensores: (j.Datos && j.Datos.Sensores) || null
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
// Ejecutable con permisos de administrador (UAC); el proceso devuelto es el intermediario que espera a que termine
function lanzarElevado(exe, args, visible, esperar) {
  const lista = args.map(x => '"' + String(x).replace(/"/g, '').replace(/\\$/, '\\.') + '"').join(' ');
  const cmd = `$ErrorActionPreference='Stop'; try { $p = Start-Process -FilePath ${citaPs(exe)} -Verb RunAs -WindowStyle ${visible ? 'Normal' : 'Hidden'} -PassThru -ArgumentList ${citaPs(lista)}; $p.WaitForExit(); exit $p.ExitCode } catch { [Console]::Error.WriteLine('UAC_RECHAZADO'); exit 1223 }`;
  return spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', comandoCodificado(cmd)], { windowsHide: true });
}

// Sigue un archivo de texto y entrega cada línea nueva
function seguirProgresoGenerico(ruta, alTexto) {
  const est = { offset: 0, resto: '' };
  const leer = () => {
    try {
      const st = fs.statSync(ruta);
      if (st.size > est.offset) {
        const fd = fs.openSync(ruta, 'r');
        const buf = Buffer.alloc(st.size - est.offset);
        fs.readSync(fd, buf, 0, buf.length, est.offset);
        fs.closeSync(fd);
        est.offset = st.size;
        const lineas = (est.resto + buf.toString('utf8')).split(/\r?\n/);
        est.resto = lineas.pop();
        lineas.forEach(l => { l = l.replace(/^\uFEFF/, '').trim(); if (l) alTexto(l); });
      }
    } catch (e) { /* aún no existe */ }
  };
  const timer = setInterval(leer, 400);
  return { parar: () => { clearInterval(timer); leer(); } };
}

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
      cargarJuegosConocidos();
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

// ------------------------------------------------------------------ monitor en vivo, sensores, juego, overlay y alertas
// El monitor (monitor.ps1) y el lector de sensores (DoctorPC.Sensores.exe) funcionan mientras alguien los necesite:
// una vista abierta (Monitor, Temperaturas), el overlay en juegos o las alertas de temperatura.
const subs = new Set();
const sensores = { proc: null, archivo: null, ctl: null, seg: null, ultimo: null, ts: 0, elevado: false, error: null, intentoSinAdmin: false };
const juego = { activo: false, n: '', pid: 0, pos: 0, neg: 0 };
let fpsPid = 0;               // proceso cuyos FPS mide PresentMon (0 = ninguno)
let enGrupoRendimiento = null; // el usuario está en "Usuarios del registro de rendimiento" (FPS sin administrador)
let ultimoMon = null;          // monitor del juego en primer plano
let tamOverlayReal = null;     // tamaño que pide el overlay según su contenido
const alerta = { cpu: { racha: 0, ultima: 0 }, gpu: { racha: 0, ultima: 0 } };
const historialAlertas = [];
const sesion = { inicio: Date.now(), cpu: null, gpu: null, hot: null, hist: [] };
let ctlMonitor = null;
let overlay = null;
let overlayForzado = null;     // null = según el modo; true/false = atajo de teclado o prueba
let juegosConocidos = { rutas: [], exes: new Set() };
let pawnioInstalado = null;

const NO_JUEGO = /^(explorer|doctor ?pc|electron|chrome|msedge|firefox|opera|brave|vivaldi|vlc|mpc-hc(64)?|potplayermini(64)?|wmplayer|video\.ui|applicationframehost|searchhost|searchapp|shellexperiencehost|startmenuexperiencehost|lockapp|textinputhost|teams|ms-teams|zoom|obs(64|32)?|discord|steamwebhelper|steam|epicgameslauncher|riotclientux|powershell|pwsh|windowsterminal|cmd|code|devenv|taskmgr|mstsc|photos|microsoft\.photos)$/i;
const RUTAS_JUEGO = /\\steamapps\\common\\|\\epic games\\|\\xboxgames\\|\\riot games\\|\\gog games\\|\\ea games\\|\\ubisoft game launcher\\games\\|\\battle\.net\\|\\games\\|\\juegos\\|\\roblox\\versions\\|\\modifiablewindowsapps\\/i;

function necesitaFondo(c) { return c.overlay !== 'off' || !!c.alertas; }
function intervaloDeseado() { return (subs.has('vista') || juego.activo || subs.has('prueba') || overlayForzado) ? 1000 : 2000; }
function escribirSeguro(f, t) { if (f) { try { fs.writeFileSync(f, String(t)); } catch (e) { /* nada */ } } }
function ctlSensores() { return String(intervaloDeseado()) + (fpsPid ? ` fps=${fpsPid}` : ''); }
function ajustarIntervalo() { const v = intervaloDeseado(); escribirSeguro(ctlMonitor, v); escribirSeguro(sensores.ctl, ctlSensores()); }

function actualizarMonitor() {
  const c = cargarConfig();
  if (necesitaFondo(c)) subs.add('fondo'); else subs.delete('fondo');
  if (subs.size) arrancarMonitor(); else pararMonitor();
  ajustarIntervalo();
}

function seguirJsonl(ruta, alObjeto) {
  return seguirProgresoGenerico(ruta, l => { if (l.startsWith('{')) { try { alObjeto(JSON.parse(l)); } catch (e) { /* línea incompleta */ } } });
}

function arrancarMonitor() {
  if (!monitor && fs.existsSync(SCRIPT_MONITOR)) {
    asegurarCarpeta(TEMP);
    ctlMonitor = path.join(TEMP, 'monitor.ctl');
    escribirSeguro(ctlMonitor, intervaloDeseado());
    const proc = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT_MONITOR, '-PadrePid', String(process.pid), '-ArchivoControl', ctlMonitor, '-IntervaloMs', String(intervaloDeseado())], { windowsHide: true });
    let resto = '';
    proc.stdout.on('data', d => {
      const t = resto + d.toString('utf8');
      const lineas = t.split(/\r?\n/);
      resto = lineas.pop();
      for (const l of lineas) { if (l.startsWith('{')) { try { procesarMuestra(JSON.parse(l)); } catch (e) { /* línea incompleta */ } } }
    });
    proc.on('close', () => { if (monitor === proc) monitor = null; });
    proc.on('error', () => { monitor = null; });
    monitor = proc;
  }
  arrancarSensores();
}
function pararMonitor() {
  if (monitor) { escribirSeguro(ctlMonitor, 'salir'); const m = monitor; monitor = null; setTimeout(() => { try { m.kill(); } catch (e) { /* nada */ } }, 2500); }
  pararSensores();
  if (overlay && overlay.isVisible()) overlay.hide();
}

function arrancarSensores(forzarSinAdmin) {
  if (sensores.proc || !fs.existsSync(SENSORES_EXE)) return;
  asegurarCarpeta(TEMP);
  const id = Date.now();
  sensores.archivo = path.join(TEMP, `sensores_${id}.jsonl`);
  sensores.ctl = path.join(TEMP, `sensores_${id}.ctl`);
  fs.writeFileSync(sensores.archivo, '');
  escribirSeguro(sensores.ctl, ctlSensores());
  const elevar = !forzarSinAdmin && !!cargarConfig().sensoresAvanzados;
  const args = ['--intervalo', String(intervaloDeseado()), '--padre', String(process.pid), '--salida', sensores.archivo, '--control', sensores.ctl];
  const proc = elevar ? lanzarElevado(SENSORES_EXE, args, false, false) : spawn(SENSORES_EXE, args, { windowsHide: true });
  sensores.proc = proc; sensores.elevado = elevar; sensores.error = null;
  const archivo = sensores.archivo;
  sensores.seg = seguirJsonl(archivo, j => {
    if (j.error) { sensores.error = j.error; return; }
    sensores.ultimo = j; sensores.ts = Date.now();
  });
  let err = '';
  if (proc.stderr) proc.stderr.on('data', d => { err += d.toString(); });
  proc.on('close', codigo => {
    if (sensores.proc !== proc) return;
    sensores.proc = null;
    if (sensores.seg) { sensores.seg.parar(); sensores.seg = null; }
    setTimeout(() => { try { fs.unlinkSync(archivo); } catch (e) { /* nada */ } }, 1500);
    if (elevar && esUacRechazado(codigo, err)) {
      sensores.error = 'Sin permiso de administrador: se leen solo los sensores básicos.';
      if (subs.size) arrancarSensores(true);
    }
  });
  proc.on('error', e => { sensores.proc = null; sensores.error = e.message; });
}
function pararSensores() {
  if (!sensores.proc) return;
  escribirSeguro(sensores.ctl, 'salir');
  const p = sensores.proc; sensores.proc = null;
  if (sensores.seg) { sensores.seg.parar(); sensores.seg = null; }
  setTimeout(() => { try { p.kill(); } catch (e) { /* nada */ } }, 3000);
}
function reiniciarSensores() { pararSensores(); sensores.ultimo = null; sensores.ts = 0; if (subs.size) setTimeout(() => arrancarSensores(), 1200); }

function comprobarPawnio() {
  return new Promise(resolve => {
    if (process.platform !== 'win32') { pawnioInstalado = false; return resolve(false); }
    const p = spawn('reg.exe', ['query', 'HKLM\\SYSTEM\\CurrentControlSet\\Services\\PawnIO'], { windowsHide: true });
    p.on('close', c => { pawnioInstalado = c === 0; resolve(pawnioInstalado); });
    p.on('error', () => { pawnioInstalado = false; resolve(false); });
  });
}

function acumular(st, v) {
  if (v == null || isNaN(v)) return st;
  if (!st) return { min: v, max: v, suma: v, n: 1 };
  st.min = Math.min(st.min, v); st.max = Math.max(st.max, v); st.suma += v; st.n++;
  return st;
}
const resumenStat = st => st ? { min: st.min, max: st.max, prom: Math.round(st.suma / st.n * 10) / 10 } : null;

function procesarMuestra(m) {
  const c = cargarConfig();
  const s = Date.now() - sensores.ts < 7000 ? sensores.ultimo : null;
  // CPU
  if (s && s.cpu && s.cpu.temp != null) { m.cpuTemp = s.cpu.temp; m.cpuTempFuente = 'sensor'; }
  else if (m.temp != null) { m.cpuTemp = m.temp; m.cpuTempFuente = 'lhm'; }
  else if (m.tempAcpi != null) { m.cpuTemp = m.tempAcpi; m.cpuTempFuente = 'acpi'; }
  else { m.cpuTemp = null; m.cpuTempFuente = null; }
  if (s && s.cpu) { m.cpuPot = s.cpu.potencia; m.cpuReloj = s.cpu.reloj; }
  // GPU: la dedicada con más carga
  const gpus = s ? (s.gpus || []) : [];
  const ded = gpus.filter(g => g.tipo !== 'GpuIntel');
  const g = (ded.length ? ded : gpus).slice().sort((a, b) => (b.carga || 0) - (a.carga || 0))[0];
  if (g) {
    m.gpuNombre = g.nombre; m.gpuTemp = g.temp; m.gpuHot = g.hotspot; m.gpuMemTemp = g.memTemp; m.gpuReloj = g.reloj; m.gpuPot = g.potencia;
    m.vramUsada = g.vramUsadaMB; m.vramTotal = g.vramTotalMB; m.gpuVentRpm = g.ventRpm; m.gpuVentPct = g.ventPct;
    if (g.carga != null && (m.gpu == null || g.tipo !== 'GpuIntel')) m.gpu = g.carga;
  }
  m.ventiladores = s ? (s.ventiladores || []) : [];
  m.sensores = { activo: !!s, admin: !!(s && s.admin), pawnio: s ? !!s.pawnio : pawnioInstalado, elevado: sensores.elevado, avanzados: !!c.sensoresAvanzados, error: sensores.error, hayLector: fs.existsSync(SENSORES_EXE) };
  // Sesión
  sesion.cpu = acumular(sesion.cpu, m.cpuTempFuente === 'acpi' ? null : m.cpuTemp);
  sesion.gpu = acumular(sesion.gpu, m.gpuTemp);
  sesion.hot = acumular(sesion.hot, m.gpuHot);
  sesion.hist.push({ t: Date.now(), cpu: m.cpuTemp, gpu: m.gpuTemp, cl: m.cpu, gl: m.gpu });
  if (sesion.hist.length > 300) sesion.hist.shift();
  m.sesion = { cpu: resumenStat(sesion.cpu), gpu: resumenStat(sesion.gpu), hot: resumenStat(sesion.hot), desde: sesion.inicio };
  // Juego en primer plano
  const esJ = esJuego(m.fg);
  if (esJ) { juego.pos++; juego.neg = 0; } else { juego.neg++; juego.pos = 0; }
  const antes = juego.activo;
  if (!juego.activo && juego.pos >= 3) { juego.activo = true; juego.n = m.fg.n; juego.pid = m.fg.pid || 0; }
  if (juego.activo && esJ && m.fg.n === juego.n && m.fg.pid) juego.pid = m.fg.pid;
  if (juego.activo && juego.neg >= 4) { juego.activo = false; juego.pid = 0; }
  if (antes !== juego.activo) { overlayForzado = null; ajustarIntervalo(); enviar('juego', { activo: juego.activo, n: juego.n }); }
  m.juego = { activo: juego.activo, n: juego.n };
  if (m.fg && m.fg.mon) ultimoMon = m.fg.mon;
  // FPS con PresentMon (dentro del lector de sensores): solo del juego y solo con el overlay visible
  let objetivo = 0;
  if (c.overlayFps !== false && overlayDeseado(c)) {
    if (juego.activo) objetivo = juego.pid;
    else if (m.fg && m.fg.pid && !NO_JUEGO.test(m.fg.n || '') && Number(m.fg.gpu) >= 5) objetivo = m.fg.pid;
  }
  if (objetivo !== fpsPid) { fpsPid = objetivo; escribirSeguro(sensores.ctl, ctlSensores()); }
  if (fpsPid) {
    const f = s && s.fps && s.fps.pid === fpsPid ? s.fps : null;
    m.fps = f ? { v: f.v, bajo1: f.bajo1, ms: f.ms, estado: f.estado } : { v: null, estado: fs.existsSync(SENSORES_EXE) ? 'iniciando' : 'sin-presentmon' };
  } else m.fps = null;
  // Overlay, alertas, bandeja y ventana
  actualizarOverlay(m, c);
  revisarAlertas(m, c);
  if (tray && m.t % 5 === 0) {
    const tt = ['Doctor PC'];
    if (m.cpuTemp != null) tt.push(`CPU ${Math.round(m.cpuTemp)} °C`);
    if (m.gpuTemp != null) tt.push(`GPU ${Math.round(m.gpuTemp)} °C`);
    tray.setToolTip(tt.join(' · '));
  }
  if (win && !win.isDestroyed() && win.isVisible()) enviar('monitor', m);
}

function esJuego(fg) {
  if (!fg || !fg.n || NO_JUEGO.test(fg.n)) return false;
  const ruta = String(fg.ruta || '').toLowerCase();
  if (ruta && (RUTAS_JUEGO.test(ruta) || juegosConocidos.rutas.some(r => ruta.startsWith(r)))) return true;
  if (juegosConocidos.exes.has(String(fg.n).toLowerCase() + '.exe')) return true;
  return !!fg.fs && Number(fg.gpu) >= 30;
}

function cargarJuegosConocidos() {
  const usuario = (() => { try { return os.userInfo().username; } catch (e) { return ''; } })();
  const rutas = new Set(), exes = new Set();
  for (const inf of listarInformes().slice(0, 5)) {
    const j = leerJson(inf.json);
    for (const x of comoLista(j && j.Datos && j.Datos.Juegos)) {
      if (x.Ruta) rutas.add(String(x.Ruta).replace('<usuario>', usuario).toLowerCase().replace(/\\+$/, '') + '\\');
      if (x.Exe) exes.add(String(x.Exe).toLowerCase());
    }
  }
  juegosConocidos = { rutas: [...rutas], exes };
}

// ---------------- overlay (estilo MSI Afterburner): ventana transparente, siempre encima y que no recibe clics
const TAM_OVERLAY = { normal: [170, 120], pequeno: [140, 100] };
function crearOverlay() {
  overlay = new BrowserWindow({
    width: 170, height: 120, frame: false, transparent: true, resizable: false, movable: false, focusable: false,
    skipTaskbar: true, alwaysOnTop: true, hasShadow: false, show: false, backgroundColor: '#00000000',
    webPreferences: { preload: path.join(__dirname, 'overlay-preload.js'), contextIsolation: true, sandbox: true, backgroundThrottling: false }
  });
  overlay.setIgnoreMouseEvents(true);
  overlay.setAlwaysOnTop(true, 'screen-saver');
  overlay.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  overlay.loadFile(path.join(__dirname, 'renderer', 'overlay.html'));
  overlay.on('closed', () => { overlay = null; });
}
function overlayDeseado(c) {
  if (overlayForzado !== null) return overlayForzado;
  if (c.overlay === 'siempre') return true;
  if (c.overlay === 'auto') return juego.activo;
  return false;
}
function posicionarOverlay(c) {
  const [w, h] = tamOverlayReal || TAM_OVERLAY[c.overlayTam === 'pequeno' ? 'pequeno' : 'normal'];
  let pant = screen.getPrimaryDisplay();
  try {
    if (ultimoMon) {
      const [l, t, r, b] = ultimoMon;
      const centro = { x: Math.round((l + r) / 2), y: Math.round((t + b) / 2) };
      const p = process.platform === 'win32' && screen.screenToDipPoint ? screen.screenToDipPoint(centro) : centro;
      pant = screen.getDisplayNearestPoint(p);
    }
  } catch (e) { /* pantalla principal */ }
  const b = pant.bounds, mg = 12, pos = c.overlayPos || 'sup-izq';
  const x = pos.endsWith('izq') ? b.x + mg : b.x + b.width - w - mg;
  const y = pos.startsWith('sup') ? b.y + mg : b.y + b.height - h - mg;
  const actual = overlay.getBounds();
  if (actual.x !== x || actual.y !== y || actual.width !== w || actual.height !== h) overlay.setBounds({ x, y, width: w, height: h });
}
function actualizarOverlay(m, c) {
  if (overlayDeseado(c)) {
    if (!overlay) crearOverlay();
    posicionarOverlay(c);
    if (!overlay.isVisible()) overlay.showInactive();
    overlay.setAlwaysOnTop(true, 'screen-saver');
    if (m) overlay.webContents.send('datos', {
      cpu: m.cpu, cpuTemp: m.cpuTemp, cpuTempFuente: m.cpuTempFuente, gpu: m.gpu, gpuTemp: m.gpuTemp, gpuHot: m.gpuHot,
      ramUsada: m.ramUsada, ramTotal: m.ramTotal, vramUsada: m.vramUsada, vramTotal: m.vramTotal, gpuReloj: m.gpuReloj, cpuReloj: m.cpuReloj,
      fps: m.fps, juego: juego.activo ? juego.n : '', umbralCpu: c.umbralCpu, umbralGpu: c.umbralGpu, tam: c.overlayTam, gpuNombre: m.gpuNombre || ''
    });
  } else if (overlay && overlay.isVisible()) overlay.hide();
}
function alternarOverlay() {
  const visible = !!(overlay && overlay.isVisible());
  overlayForzado = !visible;
  if (overlayForzado) subs.add('atajo'); else subs.delete('atajo');
  actualizarMonitor();
  if (!overlayForzado && overlay) overlay.hide();
}

ipcMain.on('overlay:tam', (e, d) => {
  if (!overlay || !d) return;
  const w = Math.max(60, Math.min(400, Math.round(Number(d.w) || 0))), h = Math.max(30, Math.min(300, Math.round(Number(d.h) || 0)));
  if (!tamOverlayReal || tamOverlayReal[0] !== w || tamOverlayReal[1] !== h) { tamOverlayReal = [w, h]; posicionarOverlay(cargarConfig()); }
});

// ---------------- FPS: PresentMon necesita administrador o el grupo "Usuarios del registro de rendimiento" (S-1-5-32-559)
function comprobarGrupoRendimiento() {
  return new Promise(resolve => {
    if (process.platform !== 'win32') return resolve(false);
    let out = '';
    const p = spawn('whoami.exe', ['/groups', '/fo', 'csv', '/nh'], { windowsHide: true });
    p.stdout.on('data', d => { out += d.toString(); });
    p.on('close', () => { enGrupoRendimiento = /S-1-5-32-559/i.test(out); resolve(enGrupoRendimiento); });
    p.on('error', () => resolve(false));
  });
}
function sidUsuario() {
  return new Promise(resolve => {
    let out = '';
    const p = spawn('whoami.exe', ['/user', '/fo', 'csv', '/nh'], { windowsHide: true });
    p.stdout.on('data', d => { out += d.toString(); });
    p.on('close', () => { const m = out.match(/S-1-5-[\d-]+/); resolve(m ? m[0] : null); });
    p.on('error', () => resolve(null));
  });
}
function estadoFps() {
  const s = Date.now() - sensores.ts < 7000 ? sensores.ultimo : null;
  const ultimo = s && s.fps ? s.fps.estado : null;
  return {
    incluido: s ? !!s.presentMon : fs.existsSync(path.join(path.dirname(SENSORES_EXE), 'PresentMon.exe')),
    admin: !!(s && s.admin), grupo: !!enGrupoRendimiento, ultimo,
    listo: !!(s && s.admin) || !!enGrupoRendimiento
  };
}
async function permitirFps() {
  const sid = await sidUsuario();
  if (!sid) return { ok: false, mensaje: 'No se pudo identificar tu usuario de Windows.' };
  const script = path.join(ENGINE_DIR, 'permitir-fps.ps1');
  return new Promise(resolve => {
    let err = '';
    const p = lanzarScript(script, ['-Sid', sid, '-Registro', REGISTRO], true, false);
    if (p.stderr) p.stderr.on('data', d => { err += d.toString(); });
    p.on('close', codigo => {
      if (esUacRechazado(codigo, err)) return resolve({ ok: false, mensaje: 'No se concedió el permiso de administrador.' });
      if (codigo === 0 || codigo === 2) return resolve({ ok: true, yaEstaba: codigo === 2, mensaje: codigo === 2 ? 'Tu usuario ya tenía el permiso. Si aún no ves los FPS, cierra sesión en Windows y vuelve a entrar.' : 'Listo. Cierra sesión en Windows y vuelve a entrar para que los FPS funcionen sin pedir permiso.' });
      resolve({ ok: false, mensaje: 'Windows no permitió el cambio (código ' + codigo + ').' });
    });
    p.on('error', e => resolve({ ok: false, mensaje: e.message }));
  });
}

// ---------------- alertas de temperatura
function revisarAlertas(m, c) {
  if (!c.alertas) return;
  const comps = [['cpu', m.cpuTempFuente === 'acpi' ? null : m.cpuTemp, Number(c.umbralCpu) || 90, 'procesador'], ['gpu', m.gpuTemp, Number(c.umbralGpu) || 85, 'tarjeta gráfica']];
  for (const [k, t, u, nombre] of comps) {
    const a = alerta[k];
    if (t != null && t >= u) a.racha++; else a.racha = 0;
    if (a.racha >= 3 && Date.now() - a.ultima > 5 * 60 * 1000) {
      a.ultima = Date.now();
      const ev = { comp: k, nombre, temp: Math.round(t), umbral: u, juego: juego.activo ? juego.n : null, fecha: Date.now() };
      historialAlertas.unshift(ev); if (historialAlertas.length > 20) historialAlertas.pop();
      enviar('alerta', ev);
      if (overlay && overlay.isVisible()) overlay.webContents.send('alerta', ev);
      if (Notification.isSupported() && (!win || !win.isVisible() || !win.isFocused())) {
        const n = new Notification({ title: `Tu ${nombre} está a ${ev.temp} °C`, body: `Supera tu límite de ${u} °C${ev.juego ? ' mientras juegas ' + ev.juego : ''}. Abre Doctor PC > Temperaturas para ver qué hacer.`, icon: path.join(__dirname, 'renderer', 'icon.png'), urgency: 'critical' });
        n.on('click', () => { mostrarVentana(); enviar('ir', 'temperaturas'); });
        n.show();
      }
    }
  }
}

// ---------------- bandeja del sistema e inicio con Windows
function mostrarVentana() {
  if (!win || win.isDestroyed()) crearVentana(true);
  else { if (win.isMinimized()) win.restore(); win.show(); win.focus(); }
}
function salirApp() { salirDeVerdad = true; app.quit(); }
function crearBandeja() {
  if (tray) return;
  try {
    const img = nativeImage.createFromPath(path.join(__dirname, 'renderer', 'icon.png')).resize({ width: 16, height: 16 });
    tray = new Tray(img);
    tray.setToolTip('Doctor PC');
    tray.on('click', mostrarVentana);
    actualizarMenuBandeja();
  } catch (e) { tray = null; }
}
function actualizarMenuBandeja() {
  if (!tray) return;
  const c = cargarConfig();
  const modo = v => () => { guardarConfig({ overlay: v }); aplicarConfigFondo(); enviar('config', cargarConfig()); };
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: 'Abrir Doctor PC', click: mostrarVentana },
    { type: 'separator' },
    { label: 'Overlay en juegos', submenu: [
      { label: 'Automático (al jugar)', type: 'radio', checked: c.overlay === 'auto', click: modo('auto') },
      { label: 'Siempre visible', type: 'radio', checked: c.overlay === 'siempre', click: modo('siempre') },
      { label: 'Desactivado', type: 'radio', checked: c.overlay === 'off', click: modo('off') }
    ] },
    { label: 'Mostrar u ocultar overlay (Ctrl+Mayús+O)', click: alternarOverlay },
    { label: 'Alertas de temperatura', type: 'checkbox', checked: !!c.alertas, click: i => { guardarConfig({ alertas: i.checked }); aplicarConfigFondo(); enviar('config', cargarConfig()); } },
    { type: 'separator' },
    { label: 'Salir de Doctor PC', click: salirApp }
  ]));
}
function aplicarInicioWindows(c) {
  if (!app.isPackaged || process.platform !== 'win32') return;
  try { app.setLoginItemSettings({ openAtLogin: !!c.iniciarConWindows, path: process.execPath, args: ['--oculto'] }); } catch (e) { /* nada */ }
}
function aplicarConfigFondo(antes) {
  const c = cargarConfig();
  actualizarMonitor();
  actualizarMenuBandeja();
  aplicarInicioWindows(c);
  if (antes && !!antes.sensoresAvanzados !== !!c.sensoresAvanzados) reiniciarSensores();
  if (overlay && !overlayDeseado(c)) overlay.hide();
}

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

function crearVentana(mostrarYa) {
  const oscuro = nativeTheme.shouldUseDarkColors;
  win = new BrowserWindow({
    width: 1260, height: 860, minWidth: 980, minHeight: 640,
    title: 'Doctor PC',
    icon: path.join(__dirname, 'renderer', 'icon.png'),
    backgroundColor: oscuro ? '#0d1117' : '#f3f5fb',
    autoHideMenuBar: true,
    show: false,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false, sandbox: true, autoplayPolicy: 'no-user-gesture-required' }
  });
  Menu.setApplicationMenu(null);
  win.once('ready-to-show', () => { if (mostrarYa || !iniciarOculto) win.show(); });
  // Al cerrar: si el overlay o las alertas están activos, Doctor PC sigue en la bandeja
  win.on('close', e => {
    const c = cargarConfig();
    if (!salirDeVerdad && c.bandeja && necesitaFondo(c) && tray) {
      e.preventDefault();
      win.hide();
      subs.delete('vista'); ajustarIntervalo();
      if (!c.avisoBandeja && Notification.isSupported()) {
        new Notification({ title: 'Doctor PC sigue en la bandeja', body: 'Vigila las temperaturas y muestra el overlay al jugar. Para cerrarlo del todo: clic derecho en el icono > Salir.', icon: path.join(__dirname, 'renderer', 'icon.png') }).show();
        guardarConfig({ avisoBandeja: true });
      }
    }
  });
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  win.webContents.setWindowOpenHandler(({ url }) => { if (/^https?:\/\//i.test(url)) shell.openExternal(url); return { action: 'deny' }; });
  win.webContents.on('will-navigate', (e, url) => { if (!url.startsWith('file:')) { e.preventDefault(); if (/^https?:\/\//i.test(url)) shell.openExternal(url); } });
  win.on('closed', () => { win = null; subs.delete('vista'); actualizarMonitor(); });
}

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => mostrarVentana());
  app.on('before-quit', () => { salirDeVerdad = true; });

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
      update: estadoUpdate,
      equipo: os.hostname(),
      hayLectorSensores: fs.existsSync(SENSORES_EXE)
    }));
    ipcMain.handle('config:guardar', (e, cfg) => { const antes = cargarConfig(); const c = guardarConfig(cfg || {}); aplicarConfigFondo(antes); return c; });
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
    ipcMain.handle('monitor:iniciar', () => { subs.add('vista'); actualizarMonitor(); return fs.existsSync(SCRIPT_MONITOR); });
    ipcMain.handle('monitor:detener', () => { subs.delete('vista'); actualizarMonitor(); return true; });
    ipcMain.handle('temps:estado', async () => ({
      sesion: { cpu: resumenStat(sesion.cpu), gpu: resumenStat(sesion.gpu), hot: resumenStat(sesion.hot), desde: sesion.inicio },
      hist: sesion.hist.slice(-300), alertas: historialAlertas,
      pawnio: await comprobarPawnio(), hayLector: fs.existsSync(SENSORES_EXE), sensoresElevados: sensores.elevado, errorSensores: sensores.error,
      juego: { activo: juego.activo, n: juego.n },
      fps: (await comprobarGrupoRendimiento(), estadoFps())
    }));
    ipcMain.handle('fps:permitir', () => permitirFps());
    ipcMain.handle('sensores:reiniciar', () => { reiniciarSensores(); return true; });
    ipcMain.handle('overlay:probar', () => {
      overlayForzado = true; subs.add('prueba'); actualizarMonitor();
      setTimeout(() => { overlayForzado = null; subs.delete('prueba'); actualizarMonitor(); if (overlay && !overlayDeseado(cargarConfig())) overlay.hide(); }, 10000);
      return true;
    });
    ipcMain.handle('abrir:ajuste', (e, id) => {
      const web = { amdweb: 'https://www.amd.com/es/support/download/drivers.html', nvidiaweb: 'https://www.nvidia.com/es-la/software/nvidia-app/', pawnio: 'https://pawnio.eu/', intelweb: 'https://www.intel.la/content/www/xl/es/support/detect.html' };
      const ms = { modojuego: 'ms-settings:gaming-gamemode', capturas: 'ms-settings:gaming-gamedvr', graficos: 'ms-settings:display-advancedgraphics', pantalla: 'ms-settings:display-advanced', integridad: 'windowsdefender://coreisolation', almacenamiento: 'ms-settings:storagesense', actualizaciones: 'ms-settings:windowsupdate' };
      if (web[id]) { shell.openExternal(web[id]); return true; }
      if (ms[id]) { shell.openExternal(ms[id]); return true; }
      if (id === 'energia') { spawn('control.exe', ['powercfg.cpl'], { detached: true, windowsHide: false }); return true; }
      if (id === 'inicio') { spawn('taskmgr.exe', ['/0', '/startup'], { detached: true }); return true; }
      if (id === 'amd') {
        const exe = 'C:\\Program Files\\AMD\\CNext\\CNext\\RadeonSoftware.exe';
        if (fs.existsSync(exe)) spawn(exe, [], { detached: true }); else shell.openExternal(web.amdweb);
        return true;
      }
      if (id === 'nvidia') {
        const exe = ['C:\\Program Files\\NVIDIA Corporation\\NVIDIA app\\CEF\\NVIDIA app.exe', 'C:\\Program Files\\NVIDIA Corporation\\NVIDIA App\\CEF\\NVIDIA App.exe'].find(f => fs.existsSync(f));
        if (exe) spawn(exe, [], { detached: true }); else shell.openExternal(web.nvidiaweb);
        return true;
      }
      return false;
    });
    ipcMain.handle('limpieza', (e, modo, elementos) => ejecutarLimpieza(modo === 'limpiar' ? 'limpiar' : 'analizar', elementos));
    ipcMain.handle('disco:unidades', () => listarUnidades());
    ipcMain.handle('disco:probar', (e, unidad) => pruebaDisco(unidad));
    ipcMain.handle('externo', (e, url) => { if (/^https:\/\//i.test(url)) shell.openExternal(url); return true; });
    ipcMain.handle('update:buscar', () => { buscarActualizacion(); return true; });
    ipcMain.handle('update:descargar', () => { if (autoUpdater && app.isPackaged) autoUpdater.downloadUpdate().catch(err => cambiarEstadoUpdate({ estado: 'error', mensaje: err.message })); return true; });
    ipcMain.handle('update:instalar', () => { if (autoUpdater && app.isPackaged) { salirDeVerdad = true; setImmediate(() => autoUpdater.quitAndInstall(true, true)); } return true; });

    configurarActualizador();
    crearVentana();
    crearBandeja();
    cargarJuegosConocidos();
    comprobarPawnio();
    comprobarGrupoRendimiento();
    aplicarInicioWindows(cargarConfig());
    try { globalShortcut.register('CommandOrControl+Shift+O', alternarOverlay); } catch (e) { /* atajo ocupado */ }
    actualizarMonitor();
    if (app.isPackaged) setTimeout(buscarActualizacion, 5000);
  });

  app.on('window-all-closed', () => {
    if (trabajo) cancelarAnalisis();
    const c = cargarConfig();
    if (!salirDeVerdad && c.bandeja && necesitaFondo(c) && tray) return;   // sigue en la bandeja
    pararMonitor();
    app.quit();
  });
  app.on('will-quit', () => { try { globalShortcut.unregisterAll(); } catch (e) { /* nada */ } pararMonitor(); });
}
