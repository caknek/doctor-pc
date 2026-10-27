# Doctor PC

**Descubre qué le pasa a tu PC y cuál es la mejora más barata.**

Doctor PC es una app gratuita para Windows 10/11 que analiza el equipo como lo haría un técnico. Revisa el hardware, los discos, los juegos instalados y los errores de Windows. Después explica qué falla en lenguaje normal y propone soluciones ordenadas por coste, ajustadas a tu país y presupuesto.

## Descargar

Ve a **[Releases](https://github.com/caknek/doctor-pc/releases/latest)** y descarga `DoctorPC-Instalador.exe`. La app se actualiza sola desde ahí: *Acerca de → Buscar actualizaciones*.

`DoctorPC-Consola.zip` es la versión sin instalación (PowerShell). Sirve también en Windows de 32 bits.

> Windows puede avisar "Windows protegió su PC" porque el instalador aún no está firmado digitalmente: *Más información → Ejecutar de todas formas*.

## Qué hace

- **Hardware:** CPU, GPU (VRAM real), RAM (ranuras libres, canal simple/doble, XMP), placa y BIOS.
- **Discos:** HDD / SSD / NVMe, salud, temperatura, desgaste, espacio libre, actividad y latencia.
- **Juegos:** Steam, Epic, GOG, Ubisoft, EA, Riot, Xbox, Minecraft, Roblox y tus carpetas. Muestra en qué disco está cada uno y si el PC cumple los requisitos.
- **Modo juego:** mide mientras juegas y distingue si el límite es la GPU, la CPU, el disco, la RAM o el calor.
- **Windows:** pantallazos azules (con su significado), apagados inesperados, errores de hardware, drivers con fallos, programas de inicio.
- **Plan de mejora:** primero lo gratis, después las compras que más rinden por dólar. Antes de sugerir una pieza revisa la compatibilidad: socket, tipo de RAM, portátil, fuente.
- **Reparaciones guiadas:** herramientas oficiales de Windows (DISM + SFC, chkdsk, diagnóstico de memoria…), una por una y con confirmación.
- **Para técnicos:** abre el `.json` de un cliente y recalcula el plan con otro país o presupuesto.

Todo se analiza en el propio PC; ningún dato sale del equipo.

## Estructura

```
main.js, preload.js      Proceso principal de Electron (motor, informes, actualizaciones)
renderer/                Interfaz (HTML/CSS/JS)
engine/DoctorPC.ps1      Motor de diagnóstico (PowerShell 5.1+, también funciona solo)
engine/datos/            Catálogos editables: precios, requisitos de juegos, índices de hardware
tests/                   Pruebas del motor y de la app + equipos de ejemplo
.github/workflows/       Pruebas en cada push y publicación automática de versiones
build/                   Icono y notas de la versión (se muestran en la app al actualizar)
```

## Desarrollo

```bash
npm install
npm start                         # abre la app (Windows)
npm test                          # comprobaciones de la app
pwsh tests/Test-Motor.ps1         # pruebas del motor (en Windows incluye un análisis real)
```

Motor sin la app:

```powershell
.\engine\DoctorPC.ps1                                   # modo consola interactivo
.\engine\DoctorPC.ps1 -DesdeJson cliente.json -Pais Chile -Presupuesto 100
```

## Publicar una versión

1. Escribe las novedades en `build/release-notes.md`.
2. Crea y sube la etiqueta:
   ```bash
   git tag v0.3.0 && git push origin v0.3.0
   ```
3. GitHub Actions pone esa versión en la app y en el motor, ejecuta las pruebas en Windows, compila `DoctorPC-Instalador.exe` y lo publica en Releases junto con `latest.yml`. Las apps instaladas lo detectan y ofrecen actualizar.
