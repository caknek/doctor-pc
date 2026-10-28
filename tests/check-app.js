// Comprobaciones rápidas de la app (sin abrir ventanas): sintaxis, archivos y configuración del instalador.
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const raiz = path.join(__dirname, '..');
let fallos = 0;
const ok = (n, f) => { try { f(); console.log('  OK    ' + n); } catch (e) { console.log('  FALLO ' + n + ' -> ' + e.message); fallos++; } };

for (const f of ['main.js', 'preload.js', 'overlay-preload.js', 'renderer/app.js', 'renderer/overlay.js', 'renderer/conocimiento.js', 'renderer/capacidades.js', 'renderer/recomendaciones.js', 'renderer/sonidos.js']) {
  ok('Sintaxis ' + f, () => execFileSync(process.execPath, ['--check', path.join(raiz, f)]));
}
ok('Archivos necesarios', () => {
  for (const f of ['renderer/index.html', 'renderer/overlay.html', 'renderer/app.css', 'engine/monitor.ps1', 'engine/limpieza.ps1', 'engine/prueba-disco.ps1', 'sensores/Program.cs', 'renderer/icon.png', 'build/icon.ico', 'engine/DoctorPC.ps1', 'engine/datos/precios.json', 'engine/datos/catalogo_juegos.json', 'engine/datos/indices_hardware.json']) {
    if (!fs.existsSync(path.join(raiz, f))) throw new Error('falta ' + f);
  }
});
ok('Configuración del instalador y de las actualizaciones', () => {
  const p = require(path.join(raiz, 'package.json'));
  const pub = p.build.publish[0];
  if (pub.provider !== 'github' || pub.owner !== 'caknek' || pub.repo !== 'doctor-pc') throw new Error('publish mal configurado');
  if (!/^\d+\.\d+\.\d+$/.test(p.version)) throw new Error('versión no válida');
  if (!p.build.extraResources.some(r => r.from === 'engine')) throw new Error('el motor no se incluye en el instalador');
});
ok('La versión de la app coincide con la del motor', () => {
  const p = require(path.join(raiz, 'package.json'));
  const m = fs.readFileSync(path.join(raiz, 'engine/DoctorPC.ps1'), 'utf8').match(/\$script:Version = '([^']+)'/);
  if (!m || m[1] !== p.version) throw new Error(`app ${p.version} / motor ${m && m[1]}`);
});
ok('Los IDs usados por la interfaz existen en el HTML', () => {
  const html = fs.readFileSync(path.join(raiz, 'renderer/index.html'), 'utf8');
  const js = fs.readFileSync(path.join(raiz, 'renderer/app.js'), 'utf8');
  const ids = [...js.matchAll(/\$\('#([\w-]+)'\)/g)].map(m => m[1]);
  const faltan = [...new Set(ids)].filter(id => !html.includes(`id="${id}"`) && !js.includes(`id="${id}"`));
  if (faltan.length) throw new Error('faltan en el HTML: ' + faltan.join(', '));
});
ok('Las funciones del puente existen en preload.js', () => {
  const pre = fs.readFileSync(path.join(raiz, 'preload.js'), 'utf8');
  const js = fs.readFileSync(path.join(raiz, 'renderer/app.js'), 'utf8');
  const usadas = [...new Set([...js.matchAll(/api\.(\w+)\(/g)].map(m => m[1]))];
  const faltan = usadas.filter(f => !new RegExp('\\b' + f + ':').test(pre));
  if (faltan.length) throw new Error('faltan: ' + faltan.join(', '));
});
ok('Los canales IPC del preload tienen manejador en main.js', () => {
  const pre = fs.readFileSync(path.join(raiz, 'preload.js'), 'utf8');
  const main = fs.readFileSync(path.join(raiz, 'main.js'), 'utf8');
  const canales = [...pre.matchAll(/invoke\('([\w:-]+)'/g)].map(m => m[1]);
  const faltan = canales.filter(c => !main.includes(`ipcMain.handle('${c}'`));
  if (faltan.length) throw new Error('sin manejador: ' + faltan.join(', '));
});

ok('El instalador incluye el overlay', () => {
  const p = require(path.join(raiz, 'package.json'));
  for (const f of ['overlay-preload.js', 'renderer/**/*']) if (!p.build.files.includes(f)) throw new Error('falta ' + f + ' en build.files');
});

// ---- Base de conocimiento y recomendaciones (casos reales)
const K = require(path.join(raiz, 'renderer/conocimiento.js'));
const R = require(path.join(raiz, 'renderer/recomendaciones.js'));
const C = require(path.join(raiz, 'renderer/capacidades.js'));
ok('Familias de GPU', () => {
  const casos = [['AMD Radeon RX 6600', g => g.vendor === 'AMD' && g.afmf && g.lineasPcie === 8 && g.codificador === 'AMF'],
    ['NVIDIA GeForce RTX 3060', g => g.dlss && g.serie === 30 && !g.av1Codifica],
    ['NVIDIA GeForce RTX 4060', g => g.dlss && g.av1Codifica && g.lineasPcie === 8],
    ['NVIDIA GeForce GTX 1650', g => !g.dlss && g.codificador === 'NVENC'],
    ['AMD Radeon RX 6500 XT', g => g.lineasPcie === 4 && !g.codificador],
    ['Radeon RX 580 Series', g => g.soporteDriver === 'mantenimiento'],
    ['Intel(R) Arc(TM) B580 Graphics', g => g.vendor === 'Intel' && !g.integrada && g.sam],
    ['Intel(R) UHD Graphics 630', g => g.integrada && g.codificador === 'Quick Sync'],
    ['AMD Radeon(TM) Graphics', g => g.integrada]];
  for (const [n, f] of casos) if (!f(K.familiaGpu(n))) throw new Error('falla ' + n + ' ' + JSON.stringify(K.familiaGpu(n)));
});
ok('Familias de CPU (Resizable BAR, Quick Sync)', () => {
  const casos = [['Intel(R) Core(TM) i7-7700 CPU @ 3.60GHz', c => c.generacion === 7 && !c.rebar && c.quickSync && c.ramOficialMHz === 2400],
    ['Intel(R) Core(TM) i5-12400F', c => c.generacion === 12 && c.rebar && !c.quickSync],
    ['AMD Ryzen 5 5600 6-Core Processor', c => c.serieRyzen === 5 && c.rebar && c.pcie === 4],
    ['AMD Ryzen 5 2600 Six-Core Processor', c => !c.rebar],
    ['AMD Ryzen 5 5600G with Radeon Graphics', c => c.apu && c.pcie === 3]];
  for (const [n, f] of casos) if (!f(K.familiaCpu(n))) throw new Error('falla ' + n + ' ' + JSON.stringify(K.familiaCpu(n)));
});
ok('Recomendaciones para i7-7700 + RX 6600 (equipo del sobrino)', () => {
  const p = { Cpu: 'Intel(R) Core(TM) i7-7700 CPU @ 3.60GHz', CpuIndice: 87, CpuPlataforma: 'LGA1151', Gpu: 'AMD Radeon RX 6600', GpuIndice: 150, VramGB: 8, GpuIntegrada: false, SoloIntegrada: false,
    RamGB: 16, RamTipo: 'DDR4', RamMHz: 2400, RamMHzActual: 2133, RamModulos: 2, RamBajoVelocidad: true, Hz: 75, PlanEnergia: 'Equilibrado', Placa: 'ASUSTeK COMPUTER INC. PRIME B250M-A', TempCpu: 88, TempGpu: 76, TempGpuHot: 97, AniosEquipo: 9 };
  const r = R.recomendaciones({ perfil: p, ajustes: { ModoJuego: true, Hags: false, GrabacionFondo: true, IntegridadMemoria: true }, idsHallazgos: ['JUEGO-LIMITE-CPU'], juegosDetalle: [{ nombre: 'Cyberpunk 2077', recGpu: 155, minGpu: 100, recCpu: 195, minCpu: 90, enHDD: true, bajoMin: ['CPU'], bajoRec: ['GPU'], notas: [] }] });
  const ids = r.secciones.flatMap(s => s.items.map(i => i.id + ':' + i.estado));
  for (const esperado of ['afmf:hacer', 'sam:nd', 'pcie:info', 'hags:hacer', 'grabacion:hacer', 'modojuego:ok', 'xmp:hacer', 'ssd:hacer', 'temps:hacer']) if (!ids.includes(esperado)) throw new Error('falta ' + esperado + ' en ' + ids.join(','));
  if (r.balance.tipo !== 'cpu') throw new Error('el balance debería indicar límite de CPU');
  if (!/2400/.test(r.secciones.find(s => s.id === 'hardware').items.find(i => i.id === 'xmp').texto)) throw new Error('falta la nota de la placa B250');
  const cp = r.juegos[0]; if (!cp.consejos.some(c => /AFMF/.test(c))) throw new Error('Cyberpunk debería sugerir AFMF');
  const fr = R.refrigeracion(p, null).filter(x => x.relevante).map(x => x.id);
  for (const e of ['polvo', 'pasta-gpu', 'disipador']) if (!fr.includes(e)) throw new Error('refrigeración: falta ' + e);
  const caps = C.capacidades(p); if (caps.length < 12) throw new Error('pocas capacidades');
  if (caps.find(x => x.id === 'vr').nivel === 'no') throw new Error('RX 6600 sí permite VR');
});
ok('Capacidades de un portátil con gráficos integrados', () => {
  const caps = C.capacidades({ Cpu: 'AMD Ryzen 5 5500U with Radeon Graphics', CpuIndice: 108, Gpu: 'AMD Radeon(TM) Graphics', GpuIndice: 25, GpuIntegrada: true, SoloIntegrada: true, RamGB: 8, Hilos: 12, EsPortatil: true });
  if (caps.find(x => x.id === 'vr').nivel !== 'no') throw new Error('sin VR con gráficos integrados');
  if (!caps.find(x => x.id === 'nube')) throw new Error('debería sugerir juego en la nube');
});

if (fallos) { console.log(fallos + ' comprobación(es) fallaron.'); process.exit(1); }
console.log('Todas las comprobaciones de la app pasaron.');
