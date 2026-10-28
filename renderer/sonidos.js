// Doctor PC — sonidos sintetizados con Web Audio (sin archivos): escaneo, pasos, fin, alertas y limpieza.
(function (raiz) {
  'use strict';
  let ctx = null, maestro = null, activo = true, volumen = 0.6, sonar = null;

  function audio() {
    if (!ctx) {
      const AC = raiz.AudioContext || raiz.webkitAudioContext;
      if (!AC) return null;
      ctx = new AC();
      maestro = ctx.createGain();
      const comp = ctx.createDynamicsCompressor();
      maestro.connect(comp).connect(ctx.destination);
    }
    if (ctx.state === 'suspended') ctx.resume();
    maestro.gain.value = volumen * 0.5;
    return ctx;
  }

  // Un tono con envolvente suave
  function tono(f, inicio = 0, dur = 0.15, tipo = 'sine', ganancia = 0.25, fFin = null) {
    const a = audio(); if (!a || !activo) return;
    const t0 = a.currentTime + inicio;
    const o = a.createOscillator(), g = a.createGain();
    o.type = tipo;
    o.frequency.setValueAtTime(f, t0);
    if (fFin) o.frequency.exponentialRampToValueAtTime(fFin, t0 + dur);
    g.gain.setValueAtTime(0.0001, t0);
    g.gain.exponentialRampToValueAtTime(ganancia, t0 + 0.012);
    g.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
    o.connect(g).connect(maestro);
    o.start(t0); o.stop(t0 + dur + 0.05);
  }
  function campana(f, inicio = 0, dur = 0.9, g = 0.18) {
    tono(f, inicio, dur, 'sine', g);
    tono(f * 2, inicio, dur * 0.6, 'sine', g * 0.25);
    tono(f * 3.01, inicio, dur * 0.35, 'sine', g * 0.08);
  }

  const S = {
    configurar(on, vol) { activo = on !== false; if (vol != null) volumen = Math.max(0, Math.min(1, vol / 100)); if (!activo) S.pararSonar(); },
    // Arranque del escaneo: barrido ascendente + acorde
    inicio() { tono(220, 0, 0.45, 'sawtooth', 0.05, 880); tono(330, 0, 0.45, 'sine', 0.12, 1320); [523.25, 659.25, 783.99].forEach((f, i) => campana(f, 0.38 + i * 0.07, 0.7, 0.12)); },
    // Cada paso completado: notas de una escala que sube
    paso(i) { const esc = [523.25, 587.33, 659.25, 698.46, 783.99, 880, 987.77, 1046.5]; const f = esc[Math.min(i, esc.length - 1)]; tono(f, 0, 0.12, 'triangle', 0.16); tono(f * 1.5, 0.05, 0.14, 'sine', 0.08); },
    // Fin del escaneo: arpegio mayor brillante
    fin(bien = true) {
      const notas = bien ? [523.25, 659.25, 783.99, 1046.5] : [440, 523.25, 659.25];
      notas.forEach((f, i) => campana(f, i * 0.11, 1.1, 0.16));
    },
    // Sonar mientras escanea
    iniciarSonar() { S.pararSonar(); if (!activo) return; const ping = () => { tono(1318.5, 0, 0.5, 'sine', 0.05, 1200); tono(1318.5, 0.18, 0.4, 'sine', 0.02, 1250); }; ping(); sonar = setInterval(ping, 2200); },
    pararSonar() { if (sonar) { clearInterval(sonar); sonar = null; } },
    // Alerta de temperatura: dos tonos alternos
    alerta() { [0, 0.22, 0.44].forEach((t, i) => tono(i % 2 ? 660 : 880, t, 0.18, 'square', 0.07)); },
    // Limpieza o tarea completada: destellos
    exito() { [1046.5, 1318.5, 1568, 2093].forEach((f, i) => tono(f, i * 0.06, 0.22, 'triangle', 0.1)); },
    error() { tono(220, 0, 0.25, 'triangle', 0.18, 140); tono(196, 0.18, 0.35, 'triangle', 0.14, 110); },
    clic() { tono(1800, 0, 0.03, 'sine', 0.05); },
    cancelado() { tono(660, 0, 0.2, 'sine', 0.12, 330); }
  };
  raiz.Sonidos = S;
})(typeof window !== 'undefined' ? window : globalThis);
