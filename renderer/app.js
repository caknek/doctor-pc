// Doctor PC — interfaz
'use strict';
const $ = s => document.querySelector(s);
const $$ = s => [...document.querySelectorAll(s)];
const api = window.doctor;

const REPARACIONES = [
  { id: 'dism_sfc', nivel: 3, admin: true, icono: 'escudo', nombre: 'Comprobar y reparar archivos de Windows (DISM + SFC)',
    desc: 'DISM repara la imagen de Windows (descarga componentes oficiales, necesita internet) y SFC restaura archivos de sistema dañados. No borra tus archivos ni programas. Tarda entre 15 y 40 minutos: no apagues el equipo. Se abrirá una ventana con el progreso.' },
  { id: 'chkdsk', nivel: 2, admin: true, icono: 'disco', nombre: 'Revisar el disco del sistema (solo lectura)',
    desc: 'Ejecuta chkdsk /scan: analiza el sistema de archivos sin repararlo ni reiniciar. Si encuentra errores, te dirá cómo programar la reparación.' },
  { id: 'memoria', nivel: 2, admin: true, icono: 'ram', nombre: 'Programar el Diagnóstico de memoria de Windows',
    desc: 'Abre la herramienta oficial. Te preguntará si quieres reiniciar ahora o en el próximo arranque. La prueba dura unos 15-20 minutos.' },
  { id: 'liberador', nivel: 2, admin: false, icono: 'limpiar', nombre: 'Abrir el Liberador de espacio en disco',
    desc: 'Abre la herramienta oficial. Tú eliges qué borrar. Pulsa "Limpiar archivos del sistema" para ver la caché de Windows Update y versiones anteriores.' },
  { id: 'inicio', nivel: 2, admin: false, icono: 'rayo', nombre: 'Elegir qué programas arrancan con Windows',
    desc: 'Abre el Administrador de tareas en "Aplicaciones de arranque". Desactivar un programa ahí es reversible.' },
  { id: 'energia', nivel: 3, admin: false, icono: 'monitor', nombre: 'Cambiar el plan de energía a Equilibrado',
    desc: 'Cambia el plan de energía activo. El plan anterior queda anotado en el registro de cambios para poder volver a él.' },
  { id: 'graficos', nivel: 2, admin: false, icono: 'gpu', nombre: 'Elegir la tarjeta gráfica de cada juego',
    desc: 'Abre Configuración > Pantalla > Gráficos para asignar "Alto rendimiento" a tus juegos (útil en portátiles con dos gráficas).' },
  { id: 'actualizaciones', nivel: 2, admin: false, icono: 'descarga', nombre: 'Buscar drivers en Windows Update',
    desc: 'Abre las actualizaciones opcionales, donde Windows ofrece drivers adicionales. Tú decides qué instalar.' }
];
const ACENTOS = [['azul', '#2563eb'], ['violeta', '#7c3aed'], ['verde', '#059669'], ['naranja', '#ea580c'], ['rosa', '#db2777'], ['cian', '#0891b2']];
const PASOS_ANALISIS = [
  { h: 13, t: 'Procesador, gráfica y memoria' }, { h: 22, t: 'Discos y temperaturas' }, { h: 36, t: 'Registros de Windows y drivers' },
  { h: 45, t: 'Juegos instalados' }, { h: 91, t: 'Medición de rendimiento' }, { h: 96, t: 'Diagnóstico' }, { h: 101, t: 'Informe listo' }
];
const PASOS_JSON = [{ h: 31, t: 'Datos del equipo' }, { h: 96, t: 'Diagnóstico' }, { h: 101, t: 'Informe listo' }];

let estado = { config: {}, paises: [], informes: [], informeActual: null, analizando: false, update: {}, pasos: PASOS_ANALISIS, vista: 'inicio', cacheDatos: {}, equipo: '', pasosHechos: 0 };
const VISTAS_MONITOR = ['monitor', 'temperaturas'];
const sonar = (fn, ...a) => { try { if (window.Sonidos && estado.config.sonidos !== false) window.Sonidos[fn](...a); } catch (e) { /* sin audio */ } };

// ================================================================== utilidades
function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }
const ico = n => `<svg class="i"><use href="#i-${n}"/></svg>`;
function toast(texto, ms = 3500) {
  const t = $('#toast');
  t.innerHTML = ico('check') + '<span>' + esc(texto) + '</span>';
  t.classList.remove('oculto'); t.style.animation = 'none'; void t.offsetWidth; t.style.animation = '';
  clearTimeout(toast._t); toast._t = setTimeout(() => t.classList.add('oculto'), ms);
}
const colorSalud = p => p >= 85 ? 'var(--ok)' : p >= 65 ? 'var(--medio)' : p >= 40 ? 'var(--alto)' : 'var(--crit)';
const colorCarga = (v, a = 60, b = 85) => v >= b ? 'var(--crit)' : v >= a ? 'var(--medio)' : 'var(--ok)';
function fecha(f, creado) {
  const d = f ? new Date(f) : new Date(creado);
  return isNaN(d) ? '' : d.toLocaleString('es', { dateStyle: 'medium', timeStyle: 'short' });
}
function fmtBytes(b) {
  b = Number(b) || 0;
  if (b >= 1073741824) return (b / 1073741824).toLocaleString('es', { maximumFractionDigits: 2 }) + ' GB';
  if (b >= 1048576) return (b / 1048576).toLocaleString('es', { maximumFractionDigits: 1 }) + ' MB';
  if (b >= 1024) return Math.round(b / 1024) + ' KB';
  return b + ' B';
}
const fmtVel = kb => kb >= 1024 ? (kb / 1024).toLocaleString('es', { maximumFractionDigits: 1 }) + ' MB/s' : Math.round(kb) + ' KB/s';
function opcionesPais(sel, valor) { sel.innerHTML = estado.paises.map(p => `<option ${p === valor ? 'selected' : ''}>${esc(p)}</option>`).join(''); }
const animado = () => !document.documentElement.classList.contains('sin-anim') && !matchMedia('(prefers-reduced-motion: reduce)').matches;

function contar(el, hasta, dur = 1100, fmt = x => Math.round(x)) {
  if (!el) return;
  const desde = Number(el.dataset.v || 0);
  el.dataset.v = hasta;
  if (!animado()) { el.textContent = fmt(hasta); return; }
  const t0 = performance.now();
  const paso = t => {
    const k = Math.min(1, (t - t0) / dur), e = 1 - Math.pow(1 - k, 3);
    el.textContent = fmt(desde + (hasta - desde) * e);
    if (k < 1) requestAnimationFrame(paso);
  };
  requestAnimationFrame(paso);
}

function anillo(p, tam = 70) {
  const v = p == null ? 0 : Number(p);
  return `<div class="anillo" style="--t:${tam}px" data-p="${v}"><svg viewBox="0 0 100 100"><circle class="fondo" cx="50" cy="50" r="42"/><circle class="valor" cx="50" cy="50" r="42" style="stroke:${colorSalud(v)}"/></svg><div class="num">${p == null ? '–' : '0'}</div></div>`;
}
function animarAnillos(raiz = document) {
  raiz.querySelectorAll('.anillo:not([data-ok])').forEach(a => {
    a.dataset.ok = 1;
    const p = Number(a.dataset.p) || 0;
    requestAnimationFrame(() => requestAnimationFrame(() => { a.querySelector('.valor').style.strokeDashoffset = 264 * (1 - p / 100); }));
    if (a.querySelector('.num').textContent !== '–') contar(a.querySelector('.num'), p, 1300);
  });
}
function escalonar(cont) { [...cont.children].forEach((c, i) => c.style.setProperty('--i', i)); cont.classList.add('anim'); }

function modal({ titulo, html, confirmar = 'Continuar', exigir = null, peligro = false, sinCancelar = false }) {
  return new Promise(res => {
    $('#m-titulo').textContent = titulo;
    $('#m-cuerpo').innerHTML = html + (exigir ? `<p class="sub">Escribe <b>${esc(exigir)}</b> para confirmar.</p><input type="text" id="m-input" autocomplete="off">` : '');
    const si = $('#m-si'), no = $('#m-no');
    si.textContent = confirmar; si.classList.toggle('peligro', peligro); no.classList.toggle('oculto', sinCancelar);
    const input = $('#m-input');
    si.disabled = !!exigir;
    if (input) { input.oninput = () => { si.disabled = input.value !== exigir; }; setTimeout(() => input.focus(), 60); }
    const cerrar = v => { $('#modal').classList.add('oculto'); si.onclick = no.onclick = null; res(v); };
    si.onclick = () => cerrar(true); no.onclick = () => cerrar(false);
    $('#modal').classList.remove('oculto');
  });
}

// ================================================================== confeti
function confeti(n = 150) {
  if (!animado()) return;
  const c = $('#confeti'), ctx = c.getContext('2d');
  c.width = innerWidth; c.height = innerHeight;
  const cs = getComputedStyle(document.documentElement);
  const colores = [cs.getPropertyValue('--acc'), cs.getPropertyValue('--acc-b'), '#22c55e', '#f59e0b', '#ec4899', '#38bdf8'].map(x => x.trim());
  const ps = Array.from({ length: n }, () => ({
    x: innerWidth / 2 + (Math.random() - .5) * 200, y: innerHeight * .35, vx: (Math.random() - .5) * 16, vy: -Math.random() * 14 - 4,
    r: Math.random() * 6 + 4, a: Math.random() * 6, va: (Math.random() - .5) * .4, col: colores[Math.floor(Math.random() * colores.length)]
  }));
  const t0 = performance.now();
  const frame = t => {
    ctx.clearRect(0, 0, c.width, c.height);
    ps.forEach(p => { p.vy += .35; p.vx *= .99; p.x += p.vx; p.y += p.vy; p.a += p.va; ctx.save(); ctx.translate(p.x, p.y); ctx.rotate(p.a); ctx.fillStyle = p.col; ctx.fillRect(-p.r / 2, -p.r / 4, p.r, p.r / 2); ctx.restore(); });
    if (t - t0 < 3200) requestAnimationFrame(frame); else ctx.clearRect(0, 0, c.width, c.height);
  };
  requestAnimationFrame(frame);
}

// ================================================================== navegación
function mostrar(vista) {
  const antes = estado.vista;
  estado.vista = vista;
  $$('.vista').forEach(v => v.classList.toggle('activa', v.id === 'v-' + vista));
  $$('.nav').forEach(b => b.classList.toggle('activo', b.dataset.vista === vista || (vista === 'informe' && b.dataset.vista === 'informes')));
  if (VISTAS_MONITOR.includes(antes) && !VISTAS_MONITOR.includes(vista)) detenerMonitor();
  if (VISTAS_MONITOR.includes(vista)) iniciarMonitor();
  if (vista === 'temperaturas') prepararTemperaturas();
  if (vista === 'capacidades') pintarCapacidades();
  if (vista === 'optimizar') pintarOptimizar();
  if (vista === 'informes') pintarInformes();
  if (vista === 'comparar') prepararComparar();
  if (vista === 'reparaciones') pintarReparaciones();
  if (vista === 'limpieza' && !estadoL.datos && !estadoL.ocupado) medirLimpieza();
  if (vista === 'disco') prepararDisco();
}
$$('[data-vista]').forEach(b => b.addEventListener('click', () => mostrar(b.dataset.vista)));

// ================================================================== configuración
function leerOpciones() {
  return {
    pais: $('#o-pais').value, presupuesto: Number($('#o-presupuesto').value) || 0, sinLimite: $('#o-sinlimite').checked,
    usados: $('#o-usados').checked, admin: $('#o-admin').checked, modoJuego: $('#o-juego').checked, modoJuegoSeg: Number($('#o-segundos').value) || 120
  };
}
async function guardar(parcial) { estado.config = await api.guardarConfig(Object.assign({}, estado.config, parcial)); }

function aplicarApariencia() {
  const c = estado.config;
  document.documentElement.dataset.acento = c.acento || 'azul';
  document.documentElement.classList.toggle('sin-anim', c.animaciones === false);
  $$('#a-tema button').forEach(b => b.classList.toggle('activo', b.dataset.v === (c.tema || 'sistema')));
  $$('#a-acento .muestra').forEach(b => b.classList.toggle('activo', b.dataset.v === (c.acento || 'azul')));
  [['#a-overlay', c.overlay || 'auto'], ['#a-overlay-pos', c.overlayPos || 'sup-izq'], ['#a-overlay-tam', c.overlayTam || 'normal']].forEach(([id, v]) => $$(id + ' button').forEach(b => b.classList.toggle('activo', b.dataset.v === v)));
}

function pintarOpciones() {
  const c = estado.config;
  opcionesPais($('#o-pais'), c.pais);
  $('#o-presupuesto').value = c.presupuesto;
  $('#o-sinlimite').checked = !!c.sinLimite;
  $('#o-presupuesto').disabled = !!c.sinLimite;
  $('#o-usados').checked = !!c.usados;
  $('#o-admin').checked = !!c.admin;
  $('#o-juego').checked = false;
  $('#o-segundos').value = String(c.modoJuegoSeg || 120);
  $('#a-fuente').value = c.fuenteW || '';
  $('#a-anonimo').checked = !!c.anonimo;
  $('#a-notificaciones').checked = c.notificaciones !== false;
  $('#a-animaciones').checked = c.animaciones !== false;
  const t = c.tecnico || {};
  $('#t-activo').checked = !!t.activo; $('#t-nombre').value = t.nombre || ''; $('#t-whatsapp').value = t.whatsapp || ''; $('#t-correo').value = t.correo || '';
  pintarTecnico();
  $('#a-acento').innerHTML = ACENTOS.map(([n, col]) => `<button class="muestra" data-v="${n}" title="${n}" style="background:${col}"></button>`).join('');
  $$('#a-acento .muestra').forEach(b => b.onclick = async () => { await guardar({ acento: b.dataset.v }); aplicarApariencia(); });
  $('#a-alertas').checked = c.alertas !== false;
  $('#a-umbral-cpu').value = c.umbralCpu || 90;
  $('#a-umbral-gpu').value = c.umbralGpu || 85;
  $('#a-sensores').checked = !!c.sensoresAvanzados;
  $('#a-sonidos').checked = c.sonidos !== false;
  $('#a-volumen').value = c.volumen != null ? c.volumen : 60;
  $('#a-bandeja').checked = c.bandeja !== false;
  $('#a-inicio-win').checked = !!c.iniciarConWindows;
  if (window.Sonidos) window.Sonidos.configurar(c.sonidos !== false, c.volumen);
  aplicarApariencia();
  pintarCarpetas();
}
['#o-pais', '#o-presupuesto', '#o-sinlimite', '#o-usados', '#o-admin', '#o-segundos'].forEach(id => $(id).addEventListener('change', () => {
  $('#o-presupuesto').disabled = $('#o-sinlimite').checked;
  const o = leerOpciones();
  guardar({ pais: o.pais, presupuesto: o.presupuesto, sinLimite: o.sinLimite, usados: o.usados, admin: o.admin, modoJuegoSeg: o.modoJuegoSeg });
}));
$('#o-juego').addEventListener('change', () => {
  const on = $('#o-juego').checked;
  $('#caja-segundos').classList.toggle('oculto', !on);
  $('#nota-duracion').textContent = on ? 'Al empezar tendrás 20 segundos para abrir tu juego; después mide mientras juegas.' : 'Tarda entre 1 y 2 minutos.';
});
$$('#a-tema button').forEach(b => b.onclick = async () => { await guardar({ tema: b.dataset.v }); aplicarApariencia(); });
$('#a-animaciones').onchange = async () => { await guardar({ animaciones: $('#a-animaciones').checked }); aplicarApariencia(); };
$('#a-notificaciones').onchange = () => guardar({ notificaciones: $('#a-notificaciones').checked });
[['#a-overlay', 'overlay'], ['#a-overlay-pos', 'overlayPos'], ['#a-overlay-tam', 'overlayTam']].forEach(([id, clave]) => $$(id + ' button').forEach(b => b.onclick = async () => { await guardar({ [clave]: b.dataset.v }); aplicarApariencia(); sonar('clic'); }));
$('#btn-probar-overlay').onclick = async () => { await api.probarOverlay(); toast('Overlay visible durante 10 segundos. Atajo: Ctrl + Mayús + O'); };
$('#a-alertas').onchange = () => guardar({ alertas: $('#a-alertas').checked });
$('#a-umbral-cpu').onchange = () => guardar({ umbralCpu: Math.min(105, Math.max(60, Number($('#a-umbral-cpu').value) || 90)) });
$('#a-umbral-gpu').onchange = () => guardar({ umbralGpu: Math.min(100, Math.max(60, Number($('#a-umbral-gpu').value) || 85)) });
$('#a-sensores').onchange = async () => {
  const on = $('#a-sensores').checked;
  await guardar({ sensoresAvanzados: on });
  if (on) toast('Windows pedirá permiso de administrador para leer el procesador.', 5000);
  estadoSensoresAjustes();
};
$('#a-sonidos').onchange = async () => { await guardar({ sonidos: $('#a-sonidos').checked }); if (window.Sonidos) window.Sonidos.configurar($('#a-sonidos').checked, Number($('#a-volumen').value)); sonar('exito'); };
let tVol;
$('#a-volumen').oninput = () => { if (window.Sonidos) window.Sonidos.configurar($('#a-sonidos').checked, Number($('#a-volumen').value)); clearTimeout(tVol); tVol = setTimeout(() => guardar({ volumen: Number($('#a-volumen').value) }), 300); };
$('#btn-probar-sonido').onclick = () => { if (window.Sonidos) { window.Sonidos.configurar(true, Number($('#a-volumen').value)); window.Sonidos.fin(true); } };
$('#a-bandeja').onchange = () => guardar({ bandeja: $('#a-bandeja').checked });
$('#a-inicio-win').onchange = () => guardar({ iniciarConWindows: $('#a-inicio-win').checked });
async function estadoSensoresAjustes() {
  const e = await api.tempsEstado();
  const el = $('#a-sensores-estado');
  if (!e.hayLector) { el.textContent = 'El lector de sensores se incluye en la versión instalada.'; return; }
  el.innerHTML = e.pawnio ? 'Controlador PawnIO: <b>instalado</b>.' : 'Para leer el procesador hace falta el controlador gratuito PawnIO. <a href="#" id="lnk-pawnio">Descargar PawnIO</a>';
  const l = $('#lnk-pawnio'); if (l) l.onclick = ev => { ev.preventDefault(); api.abrirAjuste('pawnio'); };
}
$('#a-fuente').addEventListener('change', () => guardar({ fuenteW: Math.max(0, Number($('#a-fuente').value) || 0) }));
$('#a-anonimo').addEventListener('change', () => guardar({ anonimo: $('#a-anonimo').checked }));

function leerTecnico() { return { activo: $('#t-activo').checked, nombre: $('#t-nombre').value.trim(), whatsapp: $('#t-whatsapp').value.trim(), correo: $('#t-correo').value.trim() }; }
function pintarTecnico() {
  const t = leerTecnico();
  $('#t-campos').style.opacity = t.activo ? 1 : .55;
  $('#t-vista').innerHTML = t.activo && t.nombre
    ? `<span>Informe preparado por</span><b>${esc(t.nombre)}</b>${esc([t.whatsapp && 'WhatsApp ' + t.whatsapp, t.correo].filter(Boolean).join(' · '))}`
    : 'Así aparecerán tus datos en los informes (activa la opción y escribe tu nombre).';
}
let tTec;
['#t-activo', '#t-nombre', '#t-whatsapp', '#t-correo'].forEach(id => $(id).addEventListener('input', () => {
  pintarTecnico(); clearTimeout(tTec); tTec = setTimeout(() => guardar({ tecnico: leerTecnico() }), 400);
}));

function pintarCarpetas() {
  const l = estado.config.carpetas || [];
  $('#lista-carpetas').innerHTML = l.length
    ? l.map((c, i) => `<div class="carpeta">${ico('carpeta')}<code title="${esc(c)}">${esc(c)}</code><button data-i="${i}" title="Quitar">Quitar</button></div>`).join('')
    : '<p class="sub">No has añadido carpetas.</p>';
  $('#lista-carpetas').querySelectorAll('button').forEach(b => b.onclick = async () => {
    const n = [...l]; n.splice(Number(b.dataset.i), 1); await guardar({ carpetas: n }); pintarCarpetas();
  });
}
$('#btn-add-carpeta').onclick = async () => {
  const r = await api.elegirCarpeta();
  if (r && !(estado.config.carpetas || []).includes(r)) { await guardar({ carpetas: [...(estado.config.carpetas || []), r] }); pintarCarpetas(); }
};

// ================================================================== análisis
async function lanzar(extra = {}) {
  const c = estado.config;
  const o = Object.assign(leerOpciones(), { fuenteW: c.fuenteW, carpetas: c.carpetas, anonimo: c.anonimo }, extra);
  const r = await api.analizar(o);
  if (!r.ok) toast(r.mensaje);
}
$('#btn-analizar').onclick = () => lanzar();
$('#btn-json').onclick = async () => { const ruta = await api.elegirJson(); if (ruta) lanzar({ desdeJson: ruta, admin: false }); };
$('#btn-cancelar').onclick = async () => { $('#btn-cancelar').disabled = true; $('#p-texto').textContent = 'Cancelando…'; await api.cancelar(); };
$('#btn-empezar').onclick = async () => { await api.empezarYa(); $('#btn-empezar').classList.add('oculto'); };

function modoProgreso(activo) {
  estado.analizando = activo;
  $('#panel-inicio').classList.toggle('oculto', activo);
  $('#panel-progreso').classList.toggle('oculto', !activo);
}
function pintarPasos(pct) {
  const ol = $('#p-pasos');
  if (!ol.children.length) ol.innerHTML = estado.pasos.map(p => `<li><span class="marca-p">${ico('check')}</span>${esc(p.t)}</li>`).join('');
  let activoPuesto = false;
  const hechos = estado.pasos.filter(p => pct >= p.h).length;
  if (hechos > estado.pasosHechos) { for (let k = estado.pasosHechos; k < hechos; k++) setTimeout(() => sonar('paso', k), (k - estado.pasosHechos) * 120); }
  estado.pasosHechos = Math.max(estado.pasosHechos, hechos);
  [...ol.children].forEach((li, i) => {
    const hecho = pct >= estado.pasos[i].h;
    li.classList.toggle('hecho', hecho);
    const activo = !hecho && !activoPuesto;
    li.classList.toggle('activo', activo);
    if (activo) activoPuesto = true;
  });
}

api.onAnalisis(ev => {
  switch (ev.tipo) {
    case 'inicio':
      estado.pasos = ev.desdeJson ? PASOS_JSON : PASOS_ANALISIS;
      estado.pasosHechos = 0;
      $('#p-pasos').innerHTML = '';
      sonar('inicio'); setTimeout(() => sonar('iniciarSonar'), 900);
      mostrar('inicio'); modoProgreso(true);
      $('#btn-cancelar').disabled = false;
      $('#p-titulo').textContent = ev.desdeJson ? 'Generando el informe…' : ev.modoJuego ? 'Modo juego' : 'Analizando tu PC…';
      $('#p-aviso').classList.add('oculto');
      $('#btn-empezar').classList.add('oculto');
      $('#p-barra').style.width = '2%'; $('#p-pct').dataset.v = 0; $('#p-pct').textContent = '0';
      $('#p-texto').textContent = ev.elevado ? 'Esperando el permiso de administrador…' : 'Preparando…';
      pintarPasos(0);
      break;
    case 'progreso':
      $('#p-barra').style.width = Math.max(2, ev.pct) + '%';
      contar($('#p-pct'), ev.pct, 500);
      $('#p-texto').textContent = ev.texto;
      pintarPasos(ev.pct);
      if (/^Abre tu juego/.test(ev.texto)) $('#btn-empezar').classList.remove('oculto');
      else if (/^Midiendo/.test(ev.texto)) $('#btn-empezar').classList.add('oculto');
      break;
    case 'aviso':
      $('#p-aviso').textContent = ev.texto; $('#p-aviso').classList.remove('oculto');
      break;
    case 'fin':
      sonar('pararSonar');
      pintarPasos(101); contar($('#p-pct'), 100, 300); $('#p-barra').style.width = '100%';
      setTimeout(() => sonar('fin', !ev.informe || ev.informe.salud >= 65), 250);
      setTimeout(async () => {
        modoProgreso(false);
        await refrescarInformes();
        if (ev.informe && ev.informe.url) {
          abrirInforme(ev.informe);
          toast(`Listo: salud ${ev.informe.salud}/100 (${ev.informe.etiqueta})`);
          if (ev.informe.salud >= 85) setTimeout(() => confeti(), 400);
        } else toast('El análisis terminó, pero no se encontró el informe.');
      }, 700);
      break;
    case 'cancelado':
      sonar('pararSonar'); sonar('cancelado');
      modoProgreso(false); toast('Análisis cancelado.');
      break;
    case 'error':
      sonar('pararSonar'); sonar('error');
      modoProgreso(false);
      if (ev.codigo === 'uac') {
        modal({ titulo: 'Sin permiso de administrador', html: '<p>No se concedió el permiso. Puedes analizar igualmente sin permisos: faltarán la salud de los discos y algunos registros.</p>', confirmar: 'Analizar sin permisos' })
          .then(ok => { if (ok) lanzar({ admin: false }); });
      } else {
        modal({ titulo: 'No se pudo completar el análisis', html: `<p>${esc(ev.mensaje)}</p><p class="sub">Si se repite, avísanos desde Acerca de > Ver el proyecto en GitHub.</p>`, confirmar: 'Entendido', sinCancelar: true });
      }
      break;
  }
});

// ================================================================== inicio: mi equipo y último análisis
function pintarInicio() {
  const u = estado.informes[0];
  const eq = $('#mi-equipo'), caja = $('#ultimo');
  $('#nav-n-informes').textContent = estado.informes.length;
  $('#nav-n-informes').classList.toggle('oculto', !estado.informes.length);
  if (!u) { eq.classList.add('oculto'); caja.classList.add('oculto'); return; }
  const e = u.equipoInfo || {};
  const limpio = t => String(t || '').replace(/\((R|TM)\)/gi, '').replace(/\s+CPU\s+@.*$/i, '').replace(/\s+/g, ' ').trim();
  const chips = [['cpu', 'Procesador', limpio(e.cpu)], ['gpu', 'Gráficos', limpio(e.gpu)], ['ram', 'Memoria', e.ram], ['disco', 'Almacenamiento', e.discos], ['windows', 'Sistema', e.windows]].filter(x => x[2]);
  eq.innerHTML = chips.map(([i, t, v]) => `<div class="chip-hw"><div class="ic">${ico(i)}</div><div><small>${t}</small><b title="${esc(v)}">${esc(v)}</b></div></div>`).join('');
  eq.classList.toggle('oculto', !chips.length);
  escalonar(eq);

  const cnt = u.conteo || {};
  const chipsSev = [['critico', 'críticos', 'var(--crit)'], ['alto', 'altos', 'var(--alto)'], ['medio', 'medios', 'var(--medio)'], ['bajo', 'bajos', 'var(--bajo)']]
    .filter(([s]) => cnt[s]).map(([s, t, c]) => `<span class="chip-sev" style="--c:${c}">${cnt[s]} ${t}</span>`).join('');
  caja.classList.remove('oculto');
  caja.innerHTML = `<div class="ultimo">${anillo(u.salud, 92)}<div style="flex:1;min-width:0">
      <h3>Último análisis · ${esc(u.equipo)} · ${esc(fecha(u.fecha, u.creado))}</h3>
      <div class="chips-sev">${chipsSev || '<span class="chip-sev" style="--c:var(--ok)">Sin problemas importantes</span>'}</div>
      <ul class="mini-lista">${u.principales.map(h => `<li><span class="sev ${esc(h.severidad)}">${esc(h.severidad)}</span>${esc(h.titulo)}</li>`).join('')}</ul></div>
    <div style="display:flex;flex-direction:column;gap:8px"><button class="btn" id="btn-ver-ultimo">Ver informe</button>${estado.informes.length > 1 ? '<button class="btn secundario" id="btn-comp-ultimo">Comparar</button>' : ''}</div></div>`;
  $('#btn-ver-ultimo').onclick = () => abrirInforme(u);
  if ($('#btn-comp-ultimo')) $('#btn-comp-ultimo').onclick = () => mostrar('comparar');
  animarAnillos(caja);
}

// ================================================================== informe
async function datosDe(inf) {
  if (!estado.cacheDatos[inf.json]) estado.cacheDatos[inf.json] = await api.datosInforme(inf.json);
  return estado.cacheDatos[inf.json];
}
function abrirInforme(inf) {
  estado.informeActual = inf;
  $('#marco').src = inf.url + '?t=' + Date.now();
  $('#i-titulo').textContent = `${inf.equipo || 'Equipo'}${inf.salud != null ? ' · salud ' + inf.salud + '/100' : ''}`;
  $('#i-sub').textContent = `${fecha(inf.fecha, inf.creado)}${inf.pais ? ' · ' + inf.pais : ''}`;
  opcionesPais($('#r-pais'), (inf.pais || '').replace(/ \(precios genéricos\)$/, '') || estado.config.pais);
  $('#r-presupuesto').value = inf.presupuesto != null && inf.presupuesto >= 0 ? inf.presupuesto : estado.config.presupuesto;
  mostrar('informe');
}
async function textoResumen(inf) {
  const d = await datosDe(inf);
  if (d && d.texto) return d.texto;
  return `DOCTOR PC - ${inf.equipo}\nSalud: ${inf.salud}/100 (${inf.etiqueta})\n` + inf.principales.map((h, i) => `${i + 1}. [${h.severidad.toUpperCase()}] ${h.titulo}`).join('\n');
}
$('#btn-volver').onclick = () => mostrar('informes');
$('#btn-navegador').onclick = () => estado.informeActual && api.abrirEnNavegador(estado.informeActual.html);
$('#btn-archivo').onclick = () => estado.informeActual && api.mostrarArchivo(estado.informeActual.json);
$('#btn-pdf').onclick = () => exportarPdf(estado.informeActual);
$('#btn-copiar').onclick = async () => { if (!estado.informeActual) return; await api.copiar(await textoResumen(estado.informeActual)); toast('Resumen copiado. Pégalo donde quieras.'); };
$('#btn-whatsapp').onclick = async () => { if (!estado.informeActual) return; await api.whatsapp(await textoResumen(estado.informeActual)); toast('Abriendo WhatsApp…'); };
$('#btn-recalcular').onclick = () => {
  const inf = estado.informeActual; if (!inf) return;
  lanzar({ desdeJson: inf.json, admin: false, pais: $('#r-pais').value, presupuesto: Number($('#r-presupuesto').value) || 0, sinLimite: false });
};
async function exportarPdf(inf) {
  if (!inf || !inf.html) return;
  toast('Preparando el PDF…', 2000);
  const r = await api.exportarPdf(inf.html);
  if (r.ok) toast('PDF guardado.'); else if (!r.cancelado) toast('No se pudo crear el PDF: ' + (r.mensaje || ''));
}
$('#btn-carpeta').onclick = $('#btn-carpeta2').onclick = () => api.abrirCarpetaInformes();

async function refrescarInformes() { estado.informes = await api.informes(); estado.cacheDatos = {}; pintarInicio(); }

function pintarInformes() {
  const l = estado.informes, c = $('#lista-informes');
  if (!l.length) { c.innerHTML = `<div class="vacio">${ico('informe')}Aún no hay informes. Ve a <b>Inicio</b> y pulsa "Analizar mi PC".</div>`; return; }
  c.innerHTML = l.map((inf, i) => {
    const cnt = inf.conteo || {};
    const sev = [['critico', 'var(--crit)'], ['alto', 'var(--alto)'], ['medio', 'var(--medio)']].filter(([s]) => cnt[s]).map(([s, col]) => `<span class="chip-sev" style="--c:${col}">${cnt[s]} ${s}</span>`).join('');
    return `<div class="item">${anillo(inf.salud, 62)}
      <div class="cuerpo"><b>${esc(inf.equipo || 'Equipo')}</b> <span class="etq">${esc(inf.etiqueta || '')}</span>
        <div class="meta">${esc(fecha(inf.fecha, inf.creado))}${inf.pais ? ' · ' + esc(inf.pais) : ''}${inf.presupuesto != null ? ' · ' + (inf.presupuesto < 0 ? 'sin límite' : 'US$' + inf.presupuesto) : ''}</div>
        <div class="chips-sev">${sev}</div></div>
      <div class="acciones"><button class="btn" data-abrir="${i}">Abrir</button><button class="btn icono secundario" data-pdf="${i}" title="Guardar en PDF">${ico('pdf')}</button><button class="btn icono secundario" data-borrar="${i}" title="Borrar">${ico('papelera')}</button></div></div>`;
  }).join('');
  escalonar(c); animarAnillos(c);
  c.querySelectorAll('[data-abrir]').forEach(b => b.onclick = () => { const inf = l[Number(b.dataset.abrir)]; if (inf.url) abrirInforme(inf); else toast('Falta el archivo HTML de este informe.'); });
  c.querySelectorAll('[data-pdf]').forEach(b => b.onclick = () => exportarPdf(l[Number(b.dataset.pdf)]));
  c.querySelectorAll('[data-borrar]').forEach(b => b.onclick = async () => {
    const inf = l[Number(b.dataset.borrar)];
    if (await modal({ titulo: 'Borrar informe', html: `<p>Se moverán a la papelera el informe y los datos de <b>${esc(inf.equipo)}</b> (${esc(fecha(inf.fecha, inf.creado))}).</p>`, confirmar: 'Mover a la papelera', peligro: true })) {
      await api.borrarInforme(inf.json); await refrescarInformes(); pintarInformes();
    }
  });
}

// ================================================================== comparar
function prepararComparar() {
  const l = estado.informes;
  const res = $('#c-resultado');
  if (l.length < 2) {
    $('#c-a').innerHTML = $('#c-b').innerHTML = '';
    res.innerHTML = `<div class="vacio">${ico('comparar')}Necesitas al menos dos informes. Haz un análisis, aplica las soluciones y vuelve a analizar para ver la diferencia.</div>`;
    return;
  }
  const opc = l.map((x, i) => `<option value="${i}">${esc(x.equipo)} · ${esc(fecha(x.fecha, x.creado))} · ${x.salud}/100</option>`).join('');
  const b = 0;
  let a = l.findIndex((x, i) => i > 0 && x.equipo === l[0].equipo); if (a < 0) a = 1;
  $('#c-a').innerHTML = opc; $('#c-b').innerHTML = opc;
  $('#c-a').value = String(a); $('#c-b').value = String(b);
  comparar();
}
$('#c-a').onchange = $('#c-b').onchange = () => comparar();
async function comparar() {
  const A = estado.informes[Number($('#c-a').value)], B = estado.informes[Number($('#c-b').value)];
  const res = $('#c-resultado');
  if (!A || !B) return;
  if (A === B) { res.innerHTML = '<div class="vacio">Elige dos informes distintos.</div>'; return; }
  res.innerHTML = '<div class="esqueleto"></div>';
  const [da, db] = await Promise.all([datosDe(A), datosDe(B)]);
  if (!da || !db) { res.innerHTML = '<div class="vacio">No se pudieron leer los informes.</div>'; return; }
  const ha = da.hallazgos.filter(h => h.severidad !== 'info'), hb = db.hallazgos.filter(h => h.severidad !== 'info');
  const idsB = new Set(hb.map(h => h.id)), idsA = new Set(ha.map(h => h.id));
  const resueltos = ha.filter(h => !idsB.has(h.id)), nuevos = hb.filter(h => !idsA.has(h.id)), siguen = hb.filter(h => idsA.has(h.id));
  const d = (B.salud || 0) - (A.salud || 0);
  const lista = arr => arr.length ? `<ul>${arr.map(h => `<li><span class="sev ${esc(h.severidad)}">${esc(h.severidad)}</span>${esc(h.titulo)}</li>`).join('')}</ul>` : '<p class="sub">Ninguno.</p>';
  res.innerHTML = `<div class="tarjeta"><div class="duelo">
      <div class="lado">${anillo(A.salud, 110)}<small>Antes · ${esc(fecha(A.fecha, A.creado))}</small></div>
      <div class="delta ${d > 0 ? 'sube' : d < 0 ? 'baja' : 'igual'}">${d > 0 ? '+' : ''}${d}</div>
      <div class="lado">${anillo(B.salud, 110)}<small>Después · ${esc(fecha(B.fecha, B.creado))}</small></div></div>
      <p class="sub" style="text-align:center;margin:6px 0 0">${d > 0 ? 'El equipo mejoró.' : d < 0 ? 'El equipo empeoró: revisa los problemas nuevos.' : 'La salud no cambió.'}${A.equipo !== B.equipo ? ' Atención: son equipos distintos.' : ''}</p></div>
    <div class="columnas-c">
      <div class="tarjeta" style="--c:var(--ok)"><h3>Resueltos <span>${resueltos.length}</span></h3>${lista(resueltos)}</div>
      <div class="tarjeta" style="--c:var(--crit)"><h3>Nuevos <span>${nuevos.length}</span></h3>${lista(nuevos)}</div>
      <div class="tarjeta" style="--c:var(--medio)"><h3>Siguen igual <span>${siguen.length}</span></h3>${lista(siguen)}</div></div>`;
  animarAnillos(res); escalonar(res.querySelector('.columnas-c'));
  if (d >= 15 && resueltos.length) { confeti(90); sonar('exito'); }
}

// ================================================================== monitor en vivo
const hist = { cpu: [], ram: [], gpu: [], bajada: [], subida: [] };
let monitorTimer = null;
async function iniciarMonitor() {
  const ok = await api.iniciarMonitor();
  $('#nav-vivo').classList.remove('oculto');
  const e = $('#m-estado');
  if (!ok) { e.className = 'en-vivo'; e.innerHTML = '<i></i>No disponible'; return; }
  if (!e.classList.contains('on')) e.innerHTML = '<i></i>Conectando…';
  clearTimeout(monitorTimer);
  monitorTimer = setTimeout(() => { if (!e.classList.contains('on')) e.innerHTML = '<i></i>Iniciando (unos segundos)…'; }, 4000);
}
function detenerMonitor() {
  api.detenerMonitor();
  $('#nav-vivo').classList.add('oculto');
  const e = $('#m-estado'); e.className = 'en-vivo'; e.innerHTML = '<i></i>En pausa';
}
function setMedidor(nombre, valor, max, texto, col) {
  const m = $(`.medidor[data-m="${nombre}"]`);
  const b = m.querySelector('b');
  if (valor == null) { b.textContent = '–'; m.querySelector('.valor').style.strokeDashoffset = 235.6; m.querySelector('.m-det').textContent = texto || ''; return; }
  const k = Math.max(0, Math.min(1, valor / max));
  m.style.setProperty('--col', col);
  m.querySelector('.valor').style.strokeDashoffset = 235.6 * (1 - k);
  b.textContent = Math.round(valor);
  m.querySelector('.m-det').textContent = texto || '';
}
function empujar(arr, v) { arr.push(v == null ? null : Number(v)); if (arr.length > 60) arr.shift(); }
function grafica(svg, series, max) {
  const W = 600, H = Number(svg.viewBox.baseVal.height) || 160;
  const rej = [0.25, 0.5, 0.75].map(f => `<line class="rejilla" x1="0" x2="${W}" y1="${H * f}" y2="${H * f}"/>`).join('');
  const capas = series.map(s => {
    const pts = s.datos.map((v, i) => v == null ? null : [(i + 60 - s.datos.length) * (W / 59), H - Math.min(1, v / max) * (H - 6) - 3]).filter(Boolean);
    if (pts.length < 2) return '';
    const linea = pts.map(p => p.map(n => n.toFixed(1)).join(',')).join(' ');
    return `<polygon class="area" fill="${s.color}" points="${pts[0][0].toFixed(1)},${H} ${linea} ${pts[pts.length - 1][0].toFixed(1)},${H}"/><polyline stroke="${s.color}" points="${linea}"/>`;
  }).join('');
  svg.innerHTML = rej + capas;
}
api.onMonitor(m => {
  if (estado.vista === 'temperaturas') { actualizarTemperaturas(m); return; }
  if (estado.vista !== 'monitor') return;
  const e = $('#m-estado'); if (!e.classList.contains('on')) { e.className = 'en-vivo on'; e.innerHTML = '<i></i>En vivo'; }
  const ramPct = m.ramTotal ? m.ramUsada / m.ramTotal * 100 : null;
  setMedidor('cpu', m.cpu, 100, (m.cpuNom || '').replace(/\(R\)|\(TM\)|CPU|Processor|@.*$/g, '').replace(/\s+/g, ' ').trim() + (m.cpuPerf ? ` · ${m.cpuPerf} % vel.` : ''), colorCarga(m.cpu, 70, 90));
  setMedidor('ram', ramPct, 100, m.ramTotal ? `${(m.ramUsada / 1024).toFixed(1)} de ${(m.ramTotal / 1024).toFixed(1)} GB` : '', colorCarga(ramPct, 75, 90));
  setMedidor('gpu', m.gpu, 100, m.gpu == null ? 'No disponible en este equipo' : 'Uso del motor 3D', colorCarga(m.gpu, 80, 97));
  const tSt = window.Recomendaciones ? window.Recomendaciones.estadoTemp('cpu', m.cpuTemp, false) : { texto: '' };
  setMedidor('temp', m.cpuTemp, 100, m.cpuTemp == null ? 'Ver Temperaturas para activarla' : `${tSt.texto}${m.cpuTempFuente === 'acpi' ? ' (aprox.)' : ''}${m.gpuTemp != null ? ' · GPU ' + Math.round(m.gpuTemp) + ' °C' : ''}`, colorCarga(m.cpuTemp, 75, 88));
  empujar(hist.cpu, m.cpu); empujar(hist.ram, ramPct); empujar(hist.gpu, m.gpu); empujar(hist.bajada, m.bajadaKB); empujar(hist.subida, m.subidaKB);
  const cs = getComputedStyle(document.documentElement);
  const c1 = cs.getPropertyValue('--c1').trim() || '#2563eb';
  grafica($('#m-grafica'), [{ datos: hist.ram, color: '#f59e0b' }, { datos: hist.gpu, color: '#10b981' }, { datos: hist.cpu, color: c1 }], 100);
  const maxRed = Math.max(100, ...hist.bajada.filter(x => x != null), ...hist.subida.filter(x => x != null)) * 1.15;
  grafica($('#m-grafica-red'), [{ datos: hist.subida, color: '#f59e0b' }, { datos: hist.bajada, color: c1 }], maxRed);
  $('#m-bajada').textContent = fmtVel(m.bajadaKB || 0);
  $('#m-subida').textContent = fmtVel(m.subidaKB || 0);
  const discos = (m.discos || []);
  $('#m-discos').innerHTML = discos.length ? discos.map(d => `<div class="fila-barra"><span class="nombre">Disco ${esc(d.n)}</span><span class="pista"><i style="width:${d.act}%;--col:${colorCarga(d.act, 60, 90)}"></i></span><span class="dato">${Math.round(d.act)} % · L ${d.r} · E ${d.w} MB/s</span></div>`).join('') : '<p class="sub">Sin datos de discos.</p>';
  if (m.procs) {
    const top = Math.max(10, ...m.procs.map(p => p.cpu));
    $('#m-procs').innerHTML = m.procs.map(p => `<div class="fila-barra"><span class="nombre" title="${esc(p.n)}">${esc(p.n)}</span><span class="pista"><i style="width:${(p.cpu / top * 100).toFixed(0)}%;--col:var(--acc)"></i></span><span class="dato">${p.cpu} % · ${p.ram} MB</span></div>`).join('');
  }
});

// ================================================================== limpieza
const estadoL = { datos: null, sel: new Set(), ocupado: false };
const ICONO_LIMPIEZA = { temp_usuario: 'carpeta', temp_windows: 'windows', navegadores: 'red', errores: 'informe', miniaturas: 'paleta', papelera: 'papelera' };
async function medirLimpieza() {
  estadoL.ocupado = true;
  $('#l-resultado').innerHTML = '';
  $('#l-lista').innerHTML = Array.from({ length: 6 }, () => '<div class="esqueleto"></div>').join('');
  $('#l-total').textContent = 'Midiendo…'; $('#btn-l-limpiar').disabled = true;
  const r = await api.limpieza('analizar', []);
  estadoL.ocupado = false;
  if (!r.ok) { $('#l-lista').innerHTML = `<div class="vacio">${esc(r.mensaje)}</div>`; $('#l-total').textContent = '–'; return; }
  estadoL.datos = r.datos;
  estadoL.sel = new Set(r.datos.Categorias.filter(c => c.Tamano > 0 && ['temp_usuario', 'navegadores', 'errores', 'miniaturas'].includes(c.Id)).map(c => c.Id));
  pintarLimpieza();
}
function pintarLimpieza() {
  const cats = estadoL.datos.Categorias;
  $('#l-lista').innerHTML = cats.map(c => `<div class="item cat ${estadoL.sel.has(c.Id) ? 'sel' : ''}" data-id="${c.Id}">
      <input type="checkbox" ${estadoL.sel.has(c.Id) ? 'checked' : ''} ${c.Tamano > 0 ? '' : 'disabled'}>
      <div class="ic-item">${ico(ICONO_LIMPIEZA[c.Id] || 'limpiar')}</div>
      <div class="cuerpo"><b>${esc(c.Nombre)}</b>${c.Admin ? '<span class="etq">Pide administrador</span>' : ''}${c.Id === 'papelera' ? '<span class="etq">Permanente</span>' : ''}
        <div class="meta">${esc(c.Desc)}</div></div>
      <div class="tamano">${c.Tamano > 0 ? fmtBytes(c.Tamano) : '<span class="sub">Vacío</span>'}${c.Parcial ? '<div class="meta">≈ parcial</div>' : ''}</div></div>`).join('');
  escalonar($('#l-lista'));
  $$('#l-lista .cat').forEach(el => el.onclick = ev => {
    const c = cats.find(x => x.Id === el.dataset.id);
    if (!c || c.Tamano <= 0) return;
    if (estadoL.sel.has(c.Id)) estadoL.sel.delete(c.Id); else estadoL.sel.add(c.Id);
    el.classList.toggle('sel', estadoL.sel.has(c.Id));
    el.querySelector('input').checked = estadoL.sel.has(c.Id);
    if (ev.target.tagName === 'INPUT') ev.preventDefault();
    totalLimpieza();
  });
  totalLimpieza();
}
function totalLimpieza() {
  const t = estadoL.datos.Categorias.filter(c => estadoL.sel.has(c.Id)).reduce((a, c) => a + c.Tamano, 0);
  contar($('#l-total'), t, 600, fmtBytes);
  $('#btn-l-limpiar').disabled = !estadoL.sel.size;
}
$('#btn-l-medir').onclick = () => medirLimpieza();
$('#btn-l-limpiar').onclick = async () => {
  const sel = estadoL.datos.Categorias.filter(c => estadoL.sel.has(c.Id));
  const ok = await modal({
    titulo: 'Confirmar limpieza',
    html: `<p>Se borrarán:</p><ul>${sel.map(c => `<li><b>${esc(c.Nombre)}</b> · ${fmtBytes(c.Tamano)}</li>`).join('')}</ul>${sel.some(c => c.Id === 'papelera') ? '<p><b>Lo que está en la papelera se eliminará para siempre.</b></p>' : ''}<p class="sub">Los archivos que estén en uso se saltan sin problema. Queda anotado en el registro de cambios.</p>`,
    confirmar: 'Limpiar', peligro: sel.some(c => c.Id === 'papelera')
  });
  if (!ok) return;
  $('#btn-l-limpiar').disabled = true; $('#btn-l-limpiar').innerHTML = ico('limpiar') + 'Limpiando…';
  const r = await api.limpieza('limpiar', [...estadoL.sel]);
  $('#btn-l-limpiar').innerHTML = ico('limpiar') + 'Limpiar seleccionados';
  if (!r.ok) { toast(r.mensaje); $('#btn-l-limpiar').disabled = false; return; }
  const d = r.datos;
  $('#l-resultado').innerHTML = `<div class="tarjeta exito"><small class="sub">Espacio liberado</small><div class="grande-num" id="l-liberado">0 MB</div>
    <p>${d.Borrados.toLocaleString('es')} archivos eliminados${d.Omitidos ? ` · ${d.Omitidos.toLocaleString('es')} estaban en uso y se saltaron` : ''}.</p></div>`;
  contar($('#l-liberado'), d.Liberado, 1500, fmtBytes);
  $('#l-resultado').scrollIntoView({ behavior: animado() ? 'smooth' : 'auto', block: 'center' });
  sonar('exito');
  if (d.Liberado > 50 * 1048576) confeti(110);
  estadoL.datos = null;
  setTimeout(() => { if (estado.vista === 'limpieza') medirLimpieza().then(() => {}); }, 2500);
};

// ================================================================== velocidad del disco
let unidadesCargadas = false;
async function prepararDisco() {
  if (unidadesCargadas) return;
  const u = await api.unidades();
  $('#d-unidad').innerHTML = u.map(x => `<option value="${esc(x.letra)}">${esc(x.letra)} ${x.nombre ? esc(x.nombre) + ' ' : ''}(${x.gb} GB)</option>`).join('');
  unidadesCargadas = true;
}
api.onDisco(p => { $('#d-texto').textContent = p.texto; $('#d-barra').style.width = Math.max(3, p.pct) + '%'; });
$('#btn-d-probar').onclick = async () => {
  const unidad = $('#d-unidad').value || 'C:';
  $('#btn-d-probar').disabled = true; $('#d-resultado').innerHTML = '';
  $('#d-progreso').classList.remove('oculto'); $('#d-texto').textContent = 'Preparando la prueba…'; $('#d-barra').style.width = '3%';
  const r = await api.probarDisco(unidad);
  $('#d-progreso').classList.add('oculto'); $('#btn-d-probar').disabled = false;
  if (!r.ok) { $('#d-resultado').innerHTML = `<div class="vacio">${esc(r.mensaje)}</div>`; return; }
  const d = r.datos;
  const filas = [['Lectura secuencial', d.LecturaSecuencial, 'Cargas de juegos, archivos grandes'], ['Escritura secuencial', d.EscrituraSecuencial, 'Copiar e instalar'], ['Lectura aleatoria 4 KB', d.LecturaAleatoria, `Arranque y apertura de programas${d.Iops ? ' · ' + Number(d.Iops).toLocaleString('es') + ' IOPS' : ''}`]];
  const esc2 = v => Math.min(100, Math.sqrt(Math.max(0, v || 0)) / Math.sqrt(3500) * 100);
  $('#d-resultado').innerHTML = `<div class="veredicto ${esc(d.Nivel)}">${ico(d.Nivel === 'lento' ? 'info' : 'check')}<div><b>${esc(d.Tipo)}</b>${esc(d.Texto)}</div></div>
    <div class="tarjeta velocidades"><div class="t-cab"><h3>Resultados de ${esc(d.Unidad)}</h3></div><div class="lista-barras">
    ${filas.map(([t, v, s]) => `<div class="fila-barra"><span class="nombre"><b>${t}</b><br><small class="sub">${s}</small></span><span class="pista"><i style="width:0%;--col:${d.Nivel === 'lento' ? 'var(--crit)' : 'var(--acc)'}" data-w="${esc2(v)}"></i></span><span class="dato"><b>${v == null ? '–' : v.toLocaleString('es')} MB/s</b></span></div>`).join('')}
    </div><p class="nota">Referencia de lectura secuencial: disco mecánico ~120 MB/s · SSD SATA ~550 MB/s · SSD NVMe 2.000 MB/s o más. En lectura aleatoria de 4 KB un disco mecánico da ~1 MB/s y un SSD 20 MB/s o más.</p></div>`;
  requestAnimationFrame(() => requestAnimationFrame(() => $$('#d-resultado [data-w]').forEach(i => { i.style.width = i.dataset.w + '%'; })));
  sonar(d.Nivel === 'lento' ? 'alerta' : 'exito');
  if (d.Nivel === 'excelente') confeti(80);
};

// ================================================================== reparaciones
function pintarReparaciones() {
  const sugeridas = new Set((estado.informes[0] && estado.informes[0].reparaciones) || []);
  const orden = [...REPARACIONES].sort((a, b) => (sugeridas.has(b.id) ? 1 : 0) - (sugeridas.has(a.id) ? 1 : 0));
  $('#lista-reparaciones').innerHTML = orden.map(r => `<div class="item"><div class="ic-item">${ico(r.icono)}</div><div class="cuerpo">
      <b>${esc(r.nombre)}</b>${sugeridas.has(r.id) ? '<span class="etq sugerida">Sugerida por tu último análisis</span>' : ''}${r.admin ? '<span class="etq">Pide administrador</span>' : ''}
      <div class="meta">${esc(r.desc)}</div></div>
      <div class="acciones"><button class="btn secundario" data-rep="${r.id}">Ejecutar…</button></div></div>`).join('');
  escalonar($('#lista-reparaciones'));
  $$('#lista-reparaciones [data-rep]').forEach(b => b.onclick = () => reparar(REPARACIONES.find(r => r.id === b.dataset.rep), b));
}
async function reparar(r, boton) {
  const ok = await modal({ titulo: r.nombre, html: `<p>${esc(r.desc)}</p>`, confirmar: 'Ejecutar', exigir: r.nivel >= 3 ? 'SI' : null });
  if (!ok) return;
  boton.disabled = true; const t = boton.textContent; boton.textContent = 'En curso…';
  const res = await api.reparar(r.id);
  boton.disabled = false; boton.textContent = t;
  toast(res.mensaje || (res.ok ? 'Listo.' : 'No se pudo completar.'), 5000);
}

// ================================================================== actualizaciones
function pintarUpdate(u) {
  estado.update = u || {};
  const p = $('#pildora-update'), btn = $('#btn-update'), txt = $('#u-texto'), notas = $('#u-notas'), caja = $('#u-barra-caja'), tarj = $('#u-tarjeta');
  const v = estado.version;
  p.classList.add('oculto'); notas.classList.add('oculto'); caja.classList.add('oculto'); btn.disabled = false;
  tarj.className = 'tarjeta update-tarjeta ' + (u.estado || '');
  switch (u.estado) {
    case 'buscando': txt.textContent = `Versión instalada: ${v}. Buscando actualizaciones…`; btn.disabled = true; btn.textContent = 'Buscando…'; break;
    case 'al-dia': txt.textContent = `Versión instalada: ${v}. Tienes la última versión.`; btn.textContent = 'Buscar actualizaciones'; break;
    case 'disponible':
      txt.innerHTML = `Hay una versión nueva: <b>${esc(u.version)}</b> (tienes la ${esc(v)}).`;
      if (u.notas) { notas.textContent = u.notas; notas.classList.remove('oculto'); }
      btn.textContent = 'Descargar e instalar';
      p.querySelector('span').textContent = `Actualización ${u.version}`; p.classList.remove('oculto');
      break;
    case 'descargando':
      txt.textContent = `Descargando la versión ${u.version || ''}… ${u.pct || 0} %`;
      caja.classList.remove('oculto'); $('#u-barra').style.width = (u.pct || 0) + '%';
      btn.disabled = true; btn.textContent = 'Descargando…';
      break;
    case 'listo':
      txt.textContent = `La versión ${u.version} está lista. Doctor PC se cerrará, se instalará y se volverá a abrir.`;
      btn.textContent = 'Reiniciar e instalar';
      p.querySelector('span').textContent = 'Reinicia para actualizar'; p.classList.remove('oculto');
      break;
    case 'error': txt.textContent = `Versión instalada: ${v}. No se pudo buscar actualizaciones: ${u.mensaje || 'sin conexión'}.`; btn.textContent = 'Reintentar'; break;
    case 'dev': txt.textContent = `Versión ${v} (modo desarrollo: las actualizaciones solo funcionan en la app instalada).`; btn.textContent = 'Buscar actualizaciones'; break;
    default: txt.textContent = `Versión instalada: ${v}.`; btn.textContent = 'Buscar actualizaciones';
  }
}
$('#btn-update').onclick = () => {
  const e = estado.update.estado;
  if (e === 'disponible') api.descargarUpdate();
  else if (e === 'listo') api.instalarUpdate();
  else api.buscarUpdate();
};
api.onUpdate(pintarUpdate);
$('#btn-github').onclick = () => api.externo('https://github.com/caknek/doctor-pc');

// ================================================================== bienvenida e inicio
$('#btn-bv').onclick = async () => {
  $('#bienvenida').style.transition = 'opacity .35s'; $('#bienvenida').style.opacity = 0;
  setTimeout(() => $('#bienvenida').classList.add('oculto'), 350);
  await guardar({ bienvenida: true });
};

(async function arrancar() {
  const d = await api.init();
  estado.config = d.config; estado.paises = d.paises; estado.informes = d.informes; estado.version = d.version; estado.equipo = d.equipo || '';
  $('#version').textContent = 'Versión ' + d.version;
  $('#a-carpeta').textContent = 'Los informes se guardan en: ' + d.carpetaInformes;
  pintarOpciones(); pintarInicio(); pintarUpdate(d.update || {}); estadoSensoresAjustes();
  if (!d.config.bienvenida) $('#bienvenida').classList.remove('oculto');
  if (!d.motorOk) modal({ titulo: 'Falta el motor de diagnóstico', html: '<p>No se encontró DoctorPC.ps1. Reinstala Doctor PC.</p>', confirmar: 'Entendido', sinCancelar: true });
})();

// ================================================================== equipos con perfil (para Qué puedes hacer y Optimizar)
function informesConPerfil() { return estado.informes.filter(i => i.tienePerfil); }
function indiceLocal(lista) {
  const eq = String(estado.equipo || '').toLowerCase();
  const i = lista.findIndex(x => String(x.equipo || '').toLowerCase() === eq);
  return i >= 0 ? i : 0;
}
function llenarSelectorEquipo(sel, lista, actual) {
  sel.innerHTML = lista.map((x, i) => `<option value="${i}">${esc(x.equipo)}${String(x.equipo).toLowerCase() === String(estado.equipo).toLowerCase() ? ' (este PC)' : ''} · ${esc(fecha(x.fecha, x.creado))}</option>`).join('');
  sel.value = String(actual);
}
function vacioAnalizar(cont, texto) {
  cont.innerHTML = `<div class="vacio">${ico('pulso')}${esc(texto)}<div style="margin-top:14px"><button class="btn" id="btn-vacio-analizar">Analizar mi PC</button></div></div>`;
  $('#btn-vacio-analizar').onclick = () => { mostrar('inicio'); lanzar(); };
}
async function perfilLocal() {
  const l = informesConPerfil();
  if (!l.length) return null;
  const d = await datosDe(l[indiceLocal(l)]);
  return d ? d.perfil : null;
}

// ================================================================== temperaturas
const histTemp = [];
let tempsPerfil = null, tempsEstadoCache = null;
function tarjetaTemp(id, titulo, icono) {
  const el = $('#' + id);
  if (el.dataset.ok) return el;
  el.dataset.ok = 1;
  el.innerHTML = `<div class="tg"><svg viewBox="0 0 200 130">
      <defs><linearGradient id="grad-${id}" x1="20" y1="0" x2="180" y2="0" gradientUnits="userSpaceOnUse">
        <stop offset="0" stop-color="#38bdf8"/><stop offset=".35" stop-color="#22c55e"/><stop offset=".62" stop-color="#facc15"/><stop offset=".8" stop-color="#fb923c"/><stop offset="1" stop-color="#ef4444"/></linearGradient></defs>
      <path class="pista" d="M20 105 A80 80 0 0 1 180 105"/>
      <path class="arco" d="M20 105 A80 80 0 0 1 180 105" pathLength="100" style="stroke:url(#grad-${id});stroke-dasharray:100;stroke-dashoffset:100"/>
      <g class="aguja" style="transform:rotate(-90deg)"><circle cx="100" cy="25" r="8" fill="var(--panel)" stroke="var(--tx)" stroke-width="3"/></g>
    </svg><div class="num">–</div><div class="est"></div></div>
    <div class="temp-info"><h3>${ico(icono)}${titulo}</h3><div class="modelo"></div>
      <div class="stats-temp"><div><small>Mínima</small><b class="mn">–</b></div><div><small>Media</small><b class="pr">–</b></div><div><small>Máxima</small><b class="mx">–</b></div></div>
      <div class="fuente"><i></i><span></span></div></div>`;
  return el;
}
function pintarTemp(id, t, tipo, modelo, st, fuente, colorFuente) {
  const el = tarjetaTemp(id, id === 'tt-cpu' ? 'Procesador' : 'Tarjeta gráfica', id === 'tt-cpu' ? 'cpu' : 'gpu');
  const e = window.Recomendaciones.estadoTemp(tipo, t, tempsPerfil && tempsPerfil.EsPortatil);
  const col = { frio: '#38bdf8', normal: 'var(--ok)', calido: 'var(--medio)', caliente: 'var(--alto)', peligro: 'var(--crit)', nd: 'var(--mut)' }[e.clave];
  el.style.setProperty('--col', col);
  el.classList.toggle('peligro', e.clave === 'peligro');
  const k = t == null ? 0 : Math.max(0, Math.min(1, (t - 20) / 90));
  el.querySelector('.arco').style.strokeDashoffset = 100 - k * 100;
  el.querySelector('.aguja').style.transform = `rotate(${-90 + 180 * k}deg)`;
  el.querySelector('.num').innerHTML = t == null ? '–' : `${Math.round(t)}<small>°C</small>`;
  el.querySelector('.est').textContent = e.texto;
  el.querySelector('.modelo').textContent = modelo || '';
  el.querySelector('.mn').textContent = st ? Math.round(st.min) + '°' : '–';
  el.querySelector('.pr').textContent = st ? Math.round(st.prom) + '°' : '–';
  el.querySelector('.mx').textContent = st ? Math.round(st.max) + '°' : '–';
  const f = el.querySelector('.fuente');
  f.style.setProperty('--c', colorFuente);
  f.querySelector('span').textContent = fuente;
}
async function prepararTemperaturas() {
  tarjetaTemp('tt-cpu', 'Procesador', 'cpu'); tarjetaTemp('tt-gpu', 'Tarjeta gráfica', 'gpu');
  const [e, perfil] = await Promise.all([api.tempsEstado(), perfilLocal()]);
  tempsEstadoCache = e; tempsPerfil = perfil;
  histTemp.length = 0;
  (e.hist || []).forEach(h => histTemp.push(h));
  pintarAlertas(e.alertas || []);
  pintarConsejosFrio(e.sesion);
  pintarActivarCpu(null);
  dibujarGraficaTemp();
  if (!histTemp.length) $('#t-estado').innerHTML = '<i></i>Conectando…';
}
function dibujarGraficaTemp() {
  const map = v => v == null ? null : Math.max(0, Math.min(100, (v - 20) / 90 * 100));
  const cs = getComputedStyle(document.documentElement);
  grafica($('#t-grafica'), [{ datos: histTemp.slice(-120).map(h => map(h.gpu)), color: '#10b981' }, { datos: histTemp.slice(-120).map(h => map(h.cpu)), color: cs.getPropertyValue('--c1').trim() || '#2563eb' }], 100);
}
function actualizarTemperaturas(m) {
  const e = $('#t-estado'); if (!e.classList.contains('on')) { e.className = 'en-vivo on'; e.innerHTML = '<i></i>En vivo'; }
  const ses = m.sesion || {};
  const fuenteCpu = { sensor: ['Sensor del procesador (exacto)', 'var(--ok)'], lhm: ['LibreHardwareMonitor', 'var(--ok)'], acpi: ['Zona térmica ACPI (aproximada)', 'var(--medio)'] }[m.cpuTempFuente] || ['Sin sensor: actívalo abajo', 'var(--mut)'];
  pintarTemp('tt-cpu', m.cpuTemp, 'cpu', (tempsPerfil && tempsPerfil.Cpu || m.cpuNom || '').replace(/\((R|TM)\)/g, ''), m.cpuTempFuente === 'acpi' ? null : ses.cpu, fuenteCpu[0], fuenteCpu[1]);
  pintarTemp('tt-gpu', m.gpuTemp, 'gpu', m.gpuNombre || (tempsPerfil && tempsPerfil.Gpu) || '', ses.gpu, m.gpuTemp != null ? 'Sensor de la gráfica' : 'Sin sensor de la gráfica', m.gpuTemp != null ? 'var(--ok)' : 'var(--mut)');
  histTemp.push({ t: Date.now(), cpu: m.cpuTemp, gpu: m.gpuTemp }); if (histTemp.length > 300) histTemp.shift();
  dibujarGraficaTemp();
  const fila = (a, b) => b == null || b === '' ? '' : `<div><span>${a}</span><b>${b}</b></div>`;
  const vent = (m.ventiladores || []).slice(0, 4).map(v => fila(esc(v.nombre), Math.round(v.rpm) + ' rpm')).join('');
  $('#t-detalles').innerHTML = [
    fila('Punto caliente GPU', m.gpuHot != null ? Math.round(m.gpuHot) + ' °C' : null),
    fila('Memoria de la GPU', m.gpuMemTemp != null ? Math.round(m.gpuMemTemp) + ' °C' : null),
    fila('Uso del procesador', m.cpu != null ? Math.round(m.cpu) + ' %' : null),
    fila('Uso de la gráfica', m.gpu != null ? Math.round(m.gpu) + ' %' : null),
    fila('Potencia CPU', m.cpuPot != null ? Math.round(m.cpuPot) + ' W' : null),
    fila('Potencia GPU', m.gpuPot != null ? Math.round(m.gpuPot) + ' W' : null),
    fila('Reloj CPU', m.cpuReloj != null ? Math.round(m.cpuReloj) + ' MHz' : null),
    fila('Reloj GPU', m.gpuReloj != null ? Math.round(m.gpuReloj) + ' MHz' : null),
    fila('Ventilador GPU', m.gpuVentRpm != null ? Math.round(m.gpuVentRpm) + ' rpm' + (m.gpuVentPct != null ? ` (${Math.round(m.gpuVentPct)} %)` : '') : null),
    vent
  ].join('') || '<p class="sub">Activa los sensores avanzados para ver más datos.</p>';
  pintarActivarCpu(m);
  if (m.t % 15 === 0) pintarConsejosFrio(ses);
}
function pintarActivarCpu(m) {
  const caja = $('#t-activar');
  const e = tempsEstadoCache || {};
  const sinCpu = m ? (m.cpuTemp == null || m.cpuTempFuente === 'acpi') : true;
  if (!sinCpu || (m && !m.sensores)) { caja.classList.add('oculto'); return; }
  if (!e.hayLector) { caja.classList.add('oculto'); return; }
  const c = estado.config;
  const paso = (ok, txt, boton) => `<li>${ok ? '✅' : '⬜'} ${txt} ${!ok && boton ? boton : ''}</li>`;
  const html = `<div class="u-icono">${ico('temp')}</div><div style="flex:1"><h3>Activa la temperatura del procesador</h3>
    <p class="sub" style="margin:2px 0 6px">Windows no deja leer los sensores del procesador sin un controlador. Doctor PC usa PawnIO: gratuito, firmado y de código abierto (lo usan LibreHardwareMonitor y FanControl).</p>
    <ol>${paso(e.pawnio, 'Instala PawnIO.', '<button class="btn secundario" id="btn-pawnio">Descargar PawnIO</button>')}
      ${paso(!!c.sensoresAvanzados, 'Activa los sensores avanzados (Windows pedirá permiso de administrador).', '<button class="btn" id="btn-activar-sens">Activar</button>')}</ol>
    ${e.pawnio && c.sensoresAvanzados ? '<p class="nota">Si sigue sin aparecer, cierra Doctor PC del todo (icono de la bandeja > Salir) y vuelve a abrirlo aceptando el permiso.</p>' : ''}</div>`;
  if (caja.dataset.h !== html) { caja.innerHTML = html; caja.dataset.h = html; }
  caja.classList.remove('oculto');
  const b1 = $('#btn-pawnio'); if (b1) b1.onclick = () => api.abrirAjuste('pawnio');
  const b2 = $('#btn-activar-sens'); if (b2) b2.onclick = async () => { await guardar({ sensoresAvanzados: true }); $('#a-sensores').checked = true; toast('Acepta el permiso de administrador para leer el procesador.', 5000); };
}
function pintarAlertas(lista) {
  const c = estado.config;
  $('#t-alertas').innerHTML = `<p class="sub" style="margin-top:0">${c.alertas === false ? 'Las alertas están desactivadas.' : `Te avisamos si el procesador pasa de <b>${c.umbralCpu || 90} °C</b> o la gráfica de <b>${c.umbralGpu || 85} °C</b> durante unos segundos${c.bandeja !== false ? ', aunque Doctor PC esté en la bandeja' : ''}.`}</p>` +
    (lista.length ? lista.map(a => `<div class="alerta-fila">${ico('alerta')}<span><b>${a.comp === 'cpu' ? 'Procesador' : 'Gráfica'} a ${a.temp} °C</b> (límite ${a.umbral} °C)${a.juego ? ' jugando ' + esc(a.juego) : ''}</span><span class="sub" style="margin:0 0 0 auto">${new Date(a.fecha).toLocaleTimeString('es', { hour: '2-digit', minute: '2-digit' })}</span></div>`).join('') : '<p class="sub">Sin alertas en esta sesión. 👍</p>');
}
function pintarConsejosFrio(sesion) {
  if (!window.Recomendaciones) return;
  const lista = window.Recomendaciones.refrigeracion(tempsPerfil || {}, sesion || {});
  const cont = $('#t-consejos');
  const html = lista.map(x => `<div class="item consejo ${x.relevante ? 'relevante' : ''}"><div class="cabeza"><div class="ic-item">${ico(x.relevante ? 'alerta' : 'viento')}</div><div class="cuerpo">
      <b>${esc(x.titulo)}</b>${x.relevante ? '<span class="etq sugerida">Para ti</span>' : ''}<div class="meta">${esc(x.texto)}</div>${x.motivo ? `<span class="motivo">${esc(x.motivo)}</span>` : ''}
      ${x.pasos.length ? `<ol>${x.pasos.map(p => `<li>${esc(p)}</li>`).join('')}</ol>` : ''}</div></div></div>`).join('');
  if (cont.dataset.h !== html) { cont.innerHTML = html; cont.dataset.h = html; escalonar(cont); }
}
$('#btn-t-ajustes').onclick = () => mostrar('ajustes');

// Alertas desde el proceso principal
api.onAlerta(a => {
  sonar('alerta');
  $('#nav-alerta').classList.remove('oculto');
  setTimeout(() => $('#nav-alerta').classList.add('oculto'), 60000);
  const html = `${ico('alerta')}<div><b>Tu ${a.nombre} está a ${a.temp} °C</b>Supera tu límite de ${a.umbral} °C${a.juego ? ' mientras juegas ' + esc(a.juego) : ''}.</div><button class="btn" id="btn-ver-alerta">Qué hacer</button>`;
  let g = $('#alerta-global');
  if (!g) { g = document.createElement('div'); g.id = 'alerta-global'; g.className = 'alerta-global'; document.body.appendChild(g); }
  g.innerHTML = `<div class="banner-alerta">${html}</div>`;
  $('#btn-ver-alerta').onclick = () => { g.innerHTML = ''; mostrar('temperaturas'); };
  clearTimeout(api._tAlerta); api._tAlerta = setTimeout(() => { g.innerHTML = ''; }, 15000);
  if (estado.vista === 'temperaturas') api.tempsEstado().then(e => pintarAlertas(e.alertas || []));
});
api.onIr(v => mostrar(v));
api.onConfig(c => { estado.config = c; pintarOpciones(); });
api.onJuego(j => { if (j.activo && estado.config.overlay !== 'off') toast(`Juego detectado: ${j.n}. Overlay activo (Ctrl + Mayús + O para ocultarlo).`, 4500); });

// ================================================================== qué puedes hacer
let capFiltro = 'todo';
const NIVEL_TXT = { excelente: 'Excelente', bien: 'Bien', limitado: 'Con límites', no: 'No recomendable' };
const CAT_TXT = { Juegos: 'Juegos', Crear: 'Crear', IA: 'IA', Productividad: 'Productividad', Entretenimiento: 'Ocio' };
async function pintarCapacidades(indice) {
  const lista = informesConPerfil(), cont = $('#cap-lista');
  if (!lista.length) { $('#cap-chips').innerHTML = ''; $('#cap-anillo').innerHTML = ''; vacioAnalizar(cont, 'Analiza tu PC (o abre el .json de un cliente) para descubrir todo lo que puede hacer.'); return; }
  const idx = indice != null ? indice : indiceLocal(lista);
  llenarSelectorEquipo($('#cap-equipo'), lista, idx);
  const d = await datosDe(lista[idx]);
  const p = d && d.perfil;
  if (!p) { vacioAnalizar(cont, 'Este informe es de una versión anterior. Vuelve a analizar para verlo.'); return; }
  const caps = window.Capacidades.capacidades(p);
  const pct = window.Capacidades.versatilidad(caps);
  const limpio = t => String(t || '').replace(/\((R|TM)\)/gi, '').replace(/\s+CPU\s+@.*$/i, '').replace(/\s*(Six|Eight|Quad)-Core Processor/i, '').trim();
  $('#cap-chips').innerHTML = [['cpu', limpio(p.Cpu)], ['gpu', limpio(p.Gpu) + (p.VramGB && !p.GpuIntegrada ? ` · ${p.VramGB} GB` : '')], ['ram', `${Math.round(p.RamGB)} GB ${p.RamTipo || ''}`], ['disco', p.SistemaEnHDD ? 'Windows en HDD' : 'Windows en SSD']].map(([i, t]) => `<span>${ico(i)}${esc(t)}</span>`).join('');
  $('#cap-anillo').innerHTML = anillo(pct, 120) + '<small>Versatilidad</small>';
  animarAnillos($('#cap-anillo'));
  const vis = caps.filter(x => capFiltro === 'todo' || x.cat === capFiltro);
  cont.innerHTML = vis.map(x => `<div class="cap cat-${x.cat} ${x.nivel}">
      <div class="cab-cap"><div class="burbuja-ic">${ico(x.icono)}</div><span class="nivel ${x.nivel}">${NIVEL_TXT[x.nivel]}</span></div>
      <h3>${esc(x.titulo)}</h3><p>${esc(x.texto)}</p>${x.extra ? `<div class="extra">${esc(x.extra)}</div>` : ''}${x.nota ? `<div class="extra">${esc(x.nota)}</div>` : ''}
      ${x.apps.length ? `<div class="apps">${x.apps.map(a => `<span>${esc(a)}</span>`).join('')}</div>` : ''}</div>`).join('') || '<div class="vacio">Nada en esta categoría.</div>';
  escalonar(cont);
}
$('#cap-equipo').onchange = () => pintarCapacidades(Number($('#cap-equipo').value));
$$('#cap-filtros button').forEach(b => b.onclick = () => {
  capFiltro = b.dataset.v; $$('#cap-filtros button').forEach(x => x.classList.toggle('activo', x === b)); sonar('clic');
  pintarCapacidades(Number($('#cap-equipo').value) || undefined);
});

// ================================================================== optimizar juegos
const claveHecho = (eq, id) => `dpc-op-${eq}-${id}`;
function leerHecho(eq, id) { try { return localStorage.getItem(claveHecho(eq, id)) === '1'; } catch (e) { return false; } }
function guardarHecho(eq, id, v) { try { if (v) localStorage.setItem(claveHecho(eq, id), '1'); else localStorage.removeItem(claveHecho(eq, id)); } catch (e) { /* sin almacenamiento */ } }
async function pintarOptimizar(indice) {
  const lista = informesConPerfil();
  const cab = $('#op-cabeza'), secs = $('#op-secciones'), js = $('#op-juegos');
  if (!lista.length) { cab.innerHTML = ''; js.innerHTML = ''; vacioAnalizar(secs, 'Analiza tu PC (mejor en modo juego) para recibir recomendaciones a medida.'); return; }
  const idx = indice != null ? indice : indiceLocal(lista);
  llenarSelectorEquipo($('#op-equipo'), lista, idx);
  const inf = lista[idx];
  const d = await datosDe(inf);
  if (!d || !d.perfil) { cab.innerHTML = ''; js.innerHTML = ''; vacioAnalizar(secs, 'Este informe es de una versión anterior. Vuelve a analizar para verlo.'); return; }
  const r = window.Recomendaciones.recomendaciones({ perfil: d.perfil, ajustes: d.ajustes, idsHallazgos: d.idsHallazgos, juegosDetalle: d.juegosDetalle });
  const eq = inf.equipo;
  r.secciones.forEach(s => s.items.forEach(i => { if (i.estado === 'hacer' && leerHecho(eq, i.id)) { i.estado = 'ok'; i.marcado = true; } }));
  const todos = r.secciones.flatMap(s => s.items), ok = todos.filter(i => i.estado === 'ok').length, pend = todos.filter(i => i.estado === 'hacer').length;
  const pct = ok + pend ? Math.round(ok / (ok + pend) * 100) : 100;
  const b = r.balance, mx = Math.max(b.cpu || 0, b.gpu || 0, 1);
  const bloq = (d.bloqueadas || []).find(x => /procesador/i.test(x.nombre));
  cab.innerHTML = `<div class="tarjeta op-cabeza"><div>${anillo(pct, 150)}<small class="pie">${ok} de ${ok + pend} ajustes aplicados</small></div>
    <div class="balance ${b.tipo}"><h3>${esc(b.titulo)}</h3><p class="sub" style="margin:0">${esc(b.texto)}</p>
      <div class="duelo-barras">
        <div class="fila-barra"><span class="nombre">Procesador</span><span class="pista"><i style="width:${(b.cpu || 0) / mx * 100}%;--col:${b.tipo === 'cpu' ? 'var(--alto)' : 'var(--acc)'}"></i></span><span class="dato">${Math.round(b.cpu || 0)} pts</span></div>
        <div class="fila-barra"><span class="nombre">Gráfica</span><span class="pista"><i style="width:${(b.gpu || 0) / mx * 100}%;--col:${b.tipo === 'gpu' ? 'var(--alto)' : 'var(--acc)'}"></i></span><span class="dato">${Math.round(b.gpu || 0)} pts</span></div>
        <span class="leyenda-duelo">Potencia relativa para juegos (puntos de Doctor PC)</span>
      </div>
      ${bloq && b.tipo === 'cpu' ? `<p class="nota">${ico('info')} ${esc(bloq.motivo)}</p>` : ''}</div></div>`;
  animarAnillos(cab);
  const EST = { hacer: ['Pendiente', ''], ok: ['Hecho', 'ok'], info: ['Para saber', ''], nd: ['No disponible', ''] };
  secs.innerHTML = r.secciones.map(s => `<div class="seccion-op"><h2>${ico(s.icono)}${esc(s.titulo)}</h2><div class="lista">${s.items.map(i => `
    <div class="item rec ${i.estado}" data-id="${i.id}"><div class="cabeza">
      <span class="marca-rec" title="${i.estado === 'hacer' || i.marcado ? 'Marcar como hecho' : ''}">${ico('check')}</span>
      <div class="cuerpo"><b>${esc(i.titulo)}</b>
        <div class="chips"><span class="imp ${i.impacto}">Impacto ${i.impacto}</span><span class="est ${EST[i.estado][1]}">${EST[i.estado][0]}${i.marcado ? ' (marcado por ti)' : ''}</span></div>
        <div class="meta">${esc(i.texto)}</div>
        ${i.pasos.length ? `<details><summary>Cómo hacerlo</summary><ol>${i.pasos.map(p => `<li>${esc(p)}</li>`).join('')}</ol></details>` : ''}
        ${i.accion ? `<div class="acciones-rec"><button class="btn secundario" data-accion="${esc(i.accion.ajuste || '')}" data-vista="${esc(i.accion.vista || '')}">${esc(i.accion.texto)}</button></div>` : ''}
      </div></div></div>`).join('')}</div></div>`).join('');
  secs.querySelectorAll('.lista').forEach(escalonar);
  secs.querySelectorAll('[data-accion]').forEach(bt => bt.onclick = () => { if (bt.dataset.vista) mostrar(bt.dataset.vista); else if (bt.dataset.accion) api.abrirAjuste(bt.dataset.accion); });
  secs.querySelectorAll('.rec').forEach(el => {
    const it = todos.find(x => x.id === el.dataset.id);
    if (!it || !(it.estado === 'hacer' || it.marcado)) return;
    el.querySelector('.marca-rec').onclick = () => { guardarHecho(eq, it.id, !it.marcado); if (!it.marcado) sonar('paso', 4); pintarOptimizar(idx); };
  });
  js.innerHTML = r.juegos.length ? r.juegos.map(j => `<div class="juego-op"><div class="cab-j"><b>${esc(j.nombre)}</b><span class="calidad ${j.nivel}">${esc(j.calidad)}</span></div>
      ${j.consejos.length ? `<ul>${j.consejos.map(c => `<li>${esc(c)}</li>`).join('')}</ul>` : '<p class="sub" style="margin:0">Juega en la calidad indicada a 1080p.</p>'}</div>`).join('')
    : '<div class="vacio">No se detectaron juegos del catálogo en este equipo.</div>';
  escalonar(js);
}
$('#op-equipo').onchange = () => pintarOptimizar(Number($('#op-equipo').value));
