# Doctor PC — limpieza segura.
#   -Modo analizar : mide cuánto espacio se puede liberar en cada categoría (no borra nada)
#   -Modo limpiar  : borra solo las categorías indicadas en -Elementos (separadas por comas)
# Nunca toca documentos, programas, contraseñas, historial ni sesiones.
# El resultado se escribe en -Salida (JSON) y cada borrado queda en -Registro.
param(
    [ValidateSet('analizar', 'limpiar')][string]$Modo = 'analizar',
    [string]$Elementos = '',
    [string]$Salida = '',
    [string]$Registro = ''
)
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$limite = (Get-Date).AddDays(-1)

function Test-Admin {
    try { return (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { return $false }
}
function Write-Registro([string]$t) {
    if ($Registro) { try { Add-Content -LiteralPath $Registro -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $t) -Encoding UTF8 } catch { } }
}

function Get-RutasNavegador {
    $r = @()
    $bases = @(
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'),
        (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data'),
        (Join-Path $env:LOCALAPPDATA 'Vivaldi\User Data')
    )
    foreach ($b in $bases) {
        foreach ($perfil in @(Get-ChildItem -LiteralPath $b -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
            foreach ($sub in @('Cache', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage')) {
                $p = Join-Path $perfil.FullName $sub
                if (Test-Path -LiteralPath $p) { $r += $p }
            }
        }
    }
    foreach ($p in @((Join-Path $env:LOCALAPPDATA 'Opera Software\Opera Stable\Cache'), (Join-Path $env:LOCALAPPDATA 'Opera Software\Opera GX Stable\Cache'))) {
        if (Test-Path -LiteralPath $p) { $r += $p }
    }
    foreach ($perfil in @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Mozilla\Firefox\Profiles') -Directory -ErrorAction SilentlyContinue)) {
        $p = Join-Path $perfil.FullName 'cache2'
        if (Test-Path -LiteralPath $p) { $r += $p }
    }
    return @($r)
}

$categorias = [ordered]@{
    temp_usuario = @{ Nombre = 'Archivos temporales de tu usuario'; Admin = $false; Antiguedad = $true; Patron = '*'
        Desc = 'Restos de instalaciones y programas en la carpeta TEMP. Solo se borran los que tienen más de 24 horas.'
        Rutas = @($env:TEMP) }
    temp_windows = @{ Nombre = 'Archivos temporales de Windows'; Admin = $true; Antiguedad = $true; Patron = '*'
        Desc = 'Carpeta Windows\Temp. Solo archivos con más de 24 horas. Necesita permisos de administrador.'
        Rutas = @((Join-Path $env:SystemRoot 'Temp')) }
    navegadores = @{ Nombre = 'Caché de navegadores'; Admin = $false; Antiguedad = $false; Patron = '*'
        Desc = 'Copias de páginas que guardan Chrome, Edge, Brave, Opera, Vivaldi y Firefox. No borra contraseñas, historial ni sesiones. Cierra los navegadores para liberar más.'
        Rutas = @(Get-RutasNavegador) }
    errores = @{ Nombre = 'Informes de errores y volcados'; Admin = $false; Antiguedad = $false; Patron = '*'
        Desc = 'Informes de fallos que Windows guarda para enviarlos a Microsoft. No son necesarios para que nada funcione.'
        Rutas = @((Join-Path $env:LOCALAPPDATA 'CrashDumps'), (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportArchive'), (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportQueue'), (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'), (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue')) }
    miniaturas = @{ Nombre = 'Caché de miniaturas'; Admin = $false; Antiguedad = $false; Patron = 'thumbcache_*.db'; Plano = $true
        Desc = 'Vistas previas de imágenes y vídeos del Explorador. Windows las vuelve a crear cuando hacen falta.'
        Rutas = @((Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer')) }
    papelera = @{ Nombre = 'Papelera de reciclaje'; Admin = $false; Especial = 'papelera'
        Desc = 'Los archivos que están en la papelera se eliminan para siempre.'
        Rutas = @() }
}

function Get-Archivos($c) {
    foreach ($ruta in @($c.Rutas)) {
        if (-not $ruta -or -not (Test-Path -LiteralPath $ruta)) { continue }
        if ($c.Plano) { $fs = Get-ChildItem -LiteralPath $ruta -Filter $c.Patron -File -Force -ErrorAction SilentlyContinue }
        else { $fs = Get-ChildItem -LiteralPath $ruta -Recurse -File -Force -ErrorAction SilentlyContinue }
        foreach ($f in $fs) {
            if ($c.Antiguedad -and $f.LastWriteTime -gt $limite) { continue }
            $f
        }
    }
}

function Get-Papelera {
    $tam = 0.0; $n = 0
    try {
        $sh = New-Object -ComObject Shell.Application
        foreach ($i in @($sh.Namespace(10).Items())) { $tam += [double]$i.Size; $n++ }
    } catch { }
    return @{ Tamano = $tam; Archivos = $n }
}

$admin = Test-Admin
$sel = @("$Elementos" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$resultado = [ordered]@{ Modo = $Modo; Admin = $admin; Fecha = (Get-Date).ToString('s'); Categorias = @(); Liberado = 0; Borrados = 0; Omitidos = 0 }

foreach ($id in $categorias.Keys) {
    $c = $categorias[$id]
    if ($Modo -eq 'limpiar' -and $sel -notcontains $id) { continue }
    $item = [ordered]@{ Id = $id; Nombre = $c.Nombre; Desc = $c.Desc; Admin = [bool]$c.Admin; Tamano = 0; Archivos = 0; Liberado = 0; Borrados = 0; Omitidos = 0; Parcial = $false }

    if ($c.Especial -eq 'papelera') {
        $p = Get-Papelera
        $item.Tamano = $p.Tamano; $item.Archivos = $p.Archivos
        if ($Modo -eq 'limpiar' -and $p.Archivos -gt 0) {
            try {
                Clear-RecycleBin -Force -ErrorAction Stop
                $item.Liberado = $p.Tamano; $item.Borrados = $p.Archivos
            } catch { $item.Omitidos = $p.Archivos }
        }
    }
    else {
        if ($c.Admin -and -not $admin) { $item.Parcial = $true }
        $archivos = @(Get-Archivos $c)
        $item.Archivos = $archivos.Count
        $item.Tamano = [double](($archivos | Measure-Object -Property Length -Sum).Sum)
        if ($Modo -eq 'limpiar') {
            foreach ($f in $archivos) {
                try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $item.Liberado += $f.Length; $item.Borrados++ }
                catch { $item.Omitidos++ }
            }
            # Carpetas vacías que quedaron dentro de TEMP (nunca la carpeta raíz)
            if ($id -like 'temp_*') {
                foreach ($ruta in @($c.Rutas)) {
                    Get-ChildItem -LiteralPath $ruta -Recurse -Directory -Force -ErrorAction SilentlyContinue |
                        Sort-Object { $_.FullName.Length } -Descending |
                        Where-Object { $_.LastWriteTime -lt $limite -and -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1) } |
                        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
                }
            }
        }
    }
    if ($Modo -eq 'limpiar') {
        Write-Registro ("LIMPIEZA {0}: {1} archivos borrados, {2:N1} MB liberados, {3} en uso u omitidos" -f $c.Nombre, $item.Borrados, ($item.Liberado / 1MB), $item.Omitidos)
        $resultado.Liberado += $item.Liberado; $resultado.Borrados += $item.Borrados; $resultado.Omitidos += $item.Omitidos
    }
    $resultado.Categorias += $item
}

$json = $resultado | ConvertTo-Json -Depth 5
if ($Salida) { [System.IO.File]::WriteAllText($Salida, $json, (New-Object System.Text.UTF8Encoding($false))) }
else { $json }
