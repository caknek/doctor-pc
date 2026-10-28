// Overlay de Doctor PC en juegos: números con contorno (sin fondo) y una gráfica pequeña debajo de cada uno
'use strict';
const N = 40;
const hist = { fps: [], cpu: [], gpu: [], ram: [], vram: [] };
const colores = { fps: '#f9a8d4', cpu: '#60a5fa', gpu: '#4ade80', ram: '#fbbf24', vram: '#c084fc' };
const $ = id => document.getElementById(id);

function empujar(k, v) { hist[k].push(v == null || isNaN(v) ? null : Number(v)); if (hist[k].length > N) hist[k].shift(); }
function dibujar(k, max) {
  const svg = $('g-' + k), d = hist[k];
  const tope = max || 100;
  const pts = d.map((v, i) => v == null ? null : [(i + N - d.length) * (100 / (N - 1)), 9.5 - Math.min(1, Math.max(0, v / tope)) * 9]).filter(Boolean);
  if (pts.length < 2) { svg.innerHTML = ''; return; }
  const l = pts.map(p => p[0].toFixed(1) + ',' + p[1].toFixed(1)).join(' ');
  svg.innerHTML = `<polyline class="halo" points="${l}"/><polyline class="linea" stroke="${colores[k]}" points="${l}"/>`;
}
function claseTemp(t, umbral) {
  if (t == null) return '';
  if (t >= umbral) return 'peligro';
  if (t >= umbral - 8) return 'caliente';
  if (t >= umbral - 18) return 'calido';
  return '';
}
function temp(el, t, umbral, aprox) {
  el.className = 't ' + claseTemp(t, umbral);
  el.innerHTML = t == null ? '' : `${Math.round(t)}<small>°C${aprox ? '≈' : ''}</small>`;
}
const pct = v => v == null ? '–' : `${Math.round(v)}<small>%</small>`;
const gb = mb => `${(mb / 1024).toFixed(1)}<small>GB</small>`;

// Informa del tamaño real para que la ventana ocupe solo lo necesario
let ultimoTam = '';
function informarTam() {
  const r = $('panel').getBoundingClientRect();
  const w = Math.ceil(r.width) + 6, h = Math.ceil(r.height) + 6;
  const k = w + 'x' + h;
  if (k !== ultimoTam && window.overlay.tam) { ultimoTam = k; window.overlay.tam(w, h); }
}

const TEXTO_FPS = { permiso: 'sin permiso', 'sin-presentmon': 'no incluido', error: 'error', terminado: '', inactivo: '', iniciando: '…' };

window.overlay.onDatos(d => {
  document.body.classList.toggle('pequeno', d.tam === 'pequeno');
  // FPS (PresentMon)
  const f = d.fps;
  $('fila-fps').classList.toggle('oculto', !f);
  if (f) {
    if (f.v != null) {
      $('fps').textContent = Math.round(f.v);
      $('fpsBajo').innerHTML = f.bajo1 != null ? `1%&nbsp;${Math.round(f.bajo1)}` : '';
    } else {
      $('fps').textContent = '–';
      const txt = TEXTO_FPS[f.estado];
      $('fpsBajo').innerHTML = txt ? `<span class="aviso">${txt}</span>` : '';
    }
    empujar('fps', f.v);
    const maxFps = Math.max(30, ...hist.fps.filter(v => v != null)) * 1.1;
    dibujar('fps', maxFps);
  } else hist.fps.length = 0;
  // CPU y GPU
  $('cpu').innerHTML = pct(d.cpu);
  $('gpu').innerHTML = pct(d.gpu);
  temp($('cpuT'), d.cpuTemp, d.umbralCpu || 90, d.cpuTempFuente === 'acpi');
  temp($('gpuT'), d.gpuTemp, d.umbralGpu || 85, false);
  // RAM y VRAM
  const ramPct = d.ramTotal ? d.ramUsada / d.ramTotal * 100 : null;
  $('ram').innerHTML = d.ramUsada == null ? '–' : gb(d.ramUsada);
  $('ramP').innerHTML = ramPct == null ? '' : pct(ramPct);
  const vramPct = d.vramTotal ? d.vramUsada / d.vramTotal * 100 : null;
  $('fila-vram').classList.toggle('oculto', d.vramUsada == null);
  $('vram').innerHTML = d.vramUsada == null ? '–' : gb(d.vramUsada);
  $('vramP').innerHTML = vramPct == null ? '' : pct(vramPct);
  empujar('cpu', d.cpu); empujar('gpu', d.gpu); empujar('ram', ramPct); empujar('vram', vramPct);
  ['cpu', 'gpu', 'ram', 'vram'].forEach(k => dibujar(k));
  informarTam();
});

window.overlay.onAlerta(() => {
  const p = $('panel');
  p.classList.remove('alerta'); void p.offsetWidth; p.classList.add('alerta');
  setTimeout(() => p.classList.remove('alerta'), 7000);
});
