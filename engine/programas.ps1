# Doctor PC — programas instalados y espacio en disco.
#   -Modo listar      : programas instalados (registro + Microsoft Store + juegos de Epic) con disco, tamaño real y tipo
#   -Modo espacio     : qué ocupa espacio en una unidad o carpeta (-Ruta): carpetas, perfil y archivos más grandes
#   -Modo desinstalar : abre el desinstalador original del programa (-Clave del registro o -Paquete de la Store)
#   -Modo existe      : dice si el programa sigue instalado (-Clave o -Paquete)
# Nunca desinstala nada por su cuenta: siempre abre el desinstalador del propio programa.
param(
    [ValidateSet('listar', 'espacio', 'desinstalar', 'existe')][string]$Modo = 'listar',
    [switch]$SinTamanos,
    [string]$Ruta = '',
    [string]$Clave = '',
    [string]$Paquete = '',
    [string]$Salida = '',
    [string]$ArchivoProgreso = '',
    [string]$Registro = ''
)
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
. (Join-Path $PSScriptRoot 'archivos.ps1')

function Guardar($obj) {
    $json = $obj | ConvertTo-Json -Depth 6
    if ($Salida) { [System.IO.File]::WriteAllText($Salida, $json, (New-Object System.Text.UTF8Encoding($false))) } else { $json }
}
function Write-Registro([string]$t) {
    if ($Registro) { try { Add-Content -LiteralPath $Registro -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $t) -Encoding UTF8 } catch { } }
}

$raicesUninstall = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
)
function Test-ClaveValida([string]$k) {
    foreach ($r in $raicesUninstall) { if ($k.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase) -and $k.Substring($r.Length + 1) -notmatch '\\') { return $true } }
    return $false
}

# ---------------------------------------------------------------- existe
if ($Modo -eq 'existe') {
    $existe = $false
    if ($Clave) { $existe = (Test-ClaveValida $Clave) -and (Test-Path -LiteralPath $Clave) }
    elseif ($Paquete) { $existe = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.PackageFullName -eq $Paquete }).Count -gt 0 }
    Guardar ([ordered]@{ Existe = $existe })
    return
}

# ---------------------------------------------------------------- desinstalar
function Split-Comando([string]$cmd) {
    $cmd = $cmd.Trim()
    if ($cmd.StartsWith('"')) {
        $fin = $cmd.IndexOf('"', 1)
        if ($fin -gt 0) { return @($cmd.Substring(1, $fin - 1), $cmd.Substring($fin + 1).Trim()) }
    }
    $m = [regex]::Match($cmd, '^(.+?\.(exe|cmd|bat|com))(\s+(.*))?$', 'IgnoreCase')
    if ($m.Success) { return @($m.Groups[1].Value, $m.Groups[4].Value) }
    return @($cmd, '')
}
if ($Modo -eq 'desinstalar') {
    $res = [ordered]@{ Ok = $false; Mensaje = ''; Programa = '' }
    try {
        if ($Paquete) {
            $p = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.PackageFullName -eq $Paquete })[0]
            if (-not $p) { throw 'La app ya no está instalada.' }
            $res.Programa = $p.Name
            Remove-AppxPackage -Package $Paquete -ErrorAction Stop
            $res.Ok = $true; $res.Mensaje = 'App desinstalada.'
            Write-Registro "PROGRAMAS desinstalada la app de la Store $($p.Name)"
        }
        else {
            if (-not (Test-ClaveValida $Clave)) { throw 'Clave del registro no válida.' }
            $e = Get-ItemProperty -LiteralPath $Clave -ErrorAction Stop
            $res.Programa = $e.DisplayName
            $cmd = "$($e.UninstallString)"
            if (-not $cmd) { throw 'Este programa no tiene desinstalador registrado.' }
            $guid = [regex]::Match($cmd, '\{[0-9A-Fa-f\-]{36}\}').Value
            if ($cmd -match '(?i)msiexec' -and $guid) {
                Start-Process -FilePath 'msiexec.exe' -ArgumentList "/x $guid" -ErrorAction Stop
            }
            else {
                $partes = Split-Comando ([Environment]::ExpandEnvironmentVariables($cmd))
                if ($partes[1]) { Start-Process -FilePath $partes[0] -ArgumentList $partes[1] -ErrorAction Stop }
                else { Start-Process -FilePath $partes[0] -ErrorAction Stop }
            }
            $res.Ok = $true; $res.Mensaje = 'Se abrió el desinstalador del programa.'
            Write-Registro "PROGRAMAS abierto el desinstalador de $($e.DisplayName)"
        }
    }
    catch { $res.Mensaje = $_.Exception.Message }
    Guardar $res
    return
}

# ---------------------------------------------------------------- espacio
if ($Modo -eq 'espacio') {
    if (-not $Ruta) { $Ruta = $env:SystemDrive + '\' }
    if ($Ruta -match '^[A-Za-z]:$') { $Ruta += '\' }
    $vol = $null
    try { $vol = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $Ruta.Substring(0, 2)) } catch { }
    $perfil = $env:USERPROFILE
    $e = [DoctorPcFs]::Analizar($Ruta, $perfil, 100MB, 80, $(if ($ArchivoProgreso) { $ArchivoProgreso } else { $null }))
    $win = $env:SystemRoot
    $pf = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData) | Where-Object { $_ }
    $grandes = foreach ($g in $e.Grandes) {
        $tipo = 'personal'
        if ($g.Ruta -match '(?i)^[a-z]:\\(pagefile|hiberfil|swapfile)\.sys$') { $tipo = 'sistema' }
        elseif ($win -and $g.Ruta.StartsWith($win + '\', [StringComparison]::OrdinalIgnoreCase)) { $tipo = 'sistema' }
        elseif (@($pf | Where-Object { $g.Ruta.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) }).Count) { $tipo = 'programa' }
        elseif ($g.Ruta -match '(?i)\\steamapps\\|\\Epic Games\\|\\GOG Galaxy\\Games\\|\\Riot Games\\|\\XboxGames\\|\\WindowsApps\\') { $tipo = 'programa' }
        elseif ($g.Ruta -match '(?i)\\AppData\\') { $tipo = 'app' }
        [ordered]@{ Ruta = $g.Ruta; Nombre = [IO.Path]::GetFileName($g.Ruta); Tamano = [double]$g.Bytes; Fecha = $(if ($g.Fecha -gt [DateTime]::MinValue) { $g.Fecha.ToString('yyyy-MM-dd') } else { $null }); Tipo = $tipo; Extension = [IO.Path]::GetExtension($g.Ruta).ToLowerInvariant() }
    }
    $res = [ordered]@{
        Ruta = $Ruta; Total = [double]$(if ($vol) { $vol.Size } else { 0 }); Libre = [double]$(if ($vol) { $vol.FreeSpace } else { 0 })
        Analizado = [double]$e.Total; Archivos = $e.Archivos; Inaccesibles = $e.Inaccesibles
        Carpetas = @($e.Carpetas.Keys | ForEach-Object { [ordered]@{ Nombre = $_; Ruta = (Join-Path $Ruta $_); Tamano = [double]$e.Carpetas[$_] } } | Sort-Object { $_.Tamano } -Descending | Select-Object -First 25)
        Perfil = @($e.Perfil.Keys | ForEach-Object { [ordered]@{ Nombre = $_; Ruta = (Join-Path $perfil $_); Tamano = [double]$e.Perfil[$_] } } | Sort-Object { $_.Tamano } -Descending | Select-Object -First 20)
        RutaPerfil = $perfil
        Grandes = @($grandes)
    }
    Guardar $res
    return
}

# ---------------------------------------------------------------- listar
$protegidas = @($env:SystemDrive + '\', $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, (Join-Path $env:SystemDrive 'Users'), $env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA, (Join-Path $env:LOCALAPPDATA 'Programs'), (Split-Path $env:LOCALAPPDATA -Parent)) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLowerInvariant() }
function Get-CarpetaValida([string]$p) {
    if (-not $p) { return $null }
    $p = [Environment]::ExpandEnvironmentVariables($p.Trim().Trim('"')).TrimEnd('\')
    if ($p -notmatch '^[A-Za-z]:\\') { return $null }
    if ($protegidas -contains $p.ToLowerInvariant()) { return $null }
    if ($p -match '(?i)\\Windows\\(Installer|System32|SysWOW64)|\\Package Cache\\|\\Installer\\\{') { return $null }
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { return $null }
    return $p
}
function Get-CarpetaDeExe([string]$s) {
    if (-not $s) { return $null }
    $s = [Environment]::ExpandEnvironmentVariables($s.Trim())
    if ($s -match '(?i)msiexec|rundll32') { return $null }
    $exe = $null
    if ($s.StartsWith('"')) { $fin = $s.IndexOf('"', 1); if ($fin -gt 0) { $exe = $s.Substring(1, $fin - 1) } }
    else { $m = [regex]::Match($s, '^(.+?\.(exe|ico|dll))', 'IgnoreCase'); if ($m.Success) { $exe = $m.Groups[1].Value } }
    if (-not $exe) { $exe = ($s -split ',')[0] }
    if ($exe -notmatch '^[A-Za-z]:\\') { return $null }
    return (Get-CarpetaValida (Split-Path $exe -Parent))
}

$reEsencialRuntime = '(?i)Visual C\+\+ .*Redistributable|Microsoft Visual C\+\+ 20\d\d|\.NET (Framework|Runtime|Desktop Runtime)|Windows Desktop Runtime|ASP\.NET Core|Microsoft \.NET|DirectX|Edge WebView2|Microsoft Windows Desktop Runtime|Java\(TM\)|Java \d+ Update|OpenAL|Vulkan Run ?Time|PhysX|XNA Framework|Microsoft GameInput|Windows App Runtime|Microsoft Update Health Tools|Windows PC Health Check'
$reWindows = '(?i)^Microsoft Edge$|Edge WebView2|Microsoft Update Health Tools|Windows PC Health Check|^Microsoft OneDrive$|Windows Software Development Kit'
$reDriver = '(?i)\bdriver\b|controlador|chipset|Realtek|Intel\(R\) (Graphics|Management Engine|Serial IO|Rapid Storage|Wireless|Bluetooth|Chipset)|AMD (Chipset|Software|Radeon Software|Ryzen Master|Settings)|NVIDIA (Graphics Driver|HD Audio|PhysX|FrameView|USBC|Display Container)|Synaptics|ELAN|Killer|Dolby|Waves MaxxAudio|Conexant|Qualcomm|MediaTek|Broadcom|Thunderbolt|Logitech G HUB|Razer Synapse|Corsair iCUE|SteelSeries'
$reJuegoRuta = '(?i)\\steamapps\\common\\|\\Epic Games\\|\\GOG Galaxy\\Games\\|\\GOG Games\\|\\Riot Games\\|\\Ubisoft Game Launcher\\games\\|\\EA Games\\|\\Origin Games\\|\\XboxGames\\|\\Battle\.net\\|\\Games\\'
$reJuegoNombre = '(?i)^Steam App \d+|League of Legends|Valorant|Minecraft|Fortnite|Counter-Strike|Call of Duty|Grand Theft Auto|Cyberpunk|Elden Ring|Genshin|Roblox|Rocket League|Apex Legends|Overwatch|World of Warcraft|Diablo|Hearthstone|The Sims|FIFA|EA SPORTS FC|Forza|Halo|Assassin|Far Cry|Red Dead|Resident Evil|Baldur|Hogwarts|Palworld|Terraria|Stardew|Hollow Knight'
$reLauncher = '(?i)^Steam$|Epic Games Launcher|GOG GALAXY|Ubisoft Connect|EA app|Battle\.net|Riot Client|Xbox|Playnite|Rockstar Games Launcher|Heroic'
$reNavegador = '(?i)^(Google Chrome|Mozilla Firefox|Brave|Opera|Opera GX|Vivaldi|Microsoft Edge|Tor Browser|Arc|Zen Browser|Waterfox|LibreWolf)'
$reDesarrollo = '(?i)Python \d|Node\.js|^Git\b|Visual Studio|SDK|JDK|Java Development|Android Studio|IntelliJ|PyCharm|Docker|MySQL|PostgreSQL|XAMPP|WSL|Windows Subsystem|Cursor|Postman|GitHub Desktop|Unity Hub|Unreal|Godot'
$reSeguridad = '(?i)antivirus|Avast|AVG|Norton|McAfee|Kaspersky|ESET|Bitdefender|Malwarebytes|Avira|Panda|Total Security|Windows Defender'
$reOficina = '(?i)Office|LibreOffice|WPS|Adobe Acrobat|PDF|Foxit|Word|Excel|Notion|Obsidian|OneNote'
$reMultimedia = '(?i)VLC|Spotify|OBS|Audacity|HandBrake|PotPlayer|K-Lite|iTunes|Adobe (Photoshop|Premiere|After Effects|Illustrator|Lightroom)|DaVinci|GIMP|Krita|Blender|Inkscape|CapCut|Canva|Kdenlive|Shotcut|Paint\.NET'
$reComunicacion = '(?i)Discord|WhatsApp|Telegram|Zoom|Teams|Skype|Slack|Signal|Messenger'

function Get-Categoria([string]$nombre, [string]$editor, [string]$carpeta) {
    if ($nombre -match $reWindows) { return 'windows' }
    if ($nombre -match $reEsencialRuntime) { return 'componente' }
    if ($nombre -match $reDriver -or $editor -match '(?i)^(Realtek|Intel Corporation|Advanced Micro Devices|NVIDIA Corporation)$' -and $nombre -notmatch '(?i)GeForce Experience|NVIDIA App|Broadcast') { return 'controlador' }
    if ($nombre -match $reLauncher) { return 'tienda' }
    if (($carpeta -and $carpeta -match $reJuegoRuta) -or $nombre -match $reJuegoNombre) { return 'juego' }
    if ($nombre -match $reNavegador) { return 'navegador' }
    if ($nombre -match $reSeguridad) { return 'seguridad' }
    if ($nombre -match $reDesarrollo) { return 'desarrollo' }
    if ($nombre -match $reComunicacion) { return 'comunicacion' }
    if ($nombre -match $reMultimedia) { return 'multimedia' }
    if ($nombre -match $reOficina) { return 'oficina' }
    return 'programa'
}

$lista = New-Object System.Collections.ArrayList
$vistos = @{}
foreach ($raiz in $raicesUninstall) {
    foreach ($k in @(Get-ChildItem -LiteralPath $raiz -ErrorAction SilentlyContinue)) {
        $e = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if (-not $e -or -not $e.DisplayName) { continue }
        if ($e.SystemComponent -eq 1 -or $e.ParentKeyName -or $e.ReleaseType -match 'Update|Hotfix|Security' -or $e.DisplayName -match '^(Security Update|Update for|Hotfix for)\b|\(KB\d+\)') { continue }
        if (-not $e.UninstallString -and -not $e.QuietUninstallString) { continue }
        $nombre = "$($e.DisplayName)".Trim()
        $clave = "$raiz\$($k.PSChildName)"
        $dup = ($nombre + '|' + "$($e.DisplayVersion)").ToLowerInvariant()
        if ($vistos.ContainsKey($dup)) { continue }
        $vistos[$dup] = 1
        $carpeta = Get-CarpetaValida $e.InstallLocation
        if (-not $carpeta) { $carpeta = Get-CarpetaDeExe $e.DisplayIcon }
        if (-not $carpeta) { $carpeta = Get-CarpetaDeExe $e.UninstallString }
        $icono = $null
        if ($e.DisplayIcon) { $ic = ([Environment]::ExpandEnvironmentVariables("$($e.DisplayIcon)") -split ',')[0].Trim('"'); if ($ic -match '(?i)\.(exe|ico|dll)$' -and (Test-Path -LiteralPath $ic)) { $icono = $ic } }
        $fecha = $null
        if ("$($e.InstallDate)" -match '^(\d{4})(\d{2})(\d{2})$') { $fecha = "$($Matches[1])-$($Matches[2])-$($Matches[3])" }
        $cat = Get-Categoria $nombre "$($e.Publisher)" $carpeta
        [void]$lista.Add([ordered]@{
                Id = 'r:' + $clave; Tipo = $(if ($e.WindowsInstaller -eq 1 -or "$($e.UninstallString)" -match '(?i)msiexec') { 'msi' } else { 'win32' })
                Nombre = $nombre; Editor = "$($e.Publisher)".Trim(); Version = "$($e.DisplayVersion)"; Fecha = $fecha
                Carpeta = $carpeta; Unidad = $(if ($carpeta) { $carpeta.Substring(0, 2).ToUpperInvariant() } else { $null })
                TamanoEstimado = $(if ($e.EstimatedSize) { [double]$e.EstimatedSize * 1024 } else { $null }); TamanoReal = $null
                Categoria = $cat; Icono = $icono; Clave = $clave; Paquete = $null
                Alcance = $(if ($raiz -like 'HKCU:*') { 'usuario' } else { 'equipo' })
                PuedeDesinstalar = ($cat -ne 'windows')
            })
    }
}

# Apps de Microsoft Store que aparecen en el menú Inicio
$inicio = @{}
try { foreach ($s in @(Get-StartApps)) { $fam = ("$($s.AppID)" -split '!')[0]; if ($fam -and -not $inicio.ContainsKey($fam)) { $inicio[$fam] = $s.Name } } } catch { }
foreach ($p in @(Get-AppxPackage -ErrorAction SilentlyContinue)) {
    if ($p.IsFramework -or $p.IsResourcePackage -or $p.NonRemovable -or "$($p.SignatureKind)" -eq 'System') { continue }
    if (-not $inicio.ContainsKey($p.PackageFamilyName)) { continue }
    $carpeta = $p.InstallLocation
    $editorStore = "$($p.Publisher)" -replace '^CN=([^,]+).*$', '$1'
    $integrada = $editorStore -match '^Microsoft Corporation$' -and $p.Name -like 'Microsoft.*'
    [void]$lista.Add([ordered]@{
            Id = 's:' + $p.PackageFullName; Tipo = 'store'
            Nombre = $inicio[$p.PackageFamilyName]; Editor = $editorStore; Version = "$($p.Version)"; Fecha = $null
            Carpeta = $carpeta; Unidad = $(if ($carpeta -match '^[A-Za-z]:') { $carpeta.Substring(0, 2).ToUpperInvariant() } else { $null })
            TamanoEstimado = $null; TamanoReal = $null
            Categoria = $(if ($integrada) { 'store-windows' } else { Get-Categoria $inicio[$p.PackageFamilyName] $editorStore $carpeta })
            Icono = $null; Clave = $null; Paquete = $p.PackageFullName; Alcance = 'usuario'; PuedeDesinstalar = $true
        })
}

# Juegos de Epic Games (no aparecen en "Agregar o quitar programas")
foreach ($m in @(Get-ChildItem -LiteralPath (Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests') -Filter *.item -ErrorAction SilentlyContinue)) {
    try {
        $j = Get-Content -LiteralPath $m.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $j.DisplayName -or -not $j.InstallLocation) { continue }
        $carpeta = Get-CarpetaValida $j.InstallLocation
        if ($vistos.ContainsKey(("$($j.DisplayName)|").ToLowerInvariant())) { continue }
        [void]$lista.Add([ordered]@{
                Id = 'e:' + $j.AppName; Tipo = 'epic'
                Nombre = $j.DisplayName; Editor = 'Epic Games Store'; Version = "$($j.AppVersionString)"; Fecha = $null
                Carpeta = $carpeta; Unidad = $(if ($carpeta) { $carpeta.Substring(0, 2).ToUpperInvariant() } else { $null })
                TamanoEstimado = $(if ($j.InstallSize) { [double]$j.InstallSize } else { $null }); TamanoReal = $null
                Categoria = 'juego'; Icono = $null; Clave = $null; Paquete = $null; Alcance = 'usuario'; PuedeDesinstalar = $false
            })
    } catch { }
}

# Tamaño real en disco (sin contar carpetas de otros programas que estén dentro, como los juegos dentro de Steam)
if (-not $SinTamanos) {
    $porCarpeta = @{}
    foreach ($x in $lista) { if ($x.Carpeta -and -not $porCarpeta.ContainsKey($x.Carpeta.ToLowerInvariant())) { $porCarpeta[$x.Carpeta.ToLowerInvariant()] = [double]([DoctorPcFs]::Medir($x.Carpeta, 0, '*', $true).Bytes) } }
    $claves = @($porCarpeta.Keys)
    foreach ($x in $lista) {
        if (-not $x.Carpeta) { continue }
        $c = $x.Carpeta.ToLowerInvariant()
        $t = $porCarpeta[$c]
        foreach ($otra in $claves) { if ($otra -ne $c -and $otra.StartsWith($c + '\')) { $dentro = $false; foreach ($o2 in $claves) { if ($o2 -ne $c -and $o2 -ne $otra -and $otra.StartsWith($o2 + '\') -and $o2.StartsWith($c + '\')) { $dentro = $true } }; if (-not $dentro) { $t -= $porCarpeta[$otra] } } }
        $x.TamanoReal = [Math]::Max(0, $t)
    }
}

# Unidades con espacio total y libre
$unidades = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ Letra = $_.DeviceID; Nombre = $_.VolumeName; Total = [double]$_.Size; Libre = [double]$_.FreeSpace } })

Guardar ([ordered]@{ Fecha = (Get-Date).ToString('s'); Unidades = $unidades; Programas = @($lista) })
