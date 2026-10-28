// Doctor PC — base de conocimiento de hardware (GPU y CPU) usada por "Qué puedes hacer" y "Optimizar juegos".
// Funciona en el navegador (window.Conocimiento) y en Node (module.exports) para las pruebas.
(function (raiz) {
  'use strict';

  const num = (x, d = 0) => (x == null || isNaN(Number(x)) ? d : Number(x));

  // ---------------------------------------------------------------- GPU
  function familiaGpu(nombre) {
    const n = String(nombre || '').replace(/\((R|TM)\)/gi, '').replace(/\s+/g, ' ').trim();
    const r = {
      nombre: n, vendor: '', familia: '', arq: '', serie: 0, integrada: false, rt: false,
      escaladores: [], generacionFrames: [], codificador: '', av1Codifica: false, av1Decodifica: false,
      lineasPcie: 16, pcieGen: 4, appDriver: '', soporteDriver: 'activo',
      rsr: false, afmf: false, antiLag: false, chill: false, sam: false, nis: false, reflex: false, dlss: false, xess: true
    };
    let m;
    if (/nvidia|geforce|rtx|gtx|quadro|\bmx\s?\d/i.test(n)) {
      r.vendor = 'NVIDIA'; r.appDriver = 'NVIDIA App'; r.nis = true;
      if ((m = n.match(/RTX\s*(\d{2})(\d{2})/i))) {
        const s = +m[1]; r.serie = s; r.familia = `GeForce RTX serie ${s}`; r.rt = true; r.dlss = true; r.reflex = true;
        r.arq = { 20: 'Turing', 30: 'Ampere', 40: 'Ada Lovelace', 50: 'Blackwell' }[s] || '';
        r.escaladores = ['DLSS', 'FSR', 'XeSS'];
        r.generacionFrames = s >= 50 ? ['DLSS Multi Frame Generation', 'Smooth Motion del driver'] : s >= 40 ? ['DLSS Frame Generation', 'Smooth Motion del driver'] : ['FSR Frame Generation (en juegos compatibles)'];
        r.codificador = 'NVENC'; r.av1Codifica = s >= 40; r.av1Decodifica = s >= 30; r.pcieGen = s >= 50 ? 5 : s >= 30 ? 4 : 3;
        if (/(3050|4050|4060|5050|5060)/.test(n) && !/laptop|max-q|mobile/i.test(n)) r.lineasPcie = 8;
      } else if ((m = n.match(/GTX\s*(\d{2})(\d{2})/i)) || (m = n.match(/GTX\s*(\d)(\d{2})/i))) {
        const s = +m[1]; r.serie = s; r.familia = `GeForce GTX serie ${s}`;
        r.arq = s === 16 ? 'Turing' : s === 10 ? 'Pascal' : s === 9 ? 'Maxwell' : 'Kepler o anterior';
        r.escaladores = ['FSR', 'XeSS', 'NIS (escalado del driver)'];
        r.generacionFrames = ['FSR Frame Generation (en juegos compatibles)'];
        r.codificador = /1630|1030/.test(n) ? '' : 'NVENC'; r.av1Decodifica = false; r.pcieGen = 3;
        if (s <= 10) r.soporteDriver = 'heredado';
      } else if (/GT\s*\d{3,4}|MX\s*\d{3}/i.test(n)) {
        r.familia = 'GeForce básica'; r.escaladores = ['FSR']; r.codificador = ''; r.pcieGen = 3; r.soporteDriver = 'heredado';
        if (/MX/i.test(n)) r.integrada = false;
      } else { r.familia = 'NVIDIA'; r.escaladores = ['FSR']; }
    } else if (/radeon|\bamd\b|\brx\s?\d/i.test(n)) {
      r.vendor = 'AMD'; r.appDriver = 'AMD Software: Adrenalin Edition'; r.antiLag = true; r.chill = true;
      if ((m = n.match(/RX\s*(9)(\d)(\d{2})/i))) {
        r.serie = 9000; r.familia = 'Radeon RX serie 9000'; r.arq = 'RDNA 4'; r.rt = true;
        r.escaladores = ['FSR 4', 'FSR', 'XeSS']; r.generacionFrames = ['AFMF (driver)', 'FSR Frame Generation']; r.rsr = r.afmf = r.sam = true;
        r.codificador = 'AMF'; r.av1Codifica = r.av1Decodifica = true; r.pcieGen = 5;
        if (/9060/.test(n)) r.lineasPcie = 16;
      } else if ((m = n.match(/RX\s*7(\d)(\d{2})/i))) {
        r.serie = 7000; r.familia = 'Radeon RX serie 7000'; r.arq = 'RDNA 3'; r.rt = true;
        r.escaladores = ['FSR', 'XeSS']; r.generacionFrames = ['AFMF 2 (driver)', 'FSR Frame Generation']; r.rsr = r.afmf = r.sam = true;
        r.codificador = 'AMF'; r.av1Codifica = r.av1Decodifica = true;
        if (/7600/.test(n)) r.lineasPcie = 8;
      } else if ((m = n.match(/RX\s*6(\d)(\d{2})/i))) {
        r.serie = 6000; r.familia = 'Radeon RX serie 6000'; r.arq = 'RDNA 2'; r.rt = true;
        r.escaladores = ['FSR', 'RSR (escalado del driver)', 'XeSS']; r.generacionFrames = ['AFMF 2 (driver)', 'FSR Frame Generation']; r.rsr = r.afmf = r.sam = true;
        r.codificador = 'AMF'; r.av1Decodifica = true;
        if (/6600|6650/.test(n)) r.lineasPcie = 8;
        if (/6500|6400/.test(n)) { r.lineasPcie = 4; r.codificador = ''; r.av1Decodifica = false; }
      } else if ((m = n.match(/RX\s*5(\d)(\d{2})/i))) {
        r.serie = 5000; r.familia = 'Radeon RX serie 5000'; r.arq = 'RDNA'; r.escaladores = ['FSR', 'RSR (escalado del driver)', 'XeSS'];
        r.generacionFrames = ['FSR Frame Generation (en juegos compatibles)']; r.rsr = true; r.codificador = 'AMF';
        if (/5500|5300/.test(n)) r.lineasPcie = 8;
      } else if (/RX\s*(4[5-9]0|5[5-9]0)\b|Vega\s*(56|64)/i.test(n)) {
        r.serie = 500; r.familia = /Vega/i.test(n) ? 'Radeon RX Vega' : 'Radeon RX 400/500 (Polaris)'; r.arq = /Vega/i.test(n) ? 'Vega' : 'Polaris';
        r.escaladores = ['FSR', 'XeSS']; r.generacionFrames = ['FSR Frame Generation (en juegos compatibles)']; r.codificador = 'AMF'; r.pcieGen = 3;
        r.soporteDriver = 'mantenimiento';
        if (/RX\s*5[56]0|RX\s*4[56]0/i.test(n)) r.lineasPcie = 8;
      } else if (/(890|880|860|780|760|740|680|660|610)M/i.test(n)) {
        r.integrada = true; r.familia = 'Radeon integrada (RDNA)'; r.arq = /(890|880|860)M/i.test(n) ? 'RDNA 3.5' : /(780|760|740)M/i.test(n) ? 'RDNA 3' : 'RDNA 2';
        r.escaladores = ['FSR', 'RSR (escalado del driver)', 'XeSS']; r.rsr = true; r.afmf = /(890|880|860|780|760|740)M/i.test(n);
        r.generacionFrames = r.afmf ? ['AFMF 2 (driver)'] : ['FSR Frame Generation (en juegos compatibles)']; r.codificador = 'AMF'; r.av1Decodifica = true; r.av1Codifica = /(890|880|860|780|760|740)M/i.test(n);
      } else if (/Vega|Radeon\s*\(TM\)\s*Graphics|Radeon Graphics|R[357] Graphics/i.test(n)) {
        r.integrada = true; r.familia = 'Radeon integrada (Vega)'; r.arq = 'Vega'; r.escaladores = ['FSR', 'XeSS'];
        r.generacionFrames = ['FSR Frame Generation (en juegos compatibles)']; r.codificador = 'AMF'; r.soporteDriver = 'mantenimiento';
      } else { r.familia = 'Radeon'; r.escaladores = ['FSR']; }
    } else if (/intel|arc|iris|uhd|hd graphics/i.test(n)) {
      r.vendor = 'Intel'; r.appDriver = 'Intel Graphics Software';
      if (/Arc\s*[AB]\d{3}/i.test(n)) {
        const b = /Arc\s*B/i.test(n);
        r.familia = b ? 'Intel Arc serie B' : 'Intel Arc serie A'; r.arq = b ? 'Xe2 (Battlemage)' : 'Xe-HPG (Alchemist)'; r.rt = true;
        r.escaladores = ['XeSS', 'FSR']; r.generacionFrames = b ? ['XeSS Frame Generation', 'FSR Frame Generation'] : ['FSR Frame Generation (en juegos compatibles)'];
        r.codificador = 'Quick Sync (Arc)'; r.av1Codifica = r.av1Decodifica = true; r.lineasPcie = 8; r.sam = true;
      } else {
        r.integrada = true; r.familia = /Iris Xe|Arc.*Graphics|140V|130V/i.test(n) ? 'Intel Iris Xe / Arc integrada' : 'Intel HD/UHD integrada';
        r.escaladores = ['FSR', 'XeSS']; r.generacionFrames = ['FSR Frame Generation (en juegos compatibles)'];
        r.codificador = 'Quick Sync'; r.av1Decodifica = /Iris Xe|Arc|140V|130V/i.test(n);
        r.xess = /Iris Xe|Arc|140V|130V/i.test(n);
      }
    }
    if (r.vendor && !r.escaladores.length) r.escaladores = ['FSR'];
    return r;
  }

  // ---------------------------------------------------------------- CPU
  function familiaCpu(nombre, plataforma) {
    const n = String(nombre || '').replace(/\((R|TM)\)/gi, '');
    const r = { nombre: n.replace(/\s+CPU\s+@.*$/i, '').replace(/\s+/g, ' ').trim(), vendor: '', generacion: 0, serieRyzen: 0, rebar: false, quickSync: false, pcie: 3, ramOficialMHz: 0, x3d: /X3D/i.test(n), apu: false, plataforma: plataforma || '' };
    let m;
    if (/intel/i.test(n)) {
      r.vendor = 'Intel';
      if ((m = n.match(/i[3579]-(\d{4,5})([A-Z]*)/i))) {
        const num4 = m[1], suf = (m[2] || '').toUpperCase();
        r.generacion = num4.length === 5 ? +num4.slice(0, 2) : num4.startsWith('1') && num4.length === 4 ? +num4.slice(0, 2) : +num4[0];
        r.quickSync = !/F/.test(suf);
      } else if ((m = n.match(/Ultra\s*[3579]\s*(\d)\d{2}/i))) { r.generacion = 14 + +m[1]; r.quickSync = !/\d{3}F/i.test(n); }
      else r.quickSync = !/\bF\b/.test(n);
      r.rebar = r.generacion >= 10;
      r.pcie = r.generacion >= 12 ? 5 : r.generacion >= 11 ? 4 : 3;
      r.ramOficialMHz = { 6: 2133, 7: 2400, 8: 2666, 9: 2666, 10: 2933, 11: 3200, 12: 4800, 13: 5600, 14: 5600 }[r.generacion] || 0;
    } else if (/amd|ryzen|athlon|fx-/i.test(n)) {
      r.vendor = 'AMD';
      if ((m = n.match(/Ryzen\s*[3579]\s*(?:PRO\s*)?(\d)(\d)(\d{2})([A-Z0-9]*)/i))) {
        r.serieRyzen = +m[1]; const suf = (m[4] || '').toUpperCase();
        r.apu = /G/.test(suf);
        r.rebar = r.serieRyzen >= 3 && !(r.serieRyzen === 3 && r.apu);
        r.pcie = r.serieRyzen >= 7 ? 5 : (r.serieRyzen >= 3 && !r.apu) ? 4 : 3;
        r.ramOficialMHz = { 1: 2666, 2: 2933, 3: 3200, 4: 3200, 5: 3200, 7: 5200, 8: 5200, 9: 5600 }[r.serieRyzen] || 0;
      }
    }
    return r;
  }

  // ---------------------------------------------------------------- calidad estimada por juego
  function presetJuego(j, p) {
    const gi = num(p.GpuIndice), ci = num(p.CpuIndice);
    const r = { calidad: '', escalado: false, cpuLimita: false, nivel: 'ok', ratioGpu: null, ratioCpu: null };
    if (!j || j.recGpu == null || !gi) { r.calidad = 'Sin datos'; r.nivel = 'info'; return r; }
    const rg = gi / Math.max(1, num(j.recGpu)), rc = ci && j.recCpu ? ci / Math.max(1, num(j.recCpu)) : 1;
    r.ratioGpu = Math.round(rg * 100) / 100; r.ratioCpu = Math.round(rc * 100) / 100;
    if (rg >= 1.7) r.calidad = 'Ultra';
    else if (rg >= 1.25) r.calidad = 'Alto';
    else if (rg >= 0.95) r.calidad = 'Medio-alto';
    else if (rg >= 0.75) { r.calidad = 'Medio'; r.escalado = true; }
    else if (gi >= num(j.minGpu)) { r.calidad = 'Bajo'; r.escalado = true; r.nivel = 'justo'; }
    else { r.calidad = 'Muy bajo (720p o escalado agresivo)'; r.escalado = true; r.nivel = 'mal'; }
    r.cpuLimita = rc < 0.9;
    return r;
  }

  const api = { familiaGpu, familiaCpu, presetJuego, num };
  raiz.Conocimiento = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
