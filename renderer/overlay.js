// Overlay de Doctor PC en juegos: números grandes y una gráfica pequeña debajo de cada uno
'use strict';
const N = 40;
const hist = { cpu: [], gpu: [], ram: [], vram: [] };
const colores = { cpu: '#60a5fa', gpu: '#4ade80', ram: '#fbbf24', vram: '#c084fc' };
const $ = id => document.getElementById(id);

function empujar(k, v) { hist[k].push(v == null || isNaN(v) ? null : Number(v)); if (hist[k].length > N) hist[k].shift(); }
function dibujar(k) {
  const svg = $('g-' + k), d = hist[k];
  const pts = d.map((v, i) => v == null ? null : [(i + N - d.length) * (100 / (N - 1)), 12.5 - Math.min(1, v / 100) * 11.5]).filter(Boolean);
  if (pts.length < 2) { svg.innerHTML = ''; return; }
  const l = pts.map(p => p[0].toFixed(1) + ',' + p[1].toFixed(1)).join(' ');
  svg.innerHTML = `<polygon fill="${colores[k]}" points="${pts[0][0].toFixed(1)},13 ${l} ${pts[pts.length - 1][0].toFixed(1)},13"/><polyline stroke="${colores[k]}" points="${l}"/>`;
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
  el.innerHTML = t == null ? '<small>sin sensor</small>' : `${Math.round(t)}<small>°C${aprox ? '≈' : ''}</small>`;
}

window.overlay.onDatos(d => {
  document.body.classList.toggle('pequeno', d.tam === 'pequeno');
  $('juego').textContent = d.juego || d.gpuNombre || '';
  $('cpu').innerHTML = d.cpu == null ? '–' : `${Math.round(d.cpu)}<small>%</small>`;
  $('gpu').innerHTML = d.gpu == null ? '–' : `${Math.round(d.gpu)}<small>%</small>`;
  temp($('cpuT'), d.cpuTemp, d.umbralCpu || 90, d.cpuTempFuente === 'acpi');
  temp($('gpuT'), d.gpuTemp, d.umbralGpu || 85, false);
  const ramPct = d.ramTotal ? d.ramUsada / d.ramTotal * 100 : null;
  $('ram').innerHTML = d.ramUsada == null ? '–' : `${(d.ramUsada / 1024).toFixed(1)}<small>GB</small>`;
  $('ramP').innerHTML = ramPct == null ? '' : `${Math.round(ramPct)}<small>%</small>`;
  const vramPct = d.vramTotal ? d.vramUsada / d.vramTotal * 100 : null;
  $('fila-vram').style.display = d.vramUsada == null ? 'none' : '';
  $('vram').innerHTML = d.vramUsada == null ? '–' : `${(d.vramUsada / 1024).toFixed(1)}<small>GB</small>`;
  $('vramP').innerHTML = vramPct == null ? '' : `${Math.round(vramPct)}<small>%</small>`;
  empujar('cpu', d.cpu); empujar('gpu', d.gpu); empujar('ram', ramPct); empujar('vram', vramPct);
  ['cpu', 'gpu', 'ram', 'vram'].forEach(dibujar);
});

window.overlay.onAlerta(() => {
  const p = $('panel');
  p.classList.remove('alerta'); void p.offsetWidth; p.classList.add('alerta');
  setTimeout(() => p.classList.remove('alerta'), 7000);
});
