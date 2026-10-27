// Uso: npm run nueva-version -- 0.3.0
// Cambia la versión en package.json y en el motor. Al subirlo a main, GitHub publica la versión.
const fs = require('fs');
const path = require('path');
const v = process.argv[2];
if (!/^\d+\.\d+\.\d+$/.test(v || '')) { console.error('Indica la versión, por ejemplo: npm run nueva-version -- 0.3.0'); process.exit(1); }
const raiz = path.join(__dirname, '..');
const pj = path.join(raiz, 'package.json');
const p = JSON.parse(fs.readFileSync(pj, 'utf8'));
p.version = v;
fs.writeFileSync(pj, JSON.stringify(p, null, 2) + '\n');
const lock = path.join(raiz, 'package-lock.json');
if (fs.existsSync(lock)) {
  const l = JSON.parse(fs.readFileSync(lock, 'utf8'));
  l.version = v; if (l.packages && l.packages['']) l.packages[''].version = v;
  fs.writeFileSync(lock, JSON.stringify(l, null, 2) + '\n');
}
const motor = path.join(raiz, 'engine', 'DoctorPC.ps1');
const t = fs.readFileSync(motor, 'utf8').replace(/\$script:Version = '[^']*'/, `$script:Version = '${v}'`);
fs.writeFileSync(motor, t.startsWith('﻿') ? t : '﻿' + t, 'utf8');
console.log(`Versión ${v} lista. Escribe las novedades en build/release-notes.md y sube los cambios a main.`);
