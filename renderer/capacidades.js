// Doctor PC — "Qué puedes hacer con tu PC": capacidades según el hardware real del equipo.
(function (raiz) {
  'use strict';
  const K = raiz.Conocimiento || (typeof require !== 'undefined' ? require('./conocimiento.js') : null);
  const num = K.num;

  function capacidades(p, extra = {}) {
    if (!p) return [];
    const gi = num(p.GpuIndice), ci = num(p.CpuIndice), ram = num(p.RamGB), vram = p.GpuIntegrada ? 0 : num(p.VramGB), hilos = num(p.Hilos, 4);
    const g = K.familiaGpu(p.Gpu), c = K.familiaCpu(p.Cpu, p.CpuPlataforma);
    const gpuCorta = String(p.Gpu || 'tu gráfica').replace(/\((R|TM)\)/gi, '').replace(/^(NVIDIA|AMD|Intel)\s+/i, '').replace(/GeForce\s+/i, '').trim();
    const cpuCorta = c.nombre.replace(/^(Intel|AMD)\s+/i, '').replace(/\s*(Six|Eight|Quad|Twelve|Sixteen)-Core Processor/i, '').replace(/ with Radeon.*$/i, '');
    const encoder = g.codificador || (c.quickSync ? 'Quick Sync' : '');
    const lista = [];
    const add = (o) => lista.push(o);

    // ---------------- Juegos
    let aaa, nivelAaa;
    if (gi >= 330) { aaa = 'Juegos actuales en 4K con calidad alta, y 1440p a muchos FPS.'; nivelAaa = 'excelente'; }
    else if (gi >= 220) { aaa = '1440p en calidad alta y 1080p en ultra a más de 100 FPS en la mayoría de juegos.'; nivelAaa = 'excelente'; }
    else if (gi >= 140) { aaa = '1080p en calidad alta a 60 FPS o más en casi todos los juegos actuales; 1440p en medio.'; nivelAaa = 'bien'; }
    else if (gi >= 95) { aaa = '1080p en calidad media a 60 FPS; los más exigentes, en bajo con escalado.'; nivelAaa = 'bien'; }
    else if (gi >= 60) { aaa = '1080p en bajo o 900p con escalado; juegos de hace unos años, en medio.'; nivelAaa = 'limitado'; }
    else if (gi >= 25) { aaa = 'Juegos ligeros, indies y clásicos; los actuales solo en 720p y calidad mínima.'; nivelAaa = 'limitado'; }
    else { aaa = 'Indies, juegos 2D y retro. Los juegos 3D actuales no van fluidos.'; nivelAaa = 'no'; }
    if (ci && ci < 70 && gi >= 95) aaa += ` El procesador (${cpuCorta}) puede frenar a la gráfica en mundos abiertos.`;
    const escal = g.escaladores.filter(x => !/XeSS/.test(x) || g.vendor === 'Intel').slice(0, 2).join(' o ');
    add({ id: 'aaa', cat: 'Juegos', icono: 'juego', titulo: 'Juegos de última generación', nivel: nivelAaa, texto: aaa,
      extra: escal ? `Activa ${escal} en los juegos para ganar FPS.` + (g.afmf ? ' Tu Radeon puede generar fotogramas extra desde el driver (AFMF).' : '') : '', apps: [] });

    let esp, nivelEsp;
    if (ci >= 120 && gi >= 90) { esp = 'Valorant, CS2, Fortnite o LoL a más de 200 FPS: ideal para monitores de 144-240 Hz.'; nivelEsp = 'excelente'; }
    else if (ci >= 80 && gi >= 60) { esp = 'Valorant, CS2, Fortnite o LoL a 144 FPS o más con ajustes competitivos.'; nivelEsp = 'excelente'; }
    else if (ci >= 55 && gi >= 30) { esp = 'Juegos competitivos entre 60 y 120 FPS con ajustes bajos.'; nivelEsp = 'bien'; }
    else { esp = 'Juegos competitivos a unos 60 FPS en mínimo; LoL y Valorant son los más ligeros.'; nivelEsp = 'limitado'; }
    add({ id: 'esports', cat: 'Juegos', icono: 'rayo', titulo: 'Juegos competitivos a muchos FPS', nivel: nivelEsp, texto: esp, apps: [] });

    if (gi >= 95 && ci >= 70 && ram >= 8) add({ id: 'vr', cat: 'Juegos', icono: 'monitor', titulo: 'Realidad virtual', nivel: gi >= 150 ? 'excelente' : 'bien',
      texto: `Tu ${gpuCorta} cumple los requisitos de los visores de PC (Meta Quest con Link o Air Link, Valve Index, etc.).`, extra: gi < 150 ? 'En juegos VR exigentes, baja la resolución de renderizado.' : '', apps: ['SteamVR', 'Meta Quest Link'] });
    else add({ id: 'vr', cat: 'Juegos', icono: 'monitor', titulo: 'Realidad virtual', nivel: 'no', texto: 'Para realidad virtual hace falta una gráfica dedicada de gama media (GTX 1060 / RX 580 o superior).', apps: [] });

    add({ id: 'emu', cat: 'Juegos', icono: 'juego', titulo: 'Emular consolas clásicas', nivel: ci >= 70 && gi >= 30 ? 'excelente' : ci >= 45 ? 'bien' : 'limitado',
      texto: ci >= 70 && gi >= 30 ? 'Desde NES y PS1 hasta PS2, GameCube y Wii en alta resolución (2x-3x).' : ci >= 45 ? 'Consolas hasta PS1 perfectas; PS2 y GameCube a resolución nativa.' : 'Consolas retro (NES, SNES, Mega Drive, PS1) sin problema.',
      extra: hilos >= 12 && ci >= 140 ? 'Incluso PS3 (RPCS3) en muchos juegos.' : hilos >= 8 && ci >= 85 ? 'PS3 (RPCS3) solo en algunos juegos ligeros.' : '', apps: ['RetroArch', 'PCSX2', 'Dolphin', 'DuckStation'], nota: 'Usa copias de juegos que tengas.' });

    if (nivelAaa === 'limitado' || nivelAaa === 'no') add({ id: 'nube', cat: 'Juegos', icono: 'red', titulo: 'Juegos AAA en la nube', nivel: 'bien',
      texto: 'Con una conexión de 25 Mbps o más puedes jugar títulos exigentes en streaming: el juego se ejecuta en un servidor.', apps: ['GeForce NOW', 'Xbox Cloud Gaming'] });

    // ---------------- Crear contenido
    add({ id: 'stream', cat: 'Crear', icono: 'chat', titulo: 'Hacer streaming y grabar partidas', nivel: encoder && ci >= 60 ? 'excelente' : encoder ? 'bien' : ci >= 100 ? 'bien' : 'limitado',
      texto: encoder ? `Tu equipo tiene codificador por hardware (${encoder}${g.av1Codifica ? ', con AV1' : ''}): transmites a 1080p60 sin restar FPS al juego.` : 'No hay codificador por hardware: se codifica con el procesador y resta rendimiento al juego.',
      apps: ['OBS Studio', g.vendor === 'AMD' ? 'AMD Software (ReLive)' : g.vendor === 'NVIDIA' ? 'NVIDIA App' : ''].filter(Boolean) });

    const ed4k = ram >= 16 && ci >= 100;
    add({ id: 'video', cat: 'Crear', icono: 'informe', titulo: 'Editar vídeo', nivel: ed4k ? 'excelente' : ram >= 8 && ci >= 55 ? 'bien' : 'limitado',
      texto: ed4k ? 'Edición en 1080p fluida y 4K con buen rendimiento.' : ram >= 16 && ci >= 75 ? 'Edición en 1080p fluida; para 4K usa archivos proxy (versiones ligeras del vídeo).' : ram >= 8 ? 'Edición en 1080p de proyectos sencillos.' : 'Solo proyectos cortos y sencillos: falta RAM.',
      extra: !vram || vram < 4 ? 'DaVinci Resolve pide una gráfica con al menos 4 GB de memoria: mejor usa Shotcut o CapCut.' : '', apps: vram >= 4 ? ['DaVinci Resolve', 'Shotcut', 'CapCut'] : ['Shotcut', 'CapCut', 'Clipchamp'] });

    add({ id: '3d', cat: 'Crear', icono: 'paleta', titulo: 'Modelado y animación 3D', nivel: gi >= 200 && vram >= 8 ? 'excelente' : gi >= 95 && vram >= 4 ? 'bien' : 'limitado',
      texto: gi >= 95 && vram >= 4 ? `Blender acelera el renderizado con tu ${gpuCorta}${g.vendor === 'NVIDIA' && g.rt ? ' (OptiX)' : g.vendor === 'AMD' && g.serie >= 5000 ? ' (HIP)' : g.vendor === 'Intel' && !g.integrada ? ' (oneAPI)' : ''}.` : 'Modelado y escenas sencillas; el renderizado final será lento.',
      apps: ['Blender'] });

    add({ id: 'musica', cat: 'Crear', icono: 'campana', titulo: 'Producir música', nivel: ci >= 80 && ram >= 16 ? 'excelente' : ci >= 50 && ram >= 8 ? 'bien' : 'limitado',
      texto: ci >= 80 && ram >= 16 ? 'Proyectos con muchas pistas, instrumentos virtuales y efectos.' : 'Grabación y mezcla de proyectos medianos.', apps: ['Reaper', 'Cakewalk by BandLab', 'LMMS'] });

    add({ id: 'foto', cat: 'Crear', icono: 'paleta', titulo: 'Diseño gráfico y fotografía', nivel: ram >= 16 ? 'excelente' : ram >= 8 ? 'bien' : 'limitado',
      texto: ram >= 16 ? 'Fotos RAW, diseños grandes y muchas capas.' : 'Edición de fotos y diseños medianos.', apps: ['GIMP', 'Krita', 'Photopea (web)', 'Canva'] });

    // ---------------- Inteligencia artificial local
    let ia, nivelIa;
    if (vram >= 16) { ia = `Modelos de 14B parámetros a buena velocidad con los ${vram} GB de tu gráfica.`; nivelIa = 'excelente'; }
    else if (vram >= 12) { ia = `Modelos de hasta 12-14B parámetros con los ${vram} GB de tu gráfica.`; nivelIa = 'excelente'; }
    else if (vram >= 8) { ia = `Modelos de 7-8B parámetros (Llama 3.1 8B, Qwen, Gemma) respondiendo rápido con los ${vram} GB de tu gráfica.`; nivelIa = 'bien'; }
    else if (vram >= 6) { ia = 'Modelos pequeños (3-7B parámetros) con la memoria de tu gráfica.'; nivelIa = 'bien'; }
    else if (ram >= 16) { ia = 'Modelos pequeños (1-4B parámetros) en el procesador: funcionan, pero lentos.'; nivelIa = 'limitado'; }
    else { ia = 'Hace falta más memoria (16 GB de RAM o una gráfica con 6 GB o más).'; nivelIa = 'no'; }
    add({ id: 'ia-chat', cat: 'IA', icono: 'chat', titulo: 'Tu propio ChatGPT, sin internet', nivel: nivelIa, texto: ia,
      extra: g.vendor === 'AMD' && vram >= 6 ? 'LM Studio usa tu Radeon mediante Vulkan.' : '', apps: nivelIa === 'no' ? [] : ['LM Studio', 'Ollama', 'Jan'], nota: 'Tus conversaciones se quedan en tu PC.' });

    let img, nivelImg, appsImg = [];
    if (g.vendor === 'NVIDIA' && g.rt && vram >= 8) { img = 'Generar imágenes con Stable Diffusion / Flux en segundos.'; nivelImg = 'excelente'; appsImg = ['ComfyUI', 'Fooocus']; }
    else if (g.vendor === 'NVIDIA' && vram >= 6) { img = 'Generar imágenes con Stable Diffusion a resolución media.'; nivelImg = 'bien'; appsImg = ['ComfyUI', 'Fooocus']; }
    else if (g.vendor === 'AMD' && g.serie >= 6000 && vram >= 8) { img = 'Generar imágenes con Stable Diffusion usando la app gratuita de AMD.'; nivelImg = 'bien'; appsImg = ['Amuse (de AMD)']; }
    else if (g.vendor === 'Intel' && !g.integrada && vram >= 8) { img = 'Generar imágenes con la app gratuita de Intel.'; nivelImg = 'bien'; appsImg = ['AI Playground (de Intel)']; }
    else { img = 'Tu gráfica no tiene memoria suficiente: usa generadores en la web.'; nivelImg = 'limitado'; appsImg = ['Bing Image Creator', 'Ideogram'] ; }
    add({ id: 'ia-img', cat: 'IA', icono: 'paleta', titulo: 'Crear imágenes con IA', nivel: nivelImg, texto: img, apps: appsImg });

    add({ id: 'ia-voz', cat: 'IA', icono: 'chat', titulo: 'Transcribir audio y vídeos', nivel: vram >= 4 || ci >= 80 ? 'excelente' : 'bien',
      texto: 'Convierte grabaciones, clases o reuniones en texto con Whisper, sin subirlas a internet.', apps: ['Subtitle Edit (Whisper)', 'Buzz'] });

    // ---------------- Productividad y hogar
    add({ id: 'oficina', cat: 'Productividad', icono: 'informe', titulo: 'Estudio, oficina y multitarea', nivel: p.SistemaEnHDD ? 'bien' : ram >= 8 ? 'excelente' : 'bien',
      texto: p.SistemaEnHDD ? 'Funciona, pero Windows en un disco mecánico hace que todo tarde: con un SSD iría mucho más rápido.' : `Muchas pestañas, videollamadas y documentos a la vez${ram >= 16 ? ' sin despeinarse' : ''}.`, apps: ['LibreOffice', 'Microsoft 365', 'Notion'] });

    add({ id: 'dev', cat: 'Productividad', icono: 'cpu', titulo: 'Programar y usar máquinas virtuales', nivel: ram >= 32 && hilos >= 12 ? 'excelente' : ram >= 16 && hilos >= 8 ? 'bien' : 'limitado',
      texto: ram >= 16 && hilos >= 8 ? 'Desarrollo web y de apps, Docker, WSL (Linux dentro de Windows) y 1-2 máquinas virtuales a la vez.' : 'Programación y desarrollo web; las máquinas virtuales irán justas de memoria.',
      apps: ['VS Code', 'WSL', 'VirtualBox', 'Docker Desktop'] });

    add({ id: 'video4k', cat: 'Entretenimiento', icono: 'monitor', titulo: 'Películas y vídeo en 4K', nivel: g.av1Decodifica ? 'excelente' : 'bien',
      texto: g.av1Decodifica ? 'YouTube 4K (AV1) y streaming en alta calidad decodificados por la gráfica, sin cargar el procesador.' : 'Vídeo 1080p perfecto; en 4K, YouTube puede cargar más el procesador.', apps: ['VLC', 'Kodi'] });

    add({ id: 'servidor', cat: 'Entretenimiento', icono: 'disco', titulo: 'Tu propio Netflix en casa', nivel: encoder ? 'excelente' : 'bien',
      texto: `Organiza tus películas y series y míralas en el móvil o la TV de casa.${encoder ? ` Tu ${encoder} adapta los vídeos sobre la marcha.` : ''}`, apps: ['Jellyfin', 'Plex'] });

    add({ id: 'monitores', cat: 'Productividad', icono: 'monitor', titulo: 'Varios monitores', nivel: p.SoloIntegrada ? 'bien' : 'excelente',
      texto: p.SoloIntegrada ? 'Normalmente 2 o 3 pantallas a la vez con los gráficos integrados.' : `Hasta 3-4 pantallas con tu ${gpuCorta}, según sus salidas de vídeo.`, apps: [] });

    const orden = { excelente: 0, bien: 1, limitado: 2, no: 3 };
    return lista.map(x => Object.assign({ extra: '', nota: '' }, x)).sort((a, b) => orden[a.nivel] - orden[b.nivel]);
  }

  // Puntuación de versatilidad 0-100 para el encabezado
  function versatilidad(lista) {
    if (!lista.length) return 0;
    const pts = { excelente: 100, bien: 72, limitado: 38, no: 0 };
    return Math.round(lista.reduce((a, x) => a + pts[x.nivel], 0) / lista.length);
  }

  const api = { capacidades, versatilidad };
  raiz.Capacidades = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
