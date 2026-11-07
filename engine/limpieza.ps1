# Doctor PC — limpieza segura (v2).
#   -Modo analizar : mide cada categoría y explica qué es, qué pasa si se borra y qué NO se toca (no borra nada)
#   -Modo limpiar  : borra solo las categorías indicadas en -Elementos (separadas por comas)
#   -Modo accion   : ejecuta una acción informativa concreta (-Accion hibernacion_off)
# Nunca toca documentos, fotos, programas, contraseñas, historial, cookies, sesiones ni partidas guardadas.
# Solo borra dentro de carpetas de caché y temporales conocidas, sin seguir enlaces fuera de ellas.
# El resultado se escribe en -Salida (JSON) y cada borrado queda en -Registro.
param(
    [ValidateSet('analizar', 'limpiar', 'accion')][string]$Modo = 'analizar',
    [string]$Elementos = '',
    [string]$Accion = '',
    [string]$Salida = '',
    [string]$Registro = ''
)
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
. (Join-Path $PSScriptRoot 'archivos.ps1')

function Test-Admin {
    try { return (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { return $false }
}
function Write-Registro([string]$t) {
    if ($Registro) { try { Add-Content -LiteralPath $Registro -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $t) -Encoding UTF8 } catch { } }
}
function Guardar($obj) {
    $json = $obj | ConvertTo-Json -Depth 6
    if ($Salida) { [System.IO.File]::WriteAllText($Salida, $json, (New-Object System.Text.UTF8Encoding($false))) } else { $json }
}
function NuevaRuta([string]$ruta, [string]$etiqueta, [double]$minHoras = 0, [string]$patron = '*', [bool]$recursivo = $true, [bool]$vacias = $false) {
    return @{ Ruta = $ruta; Etiqueta = $etiqueta; MinHoras = $minHoras; Patron = $patron; Recursivo = $recursivo; Vacias = $vacias }
}

$L = $env:LOCALAPPDATA; $A = $env:APPDATA; $W = $env:SystemRoot
$LL = Join-Path (Split-Path $L -Parent) 'LocalLow'

# ---------------------------------------------------------------- rutas de cada categoría
function Get-RutasNavegador {
    $r = @()
    $bases = @(
        @{ B = (Join-Path $L 'Google\Chrome\User Data'); N = 'Chrome' },
        @{ B = (Join-Path $L 'Microsoft\Edge\User Data'); N = 'Edge' },
        @{ B = (Join-Path $L 'BraveSoftware\Brave-Browser\User Data'); N = 'Brave' },
        @{ B = (Join-Path $L 'Vivaldi\User Data'); N = 'Vivaldi' }
    )
    foreach ($b in $bases) {
        foreach ($perfil in @(Get-ChildItem -LiteralPath $b.B -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
            foreach ($sub in @('Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache')) {
                $p = Join-Path $perfil.FullName $sub
                if (Test-Path -LiteralPath $p) { $r += (NuevaRuta $p $b.N) }
            }
        }
        foreach ($sub in @('ShaderCache', 'GrShaderCache', 'GraphiteDawnCache')) {
            $p = Join-Path $b.B $sub
            if (Test-Path -LiteralPath $p) { $r += (NuevaRuta $p $b.N) }
        }
    }
    foreach ($o in @(@{ P = 'Opera Software\Opera Stable'; N = 'Opera' }, @{ P = 'Opera Software\Opera GX Stable'; N = 'Opera GX' })) {
        foreach ($sub in @('Cache', 'Code Cache', 'GPUCache')) {
            $p = Join-Path (Join-Path $L $o.P) $sub
            if (Test-Path -LiteralPath $p) { $r += (NuevaRuta $p $o.N) }
        }
    }
    foreach ($perfil in @(Get-ChildItem -LiteralPath (Join-Path $L 'Mozilla\Firefox\Profiles') -Directory -ErrorAction SilentlyContinue)) {
        foreach ($sub in @('cache2', 'startupCache', 'thumbnails')) {
            $p = Join-Path $perfil.FullName $sub
            if (Test-Path -LiteralPath $p) { $r += (NuevaRuta $p 'Firefox') }
        }
    }
    return @($r)
}

# Nombres bonitos de apps conocidas (carpeta -> nombre)
$nombresApp = @{ 'Code' = 'VS Code'; 'discord' = 'Discord'; 'Claude' = 'Claude'; 'Slack' = 'Slack'; 'Microsoft\Teams' = 'Teams (clásico)'; 'Notion' = 'Notion'; 'obsidian' = 'Obsidian'; 'Figma' = 'Figma'; 'Postman' = 'Postman'; 'WhatsApp' = 'WhatsApp'; 'Signal' = 'Signal'; 'GitHub Desktop' = 'GitHub Desktop'; 'Spotify' = 'Spotify'; 'Zoom' = 'Zoom'; 'Cursor' = 'Cursor'; 'Microsoft\Edge WebView' = 'WebView' }
$procesosApp = @{ 'VS Code' = 'Code'; 'Discord' = 'Discord'; 'Claude' = 'Claude'; 'Slack' = 'slack'; 'Teams (clásico)' = 'Teams'; 'Notion' = 'Notion'; 'Obsidian' = 'Obsidian'; 'Figma' = 'Figma'; 'Spotify' = 'Spotify'; 'Steam' = 'steam'; 'Epic Games' = 'EpicGamesLauncher'; 'Cursor' = 'Cursor'; 'Postman' = 'Postman'; 'Signal' = 'Signal'; 'GitHub Desktop' = 'GitHubDesktop'; 'Zoom' = 'Zoom' }

# Apps hechas con Electron/Chromium: tienen "Local Storage" o "Preferences" junto a sus carpetas de caché.
# Solo se borran esas carpetas de caché; nunca Local Storage, IndexedDB, Session Storage, Cookies ni la configuración.
function Get-RutasApps {
    $r = @()
    $cand = @()
    foreach ($base in @($A, $L)) {
        foreach ($d in @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue)) {
            $cand += $d
            if ($d.Name -in @('Microsoft')) {
                foreach ($s in @(Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('Teams') })) { $cand += $s }
            }
        }
    }
    $vistos = @{}
    foreach ($d in $cand) {
        if ($d.FullName -match '\\(Google|BraveSoftware|Vivaldi|Opera Software|Mozilla|DoctorPC|doctor-pc)(\\|$)') { continue }
        if (-not ((Test-Path -LiteralPath (Join-Path $d.FullName 'Local Storage')) -or (Test-Path -LiteralPath (Join-Path $d.FullName 'Preferences')))) { continue }
        $rel = $d.FullName.Substring((Split-Path $d.FullName -Parent).Length).TrimStart('\')
        if ($d.Parent -and $d.Parent.Name -eq 'Microsoft') { $rel = 'Microsoft\' + $d.Name }
        $nombre = if ($nombresApp.ContainsKey($rel)) { $nombresApp[$rel] } else { $d.Name }
        foreach ($sub in @('Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'GrShaderCache', 'ShaderCache', 'CachedData', 'CachedExtensionVSIXs', 'Crashpad\reports')) {
            $p = Join-Path $d.FullName $sub
            if ((Test-Path -LiteralPath $p) -and -not $vistos.ContainsKey($p)) { $vistos[$p] = 1; $r += (NuevaRuta $p $nombre) }
        }
    }
    # Otras apps con caché web propia (sin datos del usuario dentro)
    foreach ($x in @(
            @{ P = (Join-Path $L 'Spotify\Browser\Cache'); N = 'Spotify' },
            @{ P = (Join-Path $L 'Steam\htmlcache'); N = 'Steam' },
            @{ P = (Join-Path $L 'Microsoft\Windows\INetCache\IE'); N = 'Windows (caché web)' }
        )) { if (Test-Path -LiteralPath $x.P) { $r += (NuevaRuta $x.P $x.N) } }
    foreach ($wc in @(Get-ChildItem -LiteralPath (Join-Path $L 'EpicGamesLauncher\Saved') -Directory -Filter 'webcache*' -ErrorAction SilentlyContinue)) { $r += (NuevaRuta $wc.FullName 'Epic Games') }
    return @($r)
}

function Get-CarpetaDescargas {
    try {
        $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}'
        if ($v) { $v = [Environment]::ExpandEnvironmentVariables($v); if (Test-Path -LiteralPath $v) { return $v } }
    } catch { }
    return (Join-Path $env:USERPROFILE 'Downloads')
}

$categorias = @(
    @{ Id = 'temp_usuario'; Nombre = 'Archivos temporales de tu usuario'; Grupo = 'seguro'; Admin = $false; Pre = $true; Icono = 'carpeta'
        Que = 'Restos que dejan los instaladores y los programas en tu carpeta TEMP.'
        Efecto = 'Ninguno. Solo se borran los que tienen más de 24 horas, así no molesta a programas abiertos.'
        NoToca = 'Archivos de las últimas 24 horas y los que estén en uso.'
        Rutas = @((NuevaRuta $env:TEMP 'TEMP' 24 '*' $true $true)) },
    @{ Id = 'navegadores'; Nombre = 'Caché de navegadores'; Grupo = 'seguro'; Admin = $false; Pre = $true; Icono = 'red'
        Que = 'Copias de imágenes y páginas que guardan Chrome, Edge, Brave, Opera, Vivaldi y Firefox para cargar más rápido.'
        Efecto = 'Las páginas pueden tardar un poco más la primera vez mientras el navegador vuelve a guardarlas.'
        NoToca = 'Contraseñas, historial, marcadores, pestañas abiertas, cookies y sesiones iniciadas, extensiones, descargas y datos sin conexión de las webs.'
        Procesos = @{ 'Chrome' = 'chrome'; 'Edge' = 'msedge'; 'Brave' = 'brave'; 'Vivaldi' = 'vivaldi'; 'Opera' = 'opera'; 'Opera GX' = 'opera'; 'Firefox' = 'firefox' }
        Rutas = @(Get-RutasNavegador) },
    @{ Id = 'apps_cache'; Nombre = 'Caché de aplicaciones (Claude, Discord, VS Code…)'; Grupo = 'seguro'; Admin = $false; Pre = $true; Icono = 'capas'
        Que = 'Copias temporales de las apps hechas con tecnología web: Claude, Discord, Slack, Teams, VS Code, Notion, Steam, Epic y otras.'
        Efecto = 'La app puede tardar un par de segundos más en abrir la primera vez. No cierra tu sesión.'
        NoToca = 'Conversaciones, sesiones iniciadas, configuración, mensajes, archivos descargados ni datos guardados de cada app.'
        Procesos = $procesosApp
        Rutas = @(Get-RutasApps) },
    @{ Id = 'errores'; Nombre = 'Informes de errores'; Grupo = 'seguro'; Admin = $false; Pre = $true; Icono = 'informe'
        Que = 'Informes de fallos que Windows guarda para enviarlos a Microsoft.'
        Efecto = 'Ninguno. No hacen falta para que nada funcione.'
        NoToca = 'El historial de fiabilidad de Windows ni los registros del sistema.'
        Rutas = @((NuevaRuta (Join-Path $L 'CrashDumps') 'Volcados de programas'), (NuevaRuta (Join-Path $L 'Microsoft\Windows\WER\ReportArchive') 'Informes'), (NuevaRuta (Join-Path $L 'Microsoft\Windows\WER\ReportQueue') 'Informes'), (NuevaRuta (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive') 'Informes'), (NuevaRuta (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue') 'Informes')) },
    @{ Id = 'miniaturas'; Nombre = 'Caché de miniaturas'; Grupo = 'seguro'; Admin = $false; Pre = $true; Icono = 'paleta'
        Que = 'Vistas previas de fotos y vídeos que muestra el Explorador de archivos.'
        Efecto = 'Las miniaturas tardan un momento en aparecer la próxima vez que abras una carpeta con muchas fotos.'
        NoToca = 'Tus fotos y vídeos: solo se borran sus vistas previas.'
        Rutas = @((NuevaRuta (Join-Path $L 'Microsoft\Windows\Explorer') 'Explorador' 0 'thumbcache_*.db;iconcache_*.db' $false)) },
    @{ Id = 'temp_windows'; Nombre = 'Archivos temporales de Windows'; Grupo = 'seguro'; Admin = $true; Pre = $false; Icono = 'windows'
        Que = 'La carpeta Windows\Temp, donde dejan restos las actualizaciones y los servicios.'
        Efecto = 'Ninguno. Solo se borran los de más de 24 horas.'
        NoToca = 'Archivos recientes y los que estén en uso.'
        Rutas = @((NuevaRuta (Join-Path $W 'Temp') 'Windows\Temp' 24 '*' $true $true)) },
    @{ Id = 'windows_update'; Nombre = 'Descargas de Windows Update'; Grupo = 'seguro'; Admin = $true; Pre = $false; Icono = 'actualizar'
        Que = 'Paquetes que Windows Update descargó y ya instaló.'
        Efecto = 'Ninguno. Si Windows necesita algo otra vez, lo vuelve a descargar. Solo se borran los de más de 10 días.'
        NoToca = 'Las actualizaciones instaladas: no se desinstala nada.'
        Rutas = @((NuevaRuta (Join-Path $W 'SoftwareDistribution\Download') 'Windows Update' 240 '*' $true $true)) },
    @{ Id = 'entrega'; Nombre = 'Optimización de distribución'; Grupo = 'seguro'; Admin = $true; Pre = $false; Icono = 'red'
        Que = 'Copias de actualizaciones que Windows comparte con otros PCs de tu red o de internet.'
        Efecto = 'Ninguno. Windows las vuelve a crear si las necesita.'
        NoToca = 'Las actualizaciones instaladas.'
        Rutas = @((NuevaRuta (Join-Path $W 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache') 'Optimización de distribución')) },
    @{ Id = 'volcados_sistema'; Nombre = 'Volcados de pantallazos azules'; Grupo = 'seguro'; Admin = $true; Pre = $false; Icono = 'alerta'
        Que = 'Copias de la memoria que Windows guarda cuando hay un pantallazo azul o un fallo grave.'
        Efecto = 'Ninguno en el uso diario. Si un técnico está investigando un pantallazo azul, guárdalos antes.'
        NoToca = 'Nada más del sistema.'
        Rutas = @((NuevaRuta $W 'MEMORY.DMP' 0 'MEMORY.DMP' $false), (NuevaRuta (Join-Path $W 'Minidump') 'Minidump'), (NuevaRuta (Join-Path $W 'LiveKernelReports') 'LiveKernelReports')) },
    @{ Id = 'registros_windows'; Nombre = 'Registros antiguos de Windows'; Grupo = 'seguro'; Admin = $true; Pre = $false; Icono = 'informe'
        Que = 'Registros de instalación de Windows (CBS y DISM) de hace más de 30 días.'
        Efecto = 'Ninguno. Windows sigue escribiendo los nuevos.'
        NoToca = 'Los registros recientes.'
        Rutas = @((NuevaRuta (Join-Path $W 'Logs\CBS') 'CBS' 720 '*.log;*.cab'), (NuevaRuta (Join-Path $W 'Logs\DISM') 'DISM' 720 '*.log')) },
    @{ Id = 'shaders'; Nombre = 'Caché de sombreadores (juegos)'; Grupo = 'revisar'; Admin = $false; Pre = $false; Icono = 'mando'
        Que = 'Efectos gráficos ya preparados que guardan DirectX y los drivers de NVIDIA, AMD e Intel para que los juegos carguen rápido.'
        Efecto = 'Los juegos vuelven a prepararlos: la primera partida puede cargar más lento o dar tirones unos minutos. Conviene borrarlos después de actualizar el driver o si un juego da tirones raros.'
        NoToca = 'Partidas guardadas, configuración de los juegos y los drivers.'
        Rutas = @((NuevaRuta (Join-Path $L 'D3DSCache') 'DirectX'), (NuevaRuta (Join-Path $L 'NVIDIA\DXCache') 'NVIDIA'), (NuevaRuta (Join-Path $L 'NVIDIA\GLCache') 'NVIDIA'), (NuevaRuta (Join-Path $LL 'NVIDIA\PerDriverVersion\DXCache') 'NVIDIA'), (NuevaRuta (Join-Path $LL 'NVIDIA\PerDriverVersion\GLCache') 'NVIDIA'), (NuevaRuta (Join-Path $L 'AMD\DxCache') 'AMD'), (NuevaRuta (Join-Path $L 'AMD\DxcCache') 'AMD'), (NuevaRuta (Join-Path $L 'AMD\VkCache') 'AMD'), (NuevaRuta (Join-Path $L 'AMD\GLCache') 'AMD'), (NuevaRuta (Join-Path $LL 'Intel\ShaderCache') 'Intel')) },
    @{ Id = 'papelera'; Nombre = 'Papelera de reciclaje'; Grupo = 'revisar'; Admin = $false; Pre = $false; Icono = 'papelera'; Especial = 'papelera'
        Que = 'Los archivos que ya enviaste a la papelera.'
        Efecto = 'Se eliminan para siempre: ya no podrás recuperarlos. Revisa la papelera antes si no estás seguro.'
        NoToca = 'Nada fuera de la papelera.'
        Rutas = @() },
    @{ Id = 'descargas'; Nombre = 'Instaladores e imágenes ISO en Descargas'; Grupo = 'revisar'; Admin = $false; Pre = $false; Icono = 'descargar'; Especial = 'descargas'
        Que = 'Instaladores (.exe, .msi) e imágenes de disco (.iso) de más de 30 días en tu carpeta Descargas. Normalmente ya no hacen falta después de instalar.'
        Efecto = 'Tú eliges cuáles. Van a la papelera, así que puedes recuperarlos si te equivocas.'
        NoToca = 'Documentos, fotos, vídeos, comprimidos ni ningún otro archivo de Descargas.'
        Rutas = @() },
    @{ Id = 'windows_old'; Nombre = 'Instalación anterior de Windows (Windows.old)'; Grupo = 'info'; Admin = $true; Pre = $false; Icono = 'windows'; Especial = 'windows_old'
        Que = 'Copia del Windows que tenías antes de la última actualización grande. Sirve para volver atrás durante unos días.'
        Efecto = 'Después de borrarla ya no podrás volver a la versión anterior de Windows. Bórrala desde Configuración > Almacenamiento > Archivos temporales.'
        NoToca = 'Doctor PC no la borra: lo hace Windows de forma segura.'
        Rutas = @() },
    @{ Id = 'hibernacion'; Nombre = 'Archivo de hibernación (hiberfil.sys)'; Grupo = 'info'; Admin = $true; Pre = $false; Icono = 'rayo'; Especial = 'hibernacion'
        Que = 'Windows guarda aquí la memoria al hibernar y para el inicio rápido. Ocupa una parte de tu RAM en el disco C.'
        Efecto = 'Si desactivas la hibernación recuperas ese espacio, pero se pierden la hibernación y el inicio rápido (el PC tarda unos segundos más en encender). En portátiles no se recomienda.'
        NoToca = 'Se puede volver a activar en cualquier momento.'
        Rutas = @() }
)

$admin = Test-Admin

# ---------------------------------------------------------------- acción: desactivar hibernación
if ($Modo -eq 'accion') {
    $res = [ordered]@{ Modo = 'accion'; Accion = $Accion; Ok = $false; Mensaje = '' }
    if ($Accion -eq 'hibernacion_off') {
        if (-not $admin) { $res.Mensaje = 'Hace falta permiso de administrador.' }
        else {
            & powercfg.exe /hibernate off 2>&1 | Out-Null
            $res.Ok = ($LASTEXITCODE -eq 0)
            $res.Mensaje = if ($res.Ok) { 'Hibernación desactivada. Para volver a activarla: powercfg /hibernate on' } else { 'powercfg no pudo desactivar la hibernación.' }
            Write-Registro ("LIMPIEZA hibernación desactivada (powercfg /hibernate off): {0}" -f $res.Ok)
        }
    }
    else { $res.Mensaje = 'Acción desconocida.' }
    Guardar $res
    return
}

$sel = @("$Elementos" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$procesos = @{}
foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { $procesos[$p.ProcessName.ToLowerInvariant()] = 1 }
$resultado = [ordered]@{ Modo = $Modo; Admin = $admin; Fecha = (Get-Date).ToString('s'); Categorias = @(); Liberado = 0; Borrados = 0; Omitidos = 0 }

function Get-Papelera {
    $tam = 0.0; $n = 0
    try {
        $sh = New-Object -ComObject Shell.Application
        foreach ($i in @($sh.Namespace(10).Items())) { $tam += [double]$i.Size; $n++ }
    } catch { }
    return @{ Tamano = $tam; Archivos = $n }
}

foreach ($c in $categorias) {
    $id = $c.Id
    if ($Modo -eq 'limpiar' -and $sel -notcontains $id) { continue }
    if ($Modo -eq 'limpiar' -and $c.Grupo -eq 'info') { continue }
    $item = [ordered]@{ Id = $id; Nombre = $c.Nombre; Grupo = $c.Grupo; Admin = [bool]$c.Admin; Preseleccion = [bool]$c.Pre; Icono = $c.Icono
        Que = $c.Que; Efecto = $c.Efecto; NoToca = $c.NoToca
        Tamano = 0; Archivos = 0; Liberado = 0; Borrados = 0; Omitidos = 0; Parcial = $false; Detalle = @(); Abiertos = @(); Lista = @(); Accion = $null; Nota = $null }

    switch ($c.Especial) {
        'papelera' {
            $p = Get-Papelera
            $item.Tamano = $p.Tamano; $item.Archivos = $p.Archivos
            if ($Modo -eq 'limpiar' -and $p.Archivos -gt 0) {
                try { Clear-RecycleBin -Force -ErrorAction Stop; $item.Liberado = $p.Tamano; $item.Borrados = $p.Archivos }
                catch { $item.Omitidos = $p.Archivos }
            }
        }
        'descargas' {
            $dir = Get-CarpetaDescargas
            $limite = (Get-Date).AddDays(-30)
            $lista = @()
            foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue) + @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -Force -ErrorAction SilentlyContinue })) {
                if ($f.Extension -notin @('.exe', '.msi', '.msix', '.msixbundle', '.appx', '.appxbundle', '.iso')) { continue }
                if ($f.LastWriteTime -gt $limite) { continue }
                $lista += [ordered]@{ Ruta = $f.FullName; Nombre = $f.Name; Tamano = [double]$f.Length; Fecha = $f.LastWriteTime.ToString('yyyy-MM-dd'); Tipo = $(if ($f.Extension -eq '.iso') { 'Imagen ISO' } else { 'Instalador' }) }
            }
            $lista = @($lista | Sort-Object { $_.Tamano } -Descending | Select-Object -First 200)
            $item.Lista = $lista
            $item.Archivos = $lista.Count
            $item.Tamano = [double](($lista | ForEach-Object { $_.Tamano } | Measure-Object -Sum).Sum)
            $item.Nota = $dir
        }
        'windows_old' {
            $wo = Join-Path $env:SystemDrive 'Windows.old'
            if (Test-Path -LiteralPath $wo) {
                $m = [DoctorPcFs]::Medir($wo, 0, '*', $true)
                $item.Tamano = [double]$m.Bytes; $item.Archivos = $m.Archivos
                $item.Parcial = ($m.Omitidos -gt 0)
                $item.Accion = 'storagesense'
            }
        }
        'hibernacion' {
            $h = Get-Item -LiteralPath (Join-Path $env:SystemDrive 'hiberfil.sys') -Force -ErrorAction SilentlyContinue
            if ($h) {
                $item.Tamano = [double]$h.Length; $item.Archivos = 1
                $bat = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue).Count -gt 0
                if (-not $bat -and $h.Length -gt 1GB) { $item.Accion = 'hibernacion_off' }
                if ($bat) { $item.Nota = 'Es un portátil: mejor no desactivar la hibernación.' }
            }
        }
        default {
            if ($c.Admin -and -not $admin) { $item.Parcial = $true }
            $det = [ordered]@{}
            foreach ($r in @($c.Rutas)) {
                if (-not $r.Ruta -or -not (Test-Path -LiteralPath $r.Ruta)) { continue }
                if ($Modo -eq 'limpiar') {
                    if ($id -eq 'entrega' -and (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue)) {
                        $antes = [DoctorPcFs]::Medir($r.Ruta, 0, '*', $true)
                        try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop } catch { }
                        $despues = [DoctorPcFs]::Medir($r.Ruta, 0, '*', $true)
                        $x = New-Object DoctorPcFs+Resultado
                        $x.Bytes = $antes.Bytes; $x.Archivos = $antes.Archivos
                        $x.Liberado = [Math]::Max(0, $antes.Bytes - $despues.Bytes); $x.Borrados = [Math]::Max(0, $antes.Archivos - $despues.Archivos); $x.Omitidos = $despues.Archivos
                    }
                    else { $x = [DoctorPcFs]::Borrar($r.Ruta, $r.MinHoras, $r.Patron, $r.Recursivo, $r.Vacias) }
                    $item.Liberado += $x.Liberado; $item.Borrados += $x.Borrados; $item.Omitidos += $x.Omitidos
                }
                else { $x = [DoctorPcFs]::Medir($r.Ruta, $r.MinHoras, $r.Patron, $r.Recursivo) }
                $item.Tamano += [double]$x.Bytes; $item.Archivos += $x.Archivos
                if (-not $det.Contains($r.Etiqueta)) { $det[$r.Etiqueta] = @{ Tamano = 0.0; Archivos = 0 } }
                $det[$r.Etiqueta].Tamano += [double]$x.Bytes; $det[$r.Etiqueta].Archivos += $x.Archivos
            }
            $item.Detalle = @($det.Keys | ForEach-Object { [ordered]@{ Etiqueta = $_; Tamano = $det[$_].Tamano; Archivos = $det[$_].Archivos } } | Where-Object { $_.Tamano -gt 0 } | Sort-Object { $_.Tamano } -Descending)
            if ($c.Procesos) {
                $item.Abiertos = @($c.Procesos.Keys | Where-Object { $k = $_; $procesos.ContainsKey($c.Procesos[$k].ToLowerInvariant()) -and @($item.Detalle | Where-Object { $_.Etiqueta -eq $k }).Count -gt 0 } | Sort-Object -Unique)
            }
        }
    }
    if ($Modo -eq 'limpiar') {
        Write-Registro ("LIMPIEZA {0}: {1} archivos borrados, {2:N1} MB liberados, {3} en uso u omitidos" -f $c.Nombre, $item.Borrados, ($item.Liberado / 1MB), $item.Omitidos)
        $resultado.Liberado += $item.Liberado; $resultado.Borrados += $item.Borrados; $resultado.Omitidos += $item.Omitidos
    }
    $resultado.Categorias += $item
}

Guardar $resultado
