// Doctor PC — "Optimizar juegos": recomendaciones para rendir más con el MISMO hardware,
// y consejos de refrigeración según las temperaturas medidas.
(function (raiz) {
  'use strict';
  const K = raiz.Conocimiento || (typeof require !== 'undefined' ? require('./conocimiento.js') : null);
  const num = K.num;

  const corto = n => String(n || '').replace(/\((R|TM)\)/gi, '').replace(/\s+CPU\s+@.*$/i, '').replace(/^(NVIDIA|AMD|Intel)\s+/i, '').replace(/GeForce\s+/i, '').replace(/\s*(Six|Eight|Quad|Twelve|Sixteen)-Core Processor/i, '').replace(/ with Radeon.*$/i, '').replace(/\s+/g, ' ').trim();

  // ---------------------------------------------------------------- estados de temperatura
  function estadoTemp(tipo, t, portatil) {
    if (t == null || isNaN(t)) return { clave: 'nd', texto: 'Sin dato' };
    const lim = {
      cpu: portatil ? [65, 80, 90, 97] : [60, 75, 85, 95],
      gpu: [60, 75, 83, 90],
      hot: [75, 90, 100, 108]
    }[tipo] || [60, 75, 85, 95];
    if (t < lim[0]) return { clave: 'frio', texto: 'Fría' };
    if (t < lim[1]) return { clave: 'normal', texto: 'Normal' };
    if (t < lim[2]) return { clave: 'calido', texto: 'Cálida' };
    if (t < lim[3]) return { clave: 'caliente', texto: 'Caliente' };
    return { clave: 'peligro', texto: 'Peligro' };
  }

  // ---------------------------------------------------------------- balance CPU / GPU
  function balance(p, ids) {
    const gi = num(p.GpuIndice), ci = num(p.CpuIndice);
    const cpuN = corto(p.Cpu), gpuN = corto(p.Gpu);
    const medidoCpu = ids.includes('JUEGO-LIMITE-CPU'), medidoGpu = ids.includes('JUEGO-LIMITE-GPU');
    if (p.SoloIntegrada) return { tipo: 'gpu', titulo: 'Los gráficos integrados marcan el límite', texto: `Con gráficos integrados, casi todo lo decide la gráfica y la memoria RAM. Lo que más ayuda: RAM en doble canal, resolución de renderizado al 70-80 % con FSR y ajustes bajos.`, cpu: ci, gpu: gi };
    const ratio = ci ? gi / ci : 1;
    if (medidoCpu || ratio >= 1.45) {
      return { tipo: 'cpu', titulo: `Tu ${gpuN} es más potente de lo que tu ${cpuN} puede alimentar`, medido: medidoCpu,
        texto: `En juegos que exigen mucho al procesador (mundos abiertos, multijugador masivo, CS2) la gráfica espera al procesador${medidoCpu ? ' (lo medimos en tu partida)' : ''}. Consecuencia práctica: bajar gráficos casi no sube los FPS, y subirlos casi no los baja. Aprovéchalo: sube calidad y resolución, y reduce solo lo que carga el procesador.`, cpu: ci, gpu: gi };
    }
    if (medidoGpu || ratio <= 0.6) return { tipo: 'gpu', titulo: `La gráfica (${gpuN}) es el límite`, medido: medidoGpu,
      texto: 'La tarjeta gráfica marca los FPS: bajar sombras, efectos y resolución (o usar escalado) sí sube el rendimiento.', cpu: ci, gpu: gi };
    return { tipo: 'equilibrado', titulo: 'Procesador y gráfica están equilibrados', texto: 'Ninguno de los dos frena claramente al otro: los ajustes gráficos y el escalado tienen efecto directo en los FPS.', cpu: ci, gpu: gi };
  }

  // ---------------------------------------------------------------- recomendaciones
  function recomendaciones(d) {
    const p = d.perfil || {}, aj = d.ajustes || {}, ids = d.idsHallazgos || [], juegos = d.juegosDetalle || [];
    const g = K.familiaGpu(p.Gpu), c = K.familiaCpu(p.Cpu, p.CpuPlataforma);
    const gpuN = corto(p.Gpu), cpuN = corto(p.Cpu);
    const bal = balance(p, ids);
    const secciones = [];
    const hz = num(p.Hz);
    const limiteFps = hz > 0 ? Math.max(30, hz - 3) : 0;
    const item = (o) => Object.assign({ impacto: 'medio', estado: 'hacer', pasos: [], accion: null }, o);

    // ---- Driver de la gráfica
    const drv = [];
    if (g.vendor === 'AMD') {
      if (g.afmf) drv.push(item({ id: 'afmf', impacto: 'alto', titulo: 'Activa AMD Fluid Motion Frames (AFMF)',
        texto: `El driver genera fotogramas intermedios en juegos DirectX 11 y 12: con unos 60 FPS reales verás alrededor de 100.${bal.tipo === 'cpu' ? ' Es justo lo que necesitas: no carga al procesador, que es tu límite.' : ''} Añade algo de latencia, así que en competitivos (CS2, Valorant) mejor desactivado.`,
        pasos: ['Abre AMD Software (clic derecho en el escritorio).', 'Juegos > Gráficos (o el perfil del juego) > AMD Fluid Motion Frames: Activado.', 'Funciona mejor si el juego ya llega a 55-60 FPS reales.'], accion: { texto: 'Abrir AMD Software', ajuste: 'amd' } }));
      drv.push(item({ id: 'antilag', impacto: 'medio', titulo: 'Activa Radeon Anti-Lag', texto: 'Reduce el retraso entre tu ratón y la pantalla. Notable en shooters y juegos competitivos.',
        pasos: ['AMD Software > Juegos > Gráficos > Radeon Anti-Lag: Activado.'], accion: { texto: 'Abrir AMD Software', ajuste: 'amd' } }));
      drv.push(item({ id: 'chill', impacto: 'medio', titulo: limiteFps ? `Limita los FPS a ${limiteFps} con Radeon Chill` : 'Limita los FPS con Radeon Chill',
        texto: `Con los FPS ligeramente por debajo del refresco de tu monitor${hz ? ` (${hz} Hz)` : ''} la imagen es más estable, la gráfica se calienta menos y hace menos ruido.`,
        pasos: ['AMD Software > Juegos > Gráficos > Radeon Chill: Activado.', limiteFps ? `Pon el mínimo y el máximo en ${limiteFps} FPS.` : 'Pon el máximo justo por debajo del refresco de tu monitor.'], accion: { texto: 'Abrir AMD Software', ajuste: 'amd' } }));
      drv.push(item({ id: 'freesync', impacto: hz > 60 ? 'medio' : 'bajo', titulo: 'Activa FreeSync', texto: 'Si tu monitor es compatible, sincroniza la pantalla con la gráfica: adiós al "tearing" y a los tirones al bajar los FPS.',
        pasos: ['Activa FreeSync / Adaptive Sync en el menú del propio monitor.', 'AMD Software > Pantalla > AMD FreeSync: Activado.'], accion: { texto: 'Abrir AMD Software', ajuste: 'amd' } }));
      if (g.rsr) drv.push(item({ id: 'rsr', impacto: 'bajo', titulo: 'Radeon Super Resolution para juegos sin FSR', texto: 'En juegos antiguos que no tienen FSR, el driver puede escalar la imagen. Úsalo solo si te faltan FPS.',
        pasos: ['AMD Software > Juegos > Gráficos > Radeon Super Resolution: Activado.', 'En el juego, elige una resolución algo menor que la de tu monitor (en pantalla completa).'] }));
      drv.push(item({ id: 'ris', impacto: 'bajo', titulo: 'Radeon Image Sharpening', texto: 'Devuelve nitidez cuando usas escalado (FSR) o resoluciones bajas, prácticamente sin coste.',
        pasos: ['AMD Software > Juegos > Gráficos > Radeon Image Sharpening: Activado (nitidez 50-80 %).'] }));
    } else if (g.vendor === 'NVIDIA') {
      if (g.dlss) drv.push(item({ id: 'dlss', impacto: 'alto', titulo: 'Usa DLSS en tus juegos', texto: `Tu ${gpuN} tiene DLSS: renderiza a menor resolución y la reconstruye con IA. En modo Calidad gana 30-50 % de FPS con una imagen casi igual.${g.serie >= 40 ? ' Además tiene Frame Generation para multiplicar los FPS en juegos compatibles.' : ''}`,
        pasos: ['En cada juego: Gráficos > Escalado/Upscaling > DLSS > Calidad (1080p) o Equilibrado (1440p).', 'NVIDIA App > Gráficos permite actualizar DLSS a la última versión en muchos juegos.'], accion: { texto: 'Abrir NVIDIA App', ajuste: 'nvidia' } }));
      if (g.reflex) drv.push(item({ id: 'reflex', impacto: 'medio', titulo: 'Activa NVIDIA Reflex en competitivos', texto: 'Reduce el retraso del ratón en Valorant, Fortnite, CS2, Apex y más.', pasos: ['En el juego: NVIDIA Reflex Low Latency > Activado + Boost.'] }));
      else drv.push(item({ id: 'lowlat', impacto: 'medio', titulo: 'Modo de baja latencia', texto: 'Reduce el retraso entre el ratón y la pantalla.', pasos: ['NVIDIA App o Panel de control > Modo de baja latencia: Activado.'], accion: { texto: 'Abrir NVIDIA App', ajuste: 'nvidia' } }));
      drv.push(item({ id: 'limfps', impacto: 'medio', titulo: limiteFps ? `Limita los FPS a ${limiteFps}` : 'Limita los FPS', texto: 'Un límite justo por debajo del refresco del monitor estabiliza la imagen y baja temperatura y ruido.', pasos: ['NVIDIA App > Gráficos > Velocidad de fotogramas máxima.'], accion: { texto: 'Abrir NVIDIA App', ajuste: 'nvidia' } }));
      drv.push(item({ id: 'gsync', impacto: hz > 60 ? 'medio' : 'bajo', titulo: 'Activa G-SYNC (o G-SYNC Compatible)', texto: 'Si tu monitor es FreeSync/Adaptive Sync, NVIDIA puede sincronizarlo igualmente: menos tirones al bajar los FPS.', pasos: ['Panel de control de NVIDIA > Pantalla > Configurar G-SYNC.'] }));
      if (!g.dlss) drv.push(item({ id: 'nis', impacto: 'medio', titulo: 'Usa FSR o el escalado de NVIDIA (NIS)', texto: 'Tu gráfica no tiene DLSS, pero FSR en los juegos (o NIS desde el driver) da FPS extra.', pasos: ['En el juego: Escalado > FSR > Calidad.', 'Juegos sin FSR: NVIDIA App > Gráficos > Escalado de imagen.'] }));
      if (g.soporteDriver === 'heredado') drv.push(item({ id: 'drvheredado', impacto: 'bajo', estado: 'info', titulo: 'Tu gráfica ya no recibe optimizaciones nuevas', texto: 'NVIDIA mantiene esta serie solo con actualizaciones de seguridad: usa la última versión disponible y no esperes mejoras para juegos nuevos.' }));
    } else if (g.vendor === 'Intel' && !g.integrada) {
      drv.push(item({ id: 'arc-rebar', impacto: 'alto', titulo: 'Resizable BAR es obligatorio en Intel Arc', estado: c.rebar ? 'hacer' : 'info',
        texto: c.rebar ? 'Las Arc pierden hasta un 40 % sin Resizable BAR. Comprueba que está activo en la BIOS.' : `Tu ${cpuN} no admite Resizable BAR: las Arc rinden bastante menos sin él. Tenlo en cuenta antes de invertir más en esta plataforma.`,
        pasos: c.rebar ? ['BIOS: activa "Above 4G Decoding" y "Re-Size BAR Support".', 'BIOS: desactiva CSM (arranque UEFI puro).'] : [] }));
      drv.push(item({ id: 'xess', impacto: 'alto', titulo: 'Usa XeSS en tus juegos', texto: 'El escalado de Intel funciona mejor en las Arc que FSR.', pasos: ['En el juego: Escalado > XeSS > Calidad.'] }));
      drv.push(item({ id: 'arc-drv', impacto: 'alto', titulo: 'Mantén el driver al día', texto: 'Los drivers de Intel Arc mejoran mucho el rendimiento de un mes a otro.', accion: { texto: 'Descargar driver', ajuste: 'intelweb' } }));
    }
    if (g.integrada || p.SoloIntegrada) {
      drv.push(item({ id: 'igpu-escala', impacto: 'alto', titulo: 'Resolución de renderizado al 70-80 % con FSR', texto: 'Con gráficos integrados es lo que más FPS da: el juego se ve casi igual en un monitor 1080p.', pasos: ['En el juego: Escala de resolución 70-80 % o FSR en modo Rendimiento.'] }));
      if (g.vendor === 'AMD') drv.push(item({ id: 'uma', impacto: 'medio', titulo: 'Asigna más memoria de vídeo en la BIOS', texto: 'Las Radeon integradas usan la RAM como VRAM. Con 16 GB de RAM o más, reservar 2-4 GB evita tirones en juegos que comprueban la VRAM.', pasos: ['BIOS > Advanced > AMD CBS/NBIO > GFX Configuration > UMA Frame Buffer Size: 2G o 4G.'] }));
    }
    // Smart Access Memory / Resizable BAR (AMD y NVIDIA)
    if ((g.vendor === 'AMD' && g.sam) || (g.vendor === 'NVIDIA' && g.serie >= 30)) {
      const nom = g.vendor === 'AMD' ? 'Smart Access Memory (Resizable BAR)' : 'Resizable BAR';
      if (c.rebar) drv.push(item({ id: 'sam', impacto: 'medio', titulo: `Activa ${nom}`, texto: 'Permite al procesador acceder a toda la memoria de la gráfica: entre 0 y 10 % más de FPS según el juego.',
        pasos: ['BIOS: activa "Above 4G Decoding" y "Re-Size BAR Support".', 'BIOS: desactiva CSM (Windows debe arrancar en modo UEFI).', g.vendor === 'AMD' ? 'AMD Software > Rendimiento > Ajuste: comprueba que Smart Access Memory aparece activo.' : 'Panel de control de NVIDIA > Información del sistema > Resizable BAR: Sí.'] }));
      else drv.push(item({ id: 'sam', impacto: 'bajo', estado: 'nd', titulo: `${nom}: no disponible con tu procesador`, texto: `Necesita Intel Core de 10.ª generación o Ryzen 3000 en adelante. Con tu ${cpuN} no se puede activar. No te preocupes: la diferencia suele ser pequeña.` }));
    }
    // Líneas PCIe
    if (!g.integrada && g.lineasPcie <= 8 && c.pcie < g.pcieGen) {
      drv.push(item({ id: 'pcie', impacto: g.lineasPcie <= 4 ? 'alto' : 'bajo', estado: 'info', titulo: `Tu ${gpuN} usa ${g.lineasPcie} líneas PCIe y tu placa es PCIe ${c.pcie}.0`,
        texto: g.lineasPcie <= 4 ? 'Con solo 4 líneas en PCIe 3.0 la gráfica pierde bastante cuando se llena su memoria. Clave: texturas en Medio y nada de "Ultra".' : 'Pierdes un 2-5 % respecto a una placa más moderna. Para que no aumente, evita llenar la VRAM: texturas en Alto en vez de Ultra en los juegos más nuevos.' }));
    }
    if (g.soporteDriver === 'mantenimiento') drv.push(item({ id: 'drvmant', impacto: 'bajo', estado: 'info', titulo: 'Tu gráfica está en "modo mantenimiento" de AMD', texto: 'Sigue recibiendo arreglos importantes, pero no funciones nuevas ni optimizaciones para juegos recientes.' }));
    if (drv.length) secciones.push({ id: 'driver', titulo: g.appDriver ? `Panel de tu gráfica (${g.appDriver})` : 'Panel de tu gráfica', icono: 'gpu', items: drv });

    // ---- Windows
    const win = [];
    win.push(item({ id: 'modojuego', impacto: 'medio', estado: aj.ModoJuego === false ? 'hacer' : aj.ModoJuego === true ? 'ok' : 'hacer', titulo: 'Modo juego de Windows',
      texto: aj.ModoJuego === false ? 'Está desactivado: actívalo para que Windows dé prioridad al juego y no instale actualizaciones mientras juegas.' : 'Prioriza el juego y pausa tareas de Windows Update mientras juegas.', accion: { texto: 'Abrir ajuste', ajuste: 'modojuego' } }));
    if (!g.integrada || g.vendor === 'NVIDIA') win.push(item({ id: 'hags', impacto: 'medio', estado: aj.Hags === true ? 'ok' : aj.Hags === false ? 'hacer' : 'hacer', titulo: 'Programación de GPU acelerada por hardware',
      texto: aj.Hags === true ? 'Activada: la gráfica gestiona su propia memoria y reduce la latencia.' : 'La gráfica gestiona su propia memoria: menos latencia y es necesaria para la generación de fotogramas de NVIDIA. Reinicia tras activarla.',
      pasos: ['Configuración > Sistema > Pantalla > Gráficos > Cambiar la configuración de gráficos predeterminada > Programación de GPU acelerada por hardware.'], accion: { texto: 'Abrir ajuste', ajuste: 'graficos' } }));
    win.push(item({ id: 'grabacion', impacto: 'medio', estado: aj.GrabacionFondo === true ? 'hacer' : aj.GrabacionFondo === false ? 'ok' : 'hacer', titulo: 'Grabación en segundo plano de Xbox Game Bar',
      texto: aj.GrabacionFondo === true ? 'Está grabando continuamente los últimos minutos de juego: consume rendimiento. Desactívala si no la usas.' : 'Desactivada: no resta rendimiento.', accion: { texto: 'Abrir ajuste', ajuste: 'capturas' } }));
    if (aj.IntegridadMemoria === true) win.push(item({ id: 'hvci', impacto: 'bajo', estado: 'info', titulo: 'Integridad de memoria está activa',
      texto: 'Protege Windows contra ataques avanzados y puede costar un 0-5 % de FPS en algunos juegos. Te recomendamos dejarla activa: la seguridad vale más que ese pequeño margen.', accion: { texto: 'Ver ajuste', ajuste: 'integridad' } }));
    const plan = String(p.PlanEnergia || '');
    win.push(item({ id: 'energia', impacto: /econom|ahorro|saver/i.test(plan) ? 'alto' : 'bajo', estado: /econom|ahorro|saver/i.test(plan) ? 'hacer' : 'ok', titulo: 'Plan de energía',
      texto: /econom|ahorro|saver/i.test(plan) ? `Usas "${plan}": limita la velocidad del procesador. Cambia a Equilibrado o Alto rendimiento.` : `Usas "${plan || 'Equilibrado'}": correcto.${p.EsPortatil ? ' En portátiles, juega con el cargador y el modo rendimiento del fabricante.' : ''}`, accion: { texto: 'Opciones de energía', ajuste: 'energia' } }));
    if (hz) win.push(item({ id: 'hz', impacto: hz <= 60 ? 'medio' : 'bajo', estado: hz <= 60 ? 'hacer' : 'ok', titulo: `Tu pantalla funciona a ${hz} Hz`,
      texto: hz <= 60 ? 'Si tu monitor admite 75, 120 o 144 Hz, Windows a veces lo deja en 60. Revísalo: es fluidez gratis.' : `Bien. Procura que los FPS se mantengan cerca de ${hz} y limítalos justo por debajo (${limiteFps}).`, accion: { texto: 'Configuración de pantalla', ajuste: 'pantalla' } }));
    win.push(item({ id: 'fondo', impacto: 'bajo', estado: 'info', titulo: 'Cierra lo que no uses al jugar', texto: 'El navegador con muchas pestañas, los lanzadores y las superposiciones (Discord, Steam) consumen procesador y RAM. Con un procesador de 4 núcleos se nota.', accion: { texto: 'Programas de inicio', ajuste: 'inicio' } }));
    secciones.push({ id: 'windows', titulo: 'Windows', icono: 'windows', items: win });

    // ---- Hardware que ya tienes
    const hw = [];
    if (num(p.RamModulos) === 1) hw.push(item({ id: 'canal', impacto: 'alto', titulo: 'La RAM funciona en canal simple', texto: `Con un solo módulo pierdes ${p.SoloIntegrada ? '20-40 %' : '5-15 %'} de FPS. Un segundo módulo igual (no hace falta comprar más de 8 GB) lo soluciona.` }));
    if (p.RamBajoVelocidad) {
      const placaBH = /\b[BH][1-5]\d0/i.test(String(p.Placa || '')) && c.vendor === 'Intel' && c.generacion && c.generacion <= 10;
      hw.push(item({ id: 'xmp', impacto: 'medio', titulo: `Activa el perfil XMP de la RAM (ahora va a ${p.RamMHzActual} MHz)`,
        texto: `Tu RAM admite ${p.RamMHz} MHz, pero funciona a ${p.RamMHzActual}. Más velocidad de RAM = más FPS cuando el procesador limita.${placaBH && c.ramOficialMHz ? ` En tu placa (${p.Placa}), con este procesador, el máximo es ${c.ramOficialMHz} MHz.` : ''}`,
        pasos: ['Entra en la BIOS (Supr o F2 al encender).', 'Busca XMP / DOCP / EXPO y elige el Perfil 1.', 'Guarda y reinicia. Si da pantallazos azules, vuelve a desactivarlo.'] }));
    }
    const enHdd = juegos.filter(j => j.enHDD);
    if (enHdd.length) hw.push(item({ id: 'ssd', impacto: enHdd.some(j => (j.bajoMin || []).some(x => /SSD/.test(x))) ? 'alto' : 'medio', titulo: `Mueve ${enHdd.length === 1 ? enHdd[0].nombre : enHdd.length + ' juegos'} al SSD`,
      texto: `Instalados en disco mecánico: ${enHdd.map(j => j.nombre).join(', ')}. En un SSD cargan mucho antes y desaparecen los tirones al cargar texturas.`,
      pasos: ['Steam: clic derecho en el juego > Propiedades > Archivos instalados > Mover carpeta de instalación.', 'Epic y otros: desinstala y vuelve a instalar en el SSD.'] }));
    if (p.SistemaEnHDD) hw.push(item({ id: 'win-hdd', impacto: 'alto', estado: 'info', titulo: 'Windows está en un disco mecánico', texto: 'Es lo que más ralentiza el uso diario y las cargas. Un SSD de 480 GB es la mejora más barata con más efecto.' }));
    const tC = num(p.TempCpu, null), tG = num(p.TempGpu, null), tH = num(p.TempGpuHot, null);
    if ((tC && tC >= 85) || (tG && tG >= 83) || (tH && tH >= 95)) hw.push(item({ id: 'temps', impacto: 'alto', titulo: 'Baja las temperaturas para no perder rendimiento',
      texto: `Medimos ${[tC ? `procesador ${tC} °C` : '', tG ? `gráfica ${tG} °C` : '', tH ? `punto caliente ${tH} °C` : ''].filter(Boolean).join(', ')}. Cerca del límite, el hardware baja su velocidad. Mira los consejos en Temperaturas.`, accion: { texto: 'Ver Temperaturas', vista: 'temperaturas' } }));
    if (hw.length) secciones.push({ id: 'hardware', titulo: 'Tu hardware, sin gastar', icono: 'rayo', items: hw });

    // ---- Por juego
    const esc = g.dlss ? 'DLSS (Calidad)' : g.vendor === 'Intel' && !g.integrada ? 'XeSS (Calidad)' : 'FSR (Calidad)';
    const porJuego = juegos.filter(j => j.recGpu != null).map(j => {
      const pr = K.presetJuego(j, p);
      const consejos = [];
      if (pr.escalado) consejos.push(`Activa ${esc}.`);
      if (pr.cpuLimita) consejos.push('El procesador va justo: baja distancia de visión, multitudes, tráfico y física; deja las texturas y la iluminación altas.');
      if ((j.bajoRec || []).concat(j.bajoMin || []).includes('VRAM')) consejos.push('Texturas en Medio: tu gráfica tiene poca memoria para este juego.');
      if (j.enHDD) consejos.push('Muévelo al SSD.');
      const competitivo = /counter-?strike|\bcs2\b|valorant|fortnite|apex|overwatch|rainbow six|siege|league of legends|dota|marvel rivals|the finals|rocket league/i.test(j.nombre || '');
      if (competitivo) consejos.push(g.vendor === 'NVIDIA' && g.reflex ? 'Competitivo: activa NVIDIA Reflex y no uses generación de fotogramas.' : g.vendor === 'AMD' ? 'Competitivo: activa Radeon Anti-Lag y deja AFMF desactivado (añade latencia).' : 'Competitivo: prioriza FPS altos y estables sobre la calidad gráfica.');
      else if (pr.cpuLimita && g.afmf) consejos.push('Prueba AFMF: añade fotogramas sin cargar al procesador.');
      (j.notas || []).forEach(x => consejos.push(x));
      return { nombre: j.nombre, calidad: pr.calidad, nivel: pr.nivel, consejos, ratioGpu: pr.ratioGpu };
    });

    // ---- orden: primero lo pendiente y de más impacto
    const pesoEstado = { hacer: 0, info: 1, nd: 2, ok: 3 }, pesoImpacto = { alto: 0, medio: 1, bajo: 2 };
    secciones.forEach(sec => sec.items.sort((x, y) => (pesoEstado[x.estado] - pesoEstado[y.estado]) || (pesoImpacto[x.impacto] - pesoImpacto[y.impacto])));

    // ---- puntuación
    const todos = secciones.flatMap(s => s.items);
    const hechos = todos.filter(i => i.estado === 'ok').length, pend = todos.filter(i => i.estado === 'hacer').length;
    return { balance: bal, secciones, juegos: porJuego, puntuacion: hechos + pend ? Math.round(hechos / (hechos + pend) * 100) : 100, pendientes: pend, hechos,
      gpu: g, cpu: c, resumen: { gpu: gpuN, cpu: cpuN } };
  }

  // ---------------------------------------------------------------- refrigeración
  function refrigeracion(p, sesion, extra = {}) {
    p = p || {};
    const port = !!p.EsPortatil;
    const g = K.familiaGpu(p.Gpu);
    const cpuMax = Math.max(num(sesion && sesion.cpu && sesion.cpu.max), num(p.TempCpu));
    const cpuMin = sesion && sesion.cpu ? num(sesion.cpu.min, null) : null;
    const gpuMax = Math.max(num(sesion && sesion.gpu && sesion.gpu.max), num(p.TempGpu));
    const hotMax = Math.max(num(sesion && sesion.hot && sesion.hot.max), num(p.TempGpuHot));
    const anios = num(p.AniosEquipo);
    const cpuCaliente = cpuMax >= (port ? 90 : 85), gpuCaliente = gpuMax >= 83, hotAlto = hotMax >= 95 && gpuMax && hotMax - gpuMax >= 20;
    const reposoAlto = cpuMin != null && cpuMin >= (port ? 60 : 55);
    const L = [];
    const add = (o) => L.push(Object.assign({ relevante: false, motivo: '', pasos: [] }, o));
    add({ id: 'polvo', titulo: 'Limpia el polvo', relevante: cpuCaliente || gpuCaliente || reposoAlto,
      motivo: cpuCaliente || gpuCaliente ? 'Tus temperaturas máximas son altas.' : '', texto: 'El polvo tapa disipadores y filtros y es la causa número uno del calor. Hazlo cada 6 meses (en zonas con mucho polvo, cada 3).',
      pasos: ['Apaga y desenchufa el equipo.', 'Sopla con aire comprimido disipadores, ventiladores y filtros; sujeta las aspas para que no giren.', port ? 'En portátiles, sopla por las rejillas de salida.' : 'No olvides la fuente de alimentación y el disipador de la gráfica.'] });
    add({ id: 'pasta', titulo: 'Cambia la pasta térmica del procesador', relevante: reposoAlto || (cpuCaliente && anios >= 3),
      motivo: reposoAlto ? `En reposo ya está a ${cpuMin} °C: la pasta podría estar seca.` : anios >= 3 ? `El equipo tiene unos ${Math.round(anios)} años.` : '',
      texto: 'Con los años la pasta térmica se seca y transmite peor el calor. Cambiarla cuesta unos pocos dólares y puede bajar 5-15 °C.', pasos: ['Retira el disipador, limpia la pasta vieja con alcohol isopropílico.', 'Pon una gota del tamaño de un guisante en el centro y vuelve a montar el disipador apretando en cruz.'] });
    if (hotMax) add({ id: 'pasta-gpu', titulo: 'Revisa la pasta y los pads de la gráfica', relevante: hotAlto,
      motivo: hotAlto ? `Núcleo ${gpuMax} °C y punto caliente ${hotMax} °C: más de 20 °C de diferencia.` : '',
      texto: 'Una diferencia grande entre núcleo y punto caliente indica pasta mal repartida o seca en la GPU. Si la gráfica está en garantía, mejor consulta al fabricante.' });
    if (!port) add({ id: 'flujo', titulo: 'Ordena el flujo de aire de la caja', relevante: cpuCaliente || gpuCaliente,
      texto: 'El aire debe entrar frío por delante (o abajo) y salir caliente por detrás y por arriba. Con dos ventiladores bien orientados la diferencia es grande.',
      pasos: ['Ventiladores delanteros: metiendo aire. Trasero y superiores: sacándolo.', 'Recoge los cables para que no bloqueen el aire.', 'Deja al menos 10 cm entre la caja y la pared; no la metas en un mueble cerrado.'] });
    if (!port) add({ id: 'disipador', titulo: 'Un disipador de torre económico', relevante: cpuMax >= 88,
      motivo: cpuMax >= 88 ? `Tu procesador llega a ${cpuMax} °C.` : '', texto: 'Los disipadores que vienen con el procesador se quedan cortos jugando. Uno de torre de 20-30 US$ baja 10-20 °C y hace menos ruido. Comprueba el socket y la altura de tu caja.' });
    add({ id: 'curva', titulo: 'Ajusta la curva de los ventiladores', relevante: gpuCaliente,
      texto: 'Muchas gráficas priorizan el silencio y dejan subir la temperatura. Una curva algo más agresiva baja varios grados.',
      pasos: [g.vendor === 'AMD' ? 'AMD Software > Rendimiento > Ajuste > Ajuste del ventilador.' : g.vendor === 'NVIDIA' ? 'MSI Afterburner (gratuito) > Ventilador > curva personalizada.' : 'Utilidad del fabricante de la gráfica.', 'Ventiladores de la caja y del procesador: en la BIOS (Fan control / Q-Fan / Smart Fan).'] });
    add({ id: 'undervolt', titulo: 'Reduce un poco el voltaje (undervolt)', relevante: gpuCaliente || cpuCaliente,
      texto: 'Menos voltaje = menos calor con el mismo rendimiento. Es reversible y no daña nada; si aparecen cierres, sube de nuevo el voltaje.',
      pasos: [g.vendor === 'AMD' ? 'Gráfica AMD: AMD Software > Rendimiento > Ajuste > Ajuste de la GPU > voltaje: baja 25-50 mV y prueba.' : g.vendor === 'NVIDIA' ? 'Gráfica NVIDIA: curva de voltaje en MSI Afterburner (busca una guía para tu modelo).' : 'Gráfica: usa la utilidad del fabricante.',
        /ryzen/i.test(p.Cpu || '') ? 'Ryzen: en la BIOS, PBO > Curve Optimizer negativo (-10 a -20) o el modo Eco.' : 'Procesador Intel: en la BIOS se pueden reducir los límites de potencia (PL1/PL2) en modelos que lo permitan.'] });
    add({ id: 'fps', titulo: 'Limita los FPS', relevante: gpuCaliente,
      texto: 'Si el juego va a 150 FPS en un monitor de 60 Hz, la gráfica trabaja de más. Limitar los FPS al refresco del monitor baja temperatura, consumo y ruido.',
      pasos: [g.vendor === 'AMD' ? 'AMD Software > Radeon Chill o el limitador del juego.' : g.vendor === 'NVIDIA' ? 'NVIDIA App > Velocidad de fotogramas máxima.' : 'Usa el limitador de FPS del juego.'] });
    if (port) add({ id: 'portatil', titulo: 'Trucos para portátiles', relevante: cpuCaliente || gpuCaliente,
      texto: 'Los portátiles tienen poco espacio para disipar calor.', pasos: ['Úsalo sobre una mesa, nunca sobre la cama o las piernas.', 'Una base refrigerante o simplemente elevar la parte trasera 2-3 cm ayuda mucho.', 'Usa el modo de ventilación "rendimiento" del fabricante al jugar.'] });
    add({ id: 'ambiente', titulo: 'La temperatura de la habitación cuenta', relevante: false,
      texto: 'Si la habitación está a 32 °C, el PC estará unos grados más caliente que con 22 °C. Ventila la habitación o juega en las horas frescas.' });
    const orden = (a, b) => (b.relevante ? 1 : 0) - (a.relevante ? 1 : 0);
    return L.sort(orden);
  }

  const api = { recomendaciones, refrigeracion, estadoTemp, balance };
  raiz.Recomendaciones = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
