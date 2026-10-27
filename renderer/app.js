// Doctor PC — interfaz
'use strict';
const $ = s => document.querySelector(s);
const api = window.doctor;

const REPARACIONES = [
  { id: 'dism_sfc', nivel: 3, admin: true, nombre: 'Comprobar y reparar archivos de Windows (DISM + SFC)',
    desc: 'DISM repara la imagen de Windows (descarga componentes oficiales, necesita internet) y SFC restaura archivos de sistema dañados. No borra tus archivos ni programas. Tarda entre 15 y 40 minutos: no apagues el equipo. Se abrirá una ventana con el progreso.' },
  { id: 'chkdsk', nivel: 2, admin: true, nombre: 'Revisar el disco del sistema (solo lectura)',
    desc: 'Ejecuta chkdsk /scan: analiza el sistema de archivos sin repararlo ni reiniciar. Si encuentra errores, te dirá cómo programar la reparación.' },
  { id: 'memoria', nivel: 2, admin: true, nombre: 'Programar el Diagnóstico de memoria de Windows',
    desc: 'Abre la herramienta oficial. Te preguntará si quieres reiniciar ahora o en el próximo arranque. La prueba dura unos 15-20 minutos.' },
  { id: 'liberador', nivel: 2, admin: false, nombre: 'Abrir el Liberador de espacio en disco',
    desc: 'Abre la herramienta oficial. Tú eliges qué borrar (temporales, caché de actualizaciones, papelera). Pulsa "Limpiar archivos del sistema" para ver más opciones.' },
  { id: 'inicio', nivel: 2, admin: false, nombre: 'Elegir qué programas arrancan con Windows',
    desc: 'Abre el Administrador de tareas en "Aplicaciones de arranque". Desactivar un programa ahí es reversible.' },
  { id: 'energia', nivel: 3, admin: false, nombre: 'Cambiar el plan de energía a Equilibrado',
    desc: 'Cambia el plan de energía activo. El plan anterior queda anotado en el registro de cambios para poder volver a él.' },
  { id: 'graficos', nivel: 2, admin: false, nombre: 'Elegir la tarjeta gráfica de cada juego',
    desc: 'Abre Configuración > Pantalla > Gráficos para asignar "Alto rendimiento" a tus juegos (útil en portátiles con dos gráficas).' },
  { id: 'actualizaciones', nivel: 2, admin: false, nombre: 'Buscar drivers en Windows Update',
    desc: 'Abre las actualizaciones opcionales, donde Windows ofrece drivers adicionales. Tú decides qué instalar.' }
];

let estado = { config: {}, paises: [], informes: [], informeActual: null, analizando: false, update: {} };

// ------------------------------------------------------------------ utilidades
function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }
function toast(texto, ms = 3500) {
  const t = $('#toast'); t.textContent = texto; t.classList.remove('oculto');
  clearTimeout(toast._t); toast._t = setTimeout(() => t.classList.add('oculto'), ms);
}
function colorSalud(p) { return p >= 85 ? 'var(--ok)' : p >= 65 ? 'var(--medio)' : p >= 40 ? 'var(--alto)' : 'var(--crit)'; }
function anillo(p) { return `<div class="anillo" style="--p:${Number(p) || 0};--c:${colorSalud(p)}"><b>${p == null ? '–' : p}</b></div>`; }
function fecha(f, creado) {
  const d = f ? new Date(f) : new Date(creado);
  return isNaN(d) ? '' : d.toLocaleString('es', { dateStyle: 'medium', timeStyle: 'short' });
}
function opcionesPais(sel, valor) { sel.innerHTML = estado.paises.map(p => `<option ${p === valor ? 'selected' : ''}>${esc(p)}</option>`).join(''); }

function modal({ titulo, html, confirmar = 'Continuar', exigir = null, peligro = false }) {
  return new Promise(res => {
    $('#m-titulo').textContent = titulo;
    $('#m-cuerpo').innerHTML = html + (exigir ? `<p class="sub">Escribe <b>${esc(exigir)}</b> para confirmar.</p><input type="text" id="m-input" autocomplete="off">` : '');
    const si = $('#m-si'), no = $('#m-no');
    si.textContent = confirmar; si.classList.toggle('peligro', peligro);
    const input = $('#m-input');
    si.disabled = !!exigir;
    if (input) { input.oninput = () => { si.disabled = input.value !== exigir; }; setTimeout(() => input.focus(), 50); }
    const cerrar = v => { $('#modal').classList.add('oculto'); si.onclick = no.onclick = null; res(v); };
    si.onclick = () => cerrar(true); no.onclick = () => cerrar(false);
    $('#modal').classList.remove('oculto');
  });
}

// ------------------------------------------------------------------ navegación
function mostrar(vista) {
  document.querySelectorAll('.vista').forEach(v => v.classList.toggle('activa', v.id === 'v-' + vista));
  document.querySelectorAll('.nav').forEach(b => b.classList.toggle('activo', b.dataset.vista === vista || (vista === 'informe' && b.dataset.vista === 'informes')));
  if (vista === 'informes') pintarInformes();
  if (vista === 'reparaciones') pintarReparaciones();
}
document.querySelectorAll('[data-vista]').forEach(b => b.addEventListener('click', () => {
  if (estado.analizando && b.dataset.vista !== 'analizar') toast('El análisis sigue en curso; puedes volver a "Analizar" para verlo.');
  mostrar(b.dataset.vista);
}));

// ------------------------------------------------------------------ configuración
function leerOpciones() {
  return {
    pais: $('#o-pais').value,
    presupuesto: Number($('#o-presupuesto').value) || 0,
    sinLimite: $('#o-sinlimite').checked,
    usados: $('#o-usados').checked,
    admin: $('#o-admin').checked,
    modoJuego: $('#o-juego').checked,
    modoJuegoSeg: Number($('#o-segundos').value) || 120
  };
}
async function guardar(parcial) { estado.config = await api.guardarConfig(Object.assign({}, estado.config, parcial)); }

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
  $('#caja-segundos').classList.add('oculto');
  $('#a-fuente').value = c.fuenteW || '';
  $('#a-anonimo').checked = !!c.anonimo;
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
  $('#nota-duracion').textContent = on
    ? 'Al empezar tendrás 20 segundos para abrir tu juego; después mide mientras juegas.'
    : 'Tarda entre 1 y 2 minutos. No modifica nada.';
});
$('#a-fuente').addEventListener('change', () => guardar({ fuenteW: Math.max(0, Number($('#a-fuente').value) || 0) }));
$('#a-anonimo').addEventListener('change', () => guardar({ anonimo: $('#a-anonimo').checked }));

function pintarCarpetas() {
  const l = estado.config.carpetas || [];
  $('#lista-carpetas').innerHTML = l.length
    ? l.map((c, i) => `<div class="carpeta"><code title="${esc(c)}">${esc(c)}</code><button data-i="${i}" title="Quitar">Quitar</button></div>`).join('')
    : '<p class="sub">No has añadido carpetas.</p>';
  $('#lista-carpetas').querySelectorAll('button').forEach(b => b.onclick = async () => {
    const n = [...l]; n.splice(Number(b.dataset.i), 1); await guardar({ carpetas: n }); pintarCarpetas();
  });
}
$('#btn-add-carpeta').onclick = async () => {
  const r = await api.elegirCarpeta();
  if (r && !(estado.config.carpetas || []).includes(r)) { await guardar({ carpetas: [...(estado.config.carpetas || []), r] }); pintarCarpetas(); }
};

// ------------------------------------------------------------------ análisis
async function lanzar(extra = {}) {
  const o = Object.assign(leerOpciones(), { fuenteW: estado.config.fuenteW, carpetas: estado.config.carpetas, anonimo: estado.config.anonimo }, extra);
  const r = await api.analizar(o);
  if (!r.ok) { toast(r.mensaje); return; }
}
$('#btn-analizar').onclick = () => lanzar();
$('#btn-json').onclick = async () => {
  const ruta = await api.elegirJson();
  if (ruta) lanzar({ desdeJson: ruta, admin: false });
};
$('#btn-cancelar').onclick = async () => { $('#btn-cancelar').disabled = true; $('#p-texto').textContent = 'Cancelando…'; await api.cancelar(); };
$('#btn-empezar').onclick = async () => { await api.empezarYa(); $('#btn-empezar').classList.add('oculto'); };

function modoProgreso(activo) {
  estado.analizando = activo;
  $('#panel-inicio').classList.toggle('oculto', activo);
  $('#panel-progreso').classList.toggle('oculto', !activo);
}

api.onAnalisis(ev => {
  switch (ev.tipo) {
    case 'inicio':
      mostrar('analizar'); modoProgreso(true);
      $('#btn-cancelar').disabled = false;
      $('#p-titulo').textContent = ev.modoJuego ? 'Modo juego' : 'Analizando tu PC…';
      $('#p-aviso').classList.add('oculto');
      $('#btn-empezar').classList.add('oculto');
      $('#p-barra').style.width = '2%'; $('#p-pct').textContent = '0 %';
      $('#p-texto').textContent = ev.elevado ? 'Esperando el permiso de administrador…' : 'Preparando…';
      break;
    case 'progreso':
      $('#p-barra').style.width = Math.max(2, ev.pct) + '%';
      $('#p-pct').textContent = ev.pct + ' %';
      $('#p-texto').textContent = ev.texto;
      if (/^Abre tu juego/.test(ev.texto)) $('#btn-empezar').classList.remove('oculto');
      else if (/^Midiendo/.test(ev.texto)) $('#btn-empezar').classList.add('oculto');
      break;
    case 'aviso':
      $('#p-aviso').textContent = ev.texto; $('#p-aviso').classList.remove('oculto');
      break;
    case 'fin':
      modoProgreso(false);
      if (ev.informe && ev.informe.url) { abrirInforme(ev.informe); refrescarInformes(); }
      else toast('El análisis terminó, pero no se encontró el informe.');
      break;
    case 'cancelado':
      modoProgreso(false); toast('Análisis cancelado.');
      break;
    case 'error':
      modoProgreso(false);
      if (ev.codigo === 'uac') {
        modal({ titulo: 'Sin permiso de administrador', html: '<p>No se concedió el permiso. Puedes analizar igualmente sin permisos: faltarán la salud de los discos y algunos registros.</p>', confirmar: 'Analizar sin permisos' })
          .then(ok => { if (ok) lanzar({ admin: false }); });
      } else {
        modal({ titulo: 'No se pudo completar el análisis', html: `<p>${esc(ev.mensaje)}</p><p class="sub">Si se repite, envía este mensaje en GitHub (Acerca de > Ver el proyecto).</p>`, confirmar: 'Entendido' });
      }
      break;
  }
});

// ------------------------------------------------------------------ informes
function abrirInforme(inf) {
  estado.informeActual = inf;
  $('#marco').src = inf.url + '?t=' + Date.now();
  $('#i-titulo').textContent = `${inf.equipo || 'Equipo'} · ${fecha(inf.fecha, inf.creado)}${inf.salud != null ? ' · salud ' + inf.salud + '/100' : ''}`;
  opcionesPais($('#r-pais'), (inf.pais || '').replace(/ \(precios genéricos\)$/, '') || estado.config.pais);
  $('#r-presupuesto').value = inf.presupuesto != null && inf.presupuesto >= 0 ? inf.presupuesto : estado.config.presupuesto;
  mostrar('informe');
}
$('#btn-volver').onclick = () => mostrar('informes');
$('#btn-navegador').onclick = () => estado.informeActual && api.abrirEnNavegador(estado.informeActual.html);
$('#btn-archivo').onclick = () => estado.informeActual && api.mostrarArchivo(estado.informeActual.json);
$('#btn-recalcular').onclick = () => {
  const inf = estado.informeActual; if (!inf) return;
  lanzar({ desdeJson: inf.json, admin: false, pais: $('#r-pais').value, presupuesto: Number($('#r-presupuesto').value) || 0, sinLimite: false });
};
$('#btn-carpeta').onclick = $('#btn-carpeta2').onclick = () => api.abrirCarpetaInformes();

async function refrescarInformes() { estado.informes = await api.informes(); pintarUltimo(); }

function pintarUltimo() {
  const u = estado.informes[0];
  const caja = $('#ultimo');
  if (!u) { caja.classList.add('oculto'); return; }
  caja.classList.remove('oculto');
  caja.innerHTML = `<div class="ultimo">${anillo(u.salud)}<div style="flex:1;min-width:0"><h3>Último análisis: ${esc(u.equipo)} · ${esc(fecha(u.fecha, u.creado))}</h3>
    <ul class="mini-lista">${u.principales.map(h => `<li><span class="sev ${esc(h.severidad)}">${esc(h.severidad)}</span>${esc(h.titulo)}</li>`).join('') || '<li>Sin problemas importantes.</li>'}</ul></div>
    <button class="btn secundario" id="btn-ver-ultimo">Ver informe</button></div>`;
  $('#btn-ver-ultimo').onclick = () => abrirInforme(u);
}

function pintarInformes() {
  const l = estado.informes;
  const c = $('#lista-informes');
  if (!l.length) { c.innerHTML = '<div class="vacio">Aún no hay informes. Ve a "Analizar" para crear el primero.</div>'; return; }
  c.innerHTML = l.map((inf, i) => `<div class="item">${anillo(inf.salud)}
    <div class="cuerpo"><b>${esc(inf.equipo || 'Equipo')}</b> <span class="etq">${esc(inf.etiqueta || '')}</span>
      <div class="meta">${esc(fecha(inf.fecha, inf.creado))}${inf.pais ? ' · ' + esc(inf.pais) : ''}${inf.presupuesto != null ? ' · ' + (inf.presupuesto < 0 ? 'sin límite' : 'US$' + inf.presupuesto) : ''}</div>
      <ul class="mini-lista">${inf.principales.slice(0, 2).map(h => `<li><span class="sev ${esc(h.severidad)}">${esc(h.severidad)}</span>${esc(h.titulo)}</li>`).join('')}</ul></div>
    <div class="acciones"><button class="btn" data-abrir="${i}">Abrir</button><button class="btn secundario" data-borrar="${i}">Borrar</button></div></div>`).join('');
  c.querySelectorAll('[data-abrir]').forEach(b => b.onclick = () => { const inf = l[Number(b.dataset.abrir)]; if (inf.url) abrirInforme(inf); else toast('Falta el archivo HTML de este informe.'); });
  c.querySelectorAll('[data-borrar]').forEach(b => b.onclick = async () => {
    const inf = l[Number(b.dataset.borrar)];
    if (await modal({ titulo: 'Borrar informe', html: `<p>Se moverán a la papelera el informe y los datos de <b>${esc(inf.equipo)}</b> (${esc(fecha(inf.fecha, inf.creado))}).</p>`, confirmar: 'Mover a la papelera', peligro: true })) {
      await api.borrarInforme(inf.json); await refrescarInformes(); pintarInformes();
    }
  });
}

// ------------------------------------------------------------------ reparaciones
function pintarReparaciones() {
  const sugeridas = new Set((estado.informes[0] && estado.informes[0].reparaciones) || []);
  const orden = [...REPARACIONES].sort((a, b) => (sugeridas.has(b.id) ? 1 : 0) - (sugeridas.has(a.id) ? 1 : 0));
  $('#lista-reparaciones').innerHTML = orden.map(r => `<div class="item"><div class="cuerpo">
      <b>${esc(r.nombre)}</b>${sugeridas.has(r.id) ? '<span class="etq sugerida">Sugerida por tu último análisis</span>' : ''}${r.admin ? '<span class="etq">Pide administrador</span>' : ''}
      <div class="meta">${esc(r.desc)}</div></div>
      <div class="acciones"><button class="btn secundario" data-rep="${r.id}">Ejecutar…</button></div></div>`).join('');
  $('#lista-reparaciones').querySelectorAll('[data-rep]').forEach(b => b.onclick = () => reparar(REPARACIONES.find(r => r.id === b.dataset.rep), b));
}
async function reparar(r, boton) {
  const ok = await modal({ titulo: r.nombre, html: `<p>${esc(r.desc)}</p>`, confirmar: 'Ejecutar', exigir: r.nivel >= 3 ? 'SI' : null });
  if (!ok) return;
  boton.disabled = true; const t = boton.textContent; boton.textContent = 'En curso…';
  const res = await api.reparar(r.id);
  boton.disabled = false; boton.textContent = t;
  toast(res.mensaje || (res.ok ? 'Listo.' : 'No se pudo completar.'), 5000);
}

// ------------------------------------------------------------------ actualizaciones
function pintarUpdate(u) {
  estado.update = u || {};
  const p = $('#pildora-update'), btn = $('#btn-update'), txt = $('#u-texto'), notas = $('#u-notas'), caja = $('#u-barra-caja');
  const v = estado.version;
  p.classList.add('oculto'); notas.classList.add('oculto'); caja.classList.add('oculto'); btn.disabled = false;
  switch (u.estado) {
    case 'buscando': txt.textContent = `Versión instalada: ${v}. Buscando actualizaciones…`; btn.disabled = true; btn.textContent = 'Buscando…'; break;
    case 'al-dia': txt.textContent = `Versión instalada: ${v}. Tienes la última versión.`; btn.textContent = 'Buscar actualizaciones'; break;
    case 'disponible':
      txt.textContent = `Hay una versión nueva: ${u.version} (tienes la ${v}).`;
      if (u.notas) { notas.textContent = u.notas; notas.classList.remove('oculto'); }
      btn.textContent = 'Descargar e instalar';
      p.textContent = `⬆ Actualización ${u.version} disponible`; p.classList.remove('oculto');
      break;
    case 'descargando':
      txt.textContent = `Descargando la versión ${u.version || ''}… ${u.pct || 0} %`;
      caja.classList.remove('oculto'); $('#u-barra').style.width = (u.pct || 0) + '%';
      btn.disabled = true; btn.textContent = 'Descargando…';
      break;
    case 'listo':
      txt.textContent = `La versión ${u.version} está lista. Doctor PC se cerrará, se instalará y se volverá a abrir.`;
      btn.textContent = 'Reiniciar e instalar';
      p.textContent = '⬆ Reinicia para actualizar'; p.classList.remove('oculto');
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

// ------------------------------------------------------------------ inicio
(async function arrancar() {
  const d = await api.init();
  estado.config = d.config; estado.paises = d.paises; estado.informes = d.informes; estado.version = d.version;
  $('#version').textContent = 'v' + d.version;
  $('#a-carpeta').textContent = 'Se guardan en: ' + d.carpetaInformes;
  pintarOpciones(); pintarUltimo(); pintarUpdate(d.update || {});
  if (!d.motorOk) modal({ titulo: 'Falta el motor de diagnóstico', html: '<p>No se encontró DoctorPC.ps1. Reinstala Doctor PC.</p>', confirmar: 'Entendido' });
})();
