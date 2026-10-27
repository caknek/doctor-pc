// Comprobaciones rápidas de la app (sin abrir ventanas): sintaxis, archivos y configuración del instalador.
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const raiz = path.join(__dirname, '..');
let fallos = 0;
const ok = (n, f) => { try { f(); console.log('  OK    ' + n); } catch (e) { console.log('  FALLO ' + n + ' -> ' + e.message); fallos++; } };

for (const f of ['main.js', 'preload.js', 'renderer/app.js']) {
  ok('Sintaxis ' + f, () => execFileSync(process.execPath, ['--check', path.join(raiz, f)]));
}
ok('Archivos necesarios', () => {
  for (const f of ['renderer/index.html', 'renderer/app.css', 'renderer/icon.png', 'build/icon.ico', 'engine/DoctorPC.ps1', 'engine/datos/precios.json', 'engine/datos/catalogo_juegos.json', 'engine/datos/indices_hardware.json']) {
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

if (fallos) { console.log(fallos + ' comprobación(es) fallaron.'); process.exit(1); }
console.log('Todas las comprobaciones de la app pasaron.');
