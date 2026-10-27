#Requires -Version 5.1
<#
.SYNOPSIS
    Doctor PC 0.1 - Diagnóstico explicable para Windows 10/11.

.DESCRIPTION
    Analiza hardware, discos, rendimiento, juegos instalados y registros de Windows.
    Cada problema se presenta como: Observación -> Hipótesis -> Prueba -> Solución,
    con nivel de confianza y coste. Genera un plan de mejora ordenado por
    beneficio/coste según tu país y presupuesto, y un informe HTML + JSON.

    No modifica nada del sistema. Las reparaciones solo se ejecutan desde el menú
    de "Reparaciones guiadas", una por una y con confirmación explícita.
    Todo funciona sin internet y los datos no salen de tu PC.

.EXAMPLE
    .\DoctorPC.ps1
    Modo interactivo (pregunta país, presupuesto y si incluir usados).

.EXAMPLE
    .\DoctorPC.ps1 -Pais Venezuela -Presupuesto 50 -IncluirUsados -NoInteractivo

.EXAMPLE
    .\DoctorPC.ps1 -ModoJuego 120
    Mide durante 120 s mientras juegas para detectar el cuello de botella real.

.EXAMPLE
    .\DoctorPC.ps1 -DesdeJson .\DoctorPC_PC-CLIENTE_20261027_1030.json -Pais Chile -Presupuesto 100
    Regenera el informe a partir de un JSON (útil para técnicos: el cliente envía el JSON).
#>
[CmdletBinding()]
param(
    [string]$Pais = '',
    [double]$Presupuesto = -1,
    [switch]$IncluirUsados,
    [switch]$SoloNuevos,
    [ValidateRange(5, 600)][int]$Muestreo = 20,
    [ValidateRange(0, 1800)][int]$ModoJuego = 0,
    [string[]]$CarpetasJuegos = @(),
    [int]$FuenteWatts = 0,
    [string]$Salida = '',
    [string]$DesdeJson = '',
    [switch]$Reparar,
    [switch]$NoInteractivo,
    [switch]$Anonimo,
    [switch]$NoAbrir,
    [switch]$SinJuegos,
    [switch]$ModoApp,
    [string]$ArchivoProgreso = '',
    [string]$ArchivoCancelar = '',
    [ValidateSet('', 'dism_sfc', 'chkdsk', 'memoria', 'liberador', 'inicio', 'energia', 'graficos', 'actualizaciones')][string]$Accion = ''
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$script:Version = '0.2.0'
$script:Raiz = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:DirDatos = Join-Path $script:Raiz 'datos'
$script:EsWindows = ($env:OS -eq 'Windows_NT')
$script:Avisos = New-Object System.Collections.ArrayList
$script:ListaHallazgos = New-Object System.Collections.ArrayList
$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# =====================================================================
#  UTILIDADES
# =====================================================================

function Write-Titulo([string]$t) { Write-Host ''; Write-Host "  $t" -ForegroundColor Cyan }
function Write-Paso([string]$t)   { Write-Host "  > $t" -ForegroundColor Gray }
function Write-Ok([string]$t)     { Write-Host "    $t" -ForegroundColor Green }
function Write-Alerta([string]$t) { Write-Host "    ! $t" -ForegroundColor Yellow }
function Add-Aviso([string]$t)    { [void]$script:Avisos.Add($t) }

# Comunicación con la app de escritorio: líneas "##TIPO|dato|dato" en un archivo (funciona también elevado)
function Send-Evento([string]$Tipo, [object[]]$Partes = @()) {
    $linea = '##' + $Tipo + '|' + ((@($Partes) | ForEach-Object { "$_" -replace '[\r\n|]', ' ' }) -join '|')
    if ($ArchivoProgreso) { try { [System.IO.File]::AppendAllText($ArchivoProgreso, $linea + "`n", (New-Object System.Text.UTF8Encoding($false))) } catch { } }
    if ($ModoApp) { [Console]::Out.WriteLine($linea) }
}
function Test-Cancelado {
    if ($ArchivoCancelar -and (Test-Path -LiteralPath $ArchivoCancelar)) { Send-Evento 'CANCELADO'; exit 2 }
}
function Set-Paso([int]$Pct, [string]$Texto) {
    if ($ModoApp) { Send-Evento 'PROGRESO' @($Pct, $Texto); Test-Cancelado } else { Write-Paso $Texto }
}

function Get-CimSeguro {
    param([string]$Clase, [string]$Ns = 'root\cimv2', [string]$Filtro = '')
    try {
        if ($Filtro) { Get-CimInstance -Namespace $Ns -ClassName $Clase -Filter $Filtro -ErrorAction Stop }
        else { Get-CimInstance -Namespace $Ns -ClassName $Clase -ErrorAction Stop }
    } catch { }
}

function Get-Num($v, [double]$Def = 0) {
    if ($null -eq $v -or "$v" -eq '') { return $Def }
    try { return [double]$v } catch { return $Def }
}

function ConvertTo-GB($bytes) { [math]::Round((Get-Num $bytes) / 1GB, 1) }

function Get-FechaTexto($d) {
    if (-not $d) { return '' }
    try { return ([datetime]$d).ToString('yyyy-MM-dd') } catch { return "$d" }
}

function Format-Fecha($d, [switch]$Hora) {
    if (-not $d) { return '' }
    $f = if ($Hora) { 'yyyy-MM-dd HH:mm' } else { 'yyyy-MM-dd' }
    if ($d -is [datetime]) { return $d.ToString($f) }
    try { return ([datetime]::Parse("$d", $script:Inv)).ToString($f) } catch { return "$d" }
}

function Read-JsonArchivo([string]$Ruta) {
    if (-not (Test-Path -LiteralPath $Ruta)) { return $null }
    try { return (Get-Content -LiteralPath $Ruta -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { Add-Aviso "No se pudo leer $(Split-Path $Ruta -Leaf): $($_.Exception.Message)"; return $null }
}

function Test-Admin {
    if (-not $script:EsWindows) { return $false }
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Format-RutaPrivada([string]$Ruta) {
    if (-not $Ruta) { return $Ruta }
    if ($env:USERNAME) { $Ruta = $Ruta -replace ('(?i)\\Users\\' + [regex]::Escape($env:USERNAME) + '(\\|$)'), '\Users\<usuario>$1' }
    return $Ruta
}

# Convierte el formato sencillo de patrones ("RTX 4060 Ti", "A|B", "x*y", "re:...") en regex.
$script:CacheRegex = @{}
function ConvertTo-Patron([string]$p) {
    if (-not $p) { return '(?!)' }
    if ($script:CacheRegex.ContainsKey($p)) { return $script:CacheRegex[$p] }
    if ($p.StartsWith('re:')) { $r = $p.Substring(3) }
    else {
        $alts = foreach ($a in ($p -split '\|')) {
            $e = [regex]::Escape($a.Trim())
            $e = $e -replace '\\ ', '\s*'
            $e = $e -replace '\\\*', '.*'
            $e
        }
        $r = '(' + ($alts -join '|') + ')'
    }
    $script:CacheRegex[$p] = $r
    return $r
}

function Get-Estadisticas($Valores) {
    $v = @($Valores | Where-Object { $null -ne $_ -and "$_" -ne '' } | ForEach-Object { [double]$_ })
    if ($v.Count -eq 0) { return [pscustomobject]@{ Prom = $null; Max = $null; Min = $null; P95 = $null; N = 0 } }
    $s = @($v | Sort-Object)
    $suma = ($v | Measure-Object -Sum).Sum
    $i95 = [int][math]::Min($s.Count - 1, [math]::Floor($s.Count * 0.95))
    [pscustomobject]@{
        Prom = [math]::Round($suma / $v.Count, 1)
        Max  = [math]::Round($s[$s.Count - 1], 1)
        Min  = [math]::Round($s[0], 1)
        P95  = [math]::Round($s[$i95], 1)
        N    = $v.Count
    }
}

function Read-Opcion([string]$Pregunta, [string]$Defecto = '') {
    $sufijo = if ($Defecto -ne '') { " [$Defecto]" } else { '' }
    $r = Read-Host "  $Pregunta$sufijo"
    if ([string]::IsNullOrWhiteSpace($r)) { return $Defecto }
    return $r.Trim()
}

function Read-SiNo([string]$Pregunta, [bool]$Defecto = $true) {
    $d = if ($Defecto) { 'S/n' } else { 's/N' }
    $r = Read-Host "  $Pregunta ($d)"
    if ([string]::IsNullOrWhiteSpace($r)) { return $Defecto }
    return ($r.Trim().ToLower() -in @('s', 'si', 'sí', 'y', 'yes'))
}

# =====================================================================
#  RECOLECCIÓN (solo lectura)
# =====================================================================

function Get-InfoSistema {
    $os   = Get-CimSeguro Win32_OperatingSystem
    $cs   = Get-CimSeguro Win32_ComputerSystem
    $bios = Get-CimSeguro Win32_BIOS
    $mb   = Get-CimSeguro Win32_BaseBoard
    $enc  = @(Get-CimSeguro Win32_SystemEnclosure)
    $bat  = @(Get-CimSeguro Win32_Battery)

    $chasis = @($enc | ForEach-Object { $_.ChassisTypes } | Where-Object { $_ })
    $tiposPortatil = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $tiposSobremesa = @(3, 4, 5, 6, 7, 13, 15, 16, 35, 36)
    $esSobremesa = (@($chasis | Where-Object { $tiposSobremesa -contains [int]$_ }).Count -gt 0)
    $esPortatil = (@($chasis | Where-Object { $tiposPortatil -contains [int]$_ }).Count -gt 0) -or ("$($cs.PCSystemType)" -eq '2') -or ($bat.Count -gt 0 -and -not $esSobremesa)

    $nt = $null
    try { $nt = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop } catch { }
    $build = [int](Get-Num $os.BuildNumber)
    $caption = "$($os.Caption)".Trim()
    if ($build -ge 22000 -and $caption -match 'Windows 10') { $caption = $caption -replace 'Windows 10', 'Windows 11' }

    $planGuid = ''; $planNombre = ''
    try {
        $o = (powercfg.exe /getactivescheme 2>$null) -join ' '
        if ($o -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { $planGuid = $Matches[1].ToLower() }
        if ($o -match '\(([^)]+)\)\s*\*?\s*$') { $planNombre = $Matches[1] }
    } catch { }

    $inicioRapido = $null
    try { $inicioRapido = [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction Stop).HiberbootEnabled } catch { }

    $reinicioPendiente = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                         (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')

    $uptimeDias = $null
    if ($os.LastBootUpTime) { $uptimeDias = [math]::Round(((Get-Date) - [datetime]$os.LastBootUpTime).TotalDays, 1) }

    # Batería (portátiles)
    $bateria = $null
    if ($bat.Count -gt 0) {
        $salud = $null
        try {
            $full = @(Get-CimSeguro BatteryFullChargedCapacity -Ns 'root\wmi')[0].FullChargedCapacity
            $dis  = @(Get-CimSeguro BatteryStaticData -Ns 'root\wmi')[0].DesignedCapacity
            if ((Get-Num $dis) -gt 0) { $salud = [math]::Round((Get-Num $full) / (Get-Num $dis) * 100) }
        } catch { }
        $bateria = [ordered]@{
            Carga        = $bat[0].EstimatedChargeRemaining
            Conectado    = ("$($bat[0].BatteryStatus)" -ne '1')
            SaludPct     = $salud
        }
    }

    # Antivirus registrados
    $av = @()
    foreach ($a in @(Get-CimSeguro AntiVirusProduct -Ns 'root\SecurityCenter2')) {
        $estado = [int](Get-Num $a.productState)
        $av += [ordered]@{ Nombre = $a.displayName; Activo = ((($estado -shr 12) -band 0xF) -eq 1) }
    }

    # Archivo de paginación
    $pf = @(Get-CimSeguro Win32_PageFileUsage)
    $pagMB = ($pf | Measure-Object -Property AllocatedBaseSize -Sum).Sum
    $pagPicoMB = ($pf | Measure-Object -Property PeakUsage -Sum).Sum

    [ordered]@{
        Equipo            = $env:COMPUTERNAME
        Fabricante        = "$($cs.Manufacturer)".Trim()
        Modelo            = "$($cs.Model)".Trim()
        EsPortatil        = [bool]$esPortatil
        Windows           = $caption
        VersionWindows    = if ($nt -and $nt.DisplayVersion) { "$($nt.DisplayVersion)" } elseif ($nt) { "$($nt.ReleaseId)" } else { '' }
        Build             = $build
        Arquitectura      = "$($os.OSArchitecture)"
        Instalado         = Get-FechaTexto $os.InstallDate
        UptimeDias        = $uptimeDias
        InicioRapido      = $inicioRapido
        ReinicioPendiente = [bool]$reinicioPendiente
        PlanEnergiaGuid   = $planGuid
        PlanEnergia       = $planNombre
        Placa             = ("$($mb.Manufacturer) $($mb.Product)").Trim()
        BIOS              = "$($bios.SMBIOSBIOSVersion)".Trim()
        FechaBIOS         = Get-FechaTexto $bios.ReleaseDate
        Bateria           = $bateria
        Antivirus         = @($av)
        PaginacionMB      = $pagMB
        PaginacionPicoMB  = $pagPicoMB
        PaginacionAuto    = $cs.AutomaticManagedPagefile
    }
}

function Get-InfoCpu {
    $p = @(Get-CimSeguro Win32_Processor)
    if ($p.Count -eq 0) { return $null }
    $c = $p[0]
    [ordered]@{
        Nombre       = ("$($c.Name)" -replace '\s+', ' ').Trim()
        Fabricante   = "$($c.Manufacturer)"
        Nucleos      = [int](($p | Measure-Object -Property NumberOfCores -Sum).Sum)
        Hilos        = [int](($p | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
        MHzMax       = [int](Get-Num $c.MaxClockSpeed)
        MHzActual    = [int](Get-Num $c.CurrentClockSpeed)
        Socket       = "$($c.SocketDesignation)"
        L3KB         = [int](Get-Num $c.L3CacheSize)
    }
}

function Get-InfoGpu {
    # VRAM real desde el registro (Win32_VideoController se queda en 4 GB como máximo)
    $vramReg = @{}
    $clave = 'HKLM:\SYSTEM\ControlSet001\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    foreach ($k in @(Get-ChildItem -Path $clave -ErrorAction SilentlyContinue)) {
        $pp = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if (-not $pp -or -not $pp.DriverDesc) { continue }
        $q = $pp.'HardwareInformation.qwMemorySize'
        if ($q) { $vramReg[$pp.DriverDesc] = [double]$q; continue }
        $m = $pp.'HardwareInformation.MemorySize'
        if ($m) {
            if ($m -is [byte[]]) { $m = [BitConverter]::ToUInt32($m, 0) }
            $vramReg[$pp.DriverDesc] = [double]$m
        }
    }
    $lista = @()
    foreach ($v in @(Get-CimSeguro Win32_VideoController)) {
        $nombre = "$($v.Name)".Trim()
        $vram = $null
        if ($vramReg.ContainsKey($nombre)) { $vram = ConvertTo-GB $vramReg[$nombre] }
        elseif ((Get-Num $v.AdapterRAM) -gt 0) { $vram = ConvertTo-GB $v.AdapterRAM }
        $fab = 'Otro'
        if ("$($v.PNPDeviceID)" -match 'VEN_10DE') { $fab = 'NVIDIA' }
        elseif ("$($v.PNPDeviceID)" -match 'VEN_1002') { $fab = 'AMD' }
        elseif ("$($v.PNPDeviceID)" -match 'VEN_8086') { $fab = 'Intel' }
        $lista += [ordered]@{
            Nombre       = $nombre
            Fabricante   = $fab
            VramGB       = $vram
            Driver       = "$($v.DriverVersion)"
            FechaDriver  = Get-FechaTexto $v.DriverDate
            Resolucion   = if ($v.CurrentHorizontalResolution) { "$($v.CurrentHorizontalResolution)x$($v.CurrentVerticalResolution)" } else { '' }
            Hz           = $v.CurrentRefreshRate
            Estado       = "$($v.Status)"
            Virtual      = [bool]($nombre -match 'Remote|Virtual|Parsec|Mirage|DisplayLink|Citrix|Hyper-V|spacedesk|Meta Virtual|VNC|Splashtop')
        }
    }
    return @($lista)
}

function Get-InfoRam {
    $tipos = @{ 20 = 'DDR'; 21 = 'DDR2'; 22 = 'DDR2'; 24 = 'DDR3'; 26 = 'DDR4'; 27 = 'LPDDR'; 28 = 'LPDDR2'; 29 = 'LPDDR3'; 30 = 'LPDDR4'; 34 = 'DDR5'; 35 = 'LPDDR5' }
    $cs = Get-CimSeguro Win32_ComputerSystem
    $mods = @()
    foreach ($m in @(Get-CimSeguro Win32_PhysicalMemory)) {
        $t = [int](Get-Num $m.SMBIOSMemoryType)
        $tipo = if ($tipos.ContainsKey($t)) { $tipos[$t] } else { '' }
        if (-not $tipo) {
            $mt = [int](Get-Num $m.MemoryType)
            if ($tipos.ContainsKey($mt)) { $tipo = $tipos[$mt] }
        }
        $vel = [int](Get-Num $m.Speed)
        if (-not $tipo) {
            if ($vel -ge 4400) { $tipo = 'DDR5' } elseif ($vel -ge 2133) { $tipo = 'DDR4' } elseif ($vel -ge 800) { $tipo = 'DDR3' } else { $tipo = 'Desconocido' }
        }
        $ff = [int](Get-Num $m.FormFactor)
        $mods += [ordered]@{
            CapacidadGB  = ConvertTo-GB $m.Capacity
            Tipo         = $tipo
            Formato      = if ($ff -eq 12) { 'SODIMM' } elseif ($ff -eq 8) { 'DIMM' } else { "FF$ff" }
            MHz          = $vel
            MHzActual    = [int](Get-Num $m.ConfiguredClockSpeed)
            Ranura       = "$($m.DeviceLocator)".Trim()
            Banco        = "$($m.BankLabel)".Trim()
            Fabricante   = "$($m.Manufacturer)".Trim()
            Modelo       = "$($m.PartNumber)".Trim()
        }
    }
    $arr = @(Get-CimSeguro Win32_PhysicalMemoryArray | Where-Object { "$($_.Use)" -eq '3' -or -not $_.Use })
    $ranuras = [int](($arr | Measure-Object -Property MemoryDevices -Sum).Sum)
    $maxKB = 0
    foreach ($a in $arr) { $x = Get-Num $a.MaxCapacityEx; if ($x -le 0) { $x = Get-Num $a.MaxCapacity }; $maxKB += $x }
    [ordered]@{
        TotalGB      = ConvertTo-GB $cs.TotalPhysicalMemory
        InstaladaGB  = [math]::Round((($mods | ForEach-Object { $_.CapacidadGB }) | Measure-Object -Sum).Sum, 1)
        Ranuras      = $ranuras
        MaximoGB     = if ($maxKB -gt 0) { [math]::Round($maxKB / 1MB) } else { $null }
        Modulos      = @($mods)
    }
}

function Get-TipoDisco([string]$Media, [string]$Bus, [string]$Modelo, $Rpm) {
    $m = $Media; $b = $Bus
    switch ($m) { '3' { $m = 'HDD' } '4' { $m = 'SSD' } '5' { $m = 'SCM' } '0' { $m = 'Unspecified' } }
    switch ($b) { '17' { $b = 'NVMe' } '11' { $b = 'SATA' } '7' { $b = 'USB' } '8' { $b = 'RAID' } '10' { $b = 'SAS' } '3' { $b = 'ATA' } '15' { $b = 'Virtual' } }
    $externo = ($b -eq 'USB')
    if ($b -eq 'NVMe' -or $Modelo -match 'NVMe') { $tipo = 'SSD NVMe' }
    elseif ($m -eq 'SSD') { $tipo = 'SSD SATA' }
    elseif ($m -eq 'HDD') { $tipo = 'HDD' }
    elseif ($Modelo -match 'SSD|Solid|M\.2') { $tipo = 'SSD SATA' }
    elseif ((Get-Num $Rpm) -gt 0 -and (Get-Num $Rpm) -lt 20000) { $tipo = 'HDD' }
    elseif ($b -eq 'Virtual') { $tipo = 'Virtual' }
    else { $tipo = 'Desconocido' }
    if ($externo -and $tipo -eq 'SSD SATA') { $tipo = 'SSD externo (USB)' }
    if ($externo -and $tipo -eq 'HDD') { $tipo = 'HDD externo (USB)' }
    [pscustomobject]@{ Tipo = $tipo; Bus = $b; Externo = $externo; EsSSD = ($tipo -like 'SSD*'); EsHDD = ($tipo -like 'HDD*') }
}

function Get-InfoDiscos {
    $discos = @()
    $pds = @()
    try { $pds = @(Get-PhysicalDisk -ErrorAction Stop) } catch { }
    foreach ($d in $pds) {
        $num = [int](Get-Num $d.DeviceId -1)
        $t = Get-TipoDisco "$($d.MediaType)" "$($d.BusType)" "$($d.FriendlyName)" $d.SpindleSpeed
        $rel = $null
        try { $rel = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { }
        $vols = @()
        try {
            foreach ($part in @(Get-Partition -DiskNumber $num -ErrorAction Stop | Where-Object { $_.DriveLetter })) {
                $v = Get-Volume -DriveLetter $part.DriveLetter -ErrorAction SilentlyContinue
                if ($v) {
                    $vols += [ordered]@{ Letra = "$($part.DriveLetter):"; TamanoGB = ConvertTo-GB $v.Size; LibreGB = ConvertTo-GB $v.SizeRemaining; Etiqueta = "$($v.FileSystemLabel)" }
                }
            }
        } catch { }
        $discos += [ordered]@{
            Numero        = $num
            Modelo        = "$($d.FriendlyName)".Trim()
            TamanoGB      = ConvertTo-GB $d.Size
            Tipo          = $t.Tipo
            Bus           = $t.Bus
            EsSSD         = $t.EsSSD
            EsHDD         = $t.EsHDD
            Externo       = $t.Externo
            Salud         = "$($d.HealthStatus)"
            Estado        = "$(@($d.OperationalStatus) -join ', ')"
            TempC         = if ($rel -and (Get-Num $rel.Temperature) -gt 0) { $rel.Temperature } else { $null }
            TempMaxC      = if ($rel -and (Get-Num $rel.TemperatureMax) -gt 0) { $rel.TemperatureMax } else { $null }
            DesgastePct   = if ($rel) { $rel.Wear } else { $null }
            Horas         = if ($rel) { $rel.PowerOnHours } else { $null }
            ErroresLectura= if ($rel) { $rel.ReadErrorsUncorrected } else { $null }
            Volumenes     = @($vols)
        }
    }
    # Plan B si no existe Get-PhysicalDisk
    if ($discos.Count -eq 0) {
        foreach ($dd in @(Get-CimSeguro Win32_DiskDrive)) {
            $t = Get-TipoDisco '' "$($dd.InterfaceType)" "$($dd.Model)" $null
            $vols = @()
            try {
                foreach ($part in @(Get-CimAssociatedInstance -InputObject $dd -ResultClassName Win32_DiskPartition -ErrorAction Stop)) {
                    foreach ($ld in @(Get-CimAssociatedInstance -InputObject $part -ResultClassName Win32_LogicalDisk -ErrorAction Stop)) {
                        $vols += [ordered]@{ Letra = "$($ld.DeviceID)"; TamanoGB = ConvertTo-GB $ld.Size; LibreGB = ConvertTo-GB $ld.FreeSpace; Etiqueta = "$($ld.VolumeName)" }
                    }
                }
            } catch { }
            $discos += [ordered]@{
                Numero = [int](Get-Num $dd.Index -1); Modelo = "$($dd.Model)".Trim(); TamanoGB = ConvertTo-GB $dd.Size
                Tipo = $t.Tipo; Bus = $t.Bus; EsSSD = $t.EsSSD; EsHDD = $t.EsHDD; Externo = $t.Externo
                Salud = "$($dd.Status)"; Estado = ''; TempC = $null; TempMaxC = $null; DesgastePct = $null; Horas = $null; ErroresLectura = $null
                Volumenes = @($vols)
            }
        }
    }
    return @($discos)
}

function Get-InfoVolumenes {
    $out = @()
    foreach ($ld in @(Get-CimSeguro Win32_LogicalDisk -Filtro 'DriveType=3')) {
        $out += [ordered]@{ Letra = "$($ld.DeviceID)"; TamanoGB = ConvertTo-GB $ld.Size; LibreGB = ConvertTo-GB $ld.FreeSpace; Sistema = ("$($ld.DeviceID)" -eq "$env:SystemDrive") }
    }
    return @($out)
}

function Get-FalloPredicho {
    $r = @()
    foreach ($f in @(Get-CimSeguro MSStorageDriver_FailurePredictStatus -Ns 'root\wmi')) {
        if ($f.PredictFailure) { $r += "$($f.InstanceName)" }
    }
    return @($r)
}

function Get-Temperaturas {
    $t = @()
    foreach ($ns in @('root\LibreHardwareMonitor', 'root\OpenHardwareMonitor')) {
        foreach ($s in @(Get-CimSeguro Sensor -Ns $ns -Filtro "SensorType='Temperature'")) {
            $comp = 'Placa'
            if ("$($s.Parent)" -match 'cpu') { $comp = 'CPU' }
            elseif ("$($s.Parent)" -match 'gpu') { $comp = 'GPU' }
            elseif ("$($s.Parent)" -match 'hdd|nvme|ssd|storage') { $comp = 'Disco' }
            $t += [ordered]@{ Fuente = ($ns -replace 'root\\', ''); Componente = $comp; Sensor = "$($s.Name)"; Valor = [math]::Round((Get-Num $s.Value), 1); Max = [math]::Round((Get-Num $s.Max), 1) }
        }
    }
    foreach ($z in @(Get-CimSeguro MSAcpi_ThermalZoneTemperature -Ns 'root\wmi')) {
        $c = [math]::Round((Get-Num $z.CurrentTemperature) / 10 - 273.15, 1)
        if ($c -gt 5 -and $c -lt 125) {
            $t += [ordered]@{ Fuente = 'ACPI'; Componente = 'Zona térmica'; Sensor = "$($z.InstanceName)"; Valor = $c; Max = $null }
        }
    }
    return @($t)
}

function Get-EventosWindows([int]$Dias = 30) {
    $desde = (Get-Date).AddDays(-$Dias)
    $r = [ordered]@{
        Dias = $Dias; ApagadosInesperados = 0; FechasApagados = @(); Pantallazos = @(); ReiniciosDriverVideo = 0
        ErroresDisco = 0; DiscosConError = @(); ErroresNtfs = 0; ReiniciosControladorDisco = 0; MemoriaVirtualBaja = 0
        ErroresWhea = 0; WheaFatales = 0; CierresApps = @(); BloqueosApps = @()
    }
    if (-not $script:EsWindows) { return $r }

    $sys = @()
    try { $sys = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41, 6008, 1001, 4101, 7, 51, 153, 55, 98, 129, 2004; StartTime = $desde } -MaxEvents 3000 -ErrorAction Stop) } catch { }
    $fechas = @(); $discosErr = @{}
    foreach ($e in $sys) {
        $prov = "$($e.ProviderName)"
        switch ($e.Id) {
            41   { if ($prov -like '*Kernel-Power*') { $r.ApagadosInesperados++; $fechas += $e.TimeCreated.ToString('yyyy-MM-dd HH:mm') } }
            1001 {
                if ($prov -match 'WER-SystemErrorReporting|BugCheck') {
                    $txt = (@($e.Properties | ForEach-Object { "$($_.Value)" }) -join ' ') + ' ' + "$($e.Message)"
                    $cod = if ($txt -match '0x[0-9a-fA-F]{8}') { $Matches[0].ToUpper() -replace '^0X', '0x' } else { '' }
                    $r.Pantallazos += [ordered]@{ Fecha = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm'); Codigo = $cod }
                }
            }
            4101 { if ($prov -eq 'Display') { $r.ReiniciosDriverVideo++ } }
            { $_ -in 7, 51, 153 } {
                if ($prov -eq 'disk') {
                    $r.ErroresDisco++
                    $txt = (@($e.Properties | ForEach-Object { "$($_.Value)" }) -join ' ')
                    if ($txt -match 'Harddisk(\d+)') { $discosErr[$Matches[1]] = $true }
                }
            }
            { $_ -in 55, 98 } { if ($prov -like '*Ntfs*') { $r.ErroresNtfs++ } }
            129  { if ($prov -match 'storahci|stornvme|iaStor|storport|nvme|amd_sata|disk') { $r.ReiniciosControladorDisco++ } }
            2004 { if ($prov -like '*Resource-Exhaustion*') { $r.MemoriaVirtualBaja++ } }
        }
    }
    $r.FechasApagados = @($fechas | Select-Object -First 10)
    $r.DiscosConError = @($discosErr.Keys | ForEach-Object { [int]$_ })

    try {
        $wh = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $desde } -MaxEvents 500 -ErrorAction Stop)
        $r.ErroresWhea = $wh.Count
        $r.WheaFatales = @($wh | Where-Object { $_.Level -le 2 }).Count
    } catch { }

    $app = @()
    try { $app = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000, 1002; StartTime = $desde } -MaxEvents 2000 -ErrorAction Stop) } catch { }
    $cierres = @{}; $bloqueos = @{}
    foreach ($e in $app) {
        $nom = "$($e.Properties[0].Value)"
        if (-not $nom) { continue }
        if ($e.Id -eq 1000 -and $e.ProviderName -eq 'Application Error') {
            if (-not $cierres.ContainsKey($nom)) { $cierres[$nom] = [ordered]@{ App = $nom; Veces = 0; Modulo = "$($e.Properties[3].Value)"; Ultima = $e.TimeCreated.ToString('yyyy-MM-dd') } }
            $cierres[$nom].Veces++
        }
        elseif ($e.Id -eq 1002 -and $e.ProviderName -eq 'Application Hang') {
            if (-not $bloqueos.ContainsKey($nom)) { $bloqueos[$nom] = [ordered]@{ App = $nom; Veces = 0; Ultima = $e.TimeCreated.ToString('yyyy-MM-dd') } }
            $bloqueos[$nom].Veces++
        }
    }
    $r.CierresApps = @($cierres.Values | Sort-Object { $_.Veces } -Descending | Select-Object -First 15)
    $r.BloqueosApps = @($bloqueos.Values | Sort-Object { $_.Veces } -Descending | Select-Object -First 10)
    return $r
}

function Get-DispositivosConError {
    $out = @()
    foreach ($d in @(Get-CimSeguro Win32_PnPEntity -Filtro 'ConfigManagerErrorCode <> 0')) {
        $c = [int]$d.ConfigManagerErrorCode
        if ($c -eq 45) { continue }   # 45 = dispositivo desconectado (normal)
        $out += [ordered]@{ Nombre = "$($d.Name)"; Codigo = $c; Clase = "$($d.PNPClass)"; Id = ("$($d.DeviceID)" -replace '\\[^\\]*$', '') }
    }
    return @($out)
}

function Get-ProgramasInicio {
    $desactivados = @{}
    foreach ($k in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
                     'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
                     'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32',
                     'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder',
                     'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder')) {
        try {
            $p = Get-ItemProperty -Path $k -ErrorAction Stop
            foreach ($prop in $p.PSObject.Properties) {
                if ($prop.Name -like 'PS*') { continue }
                $b = $prop.Value
                if ($b -is [byte[]] -and $b.Length -gt 0 -and ($b[0] -band 1) -eq 1) { $desactivados[($prop.Name -replace '\.lnk$', '')] = $true }
            }
        } catch { }
    }
    $out = @()
    foreach ($s in @(Get-CimSeguro Win32_StartupCommand)) {
        $n = "$($s.Name)" -replace '\.lnk$', ''
        $out += [ordered]@{ Nombre = $n; Comando = (Format-RutaPrivada "$($s.Command)"); Ubicacion = "$($s.Location)"; Activo = (-not $desactivados.ContainsKey($n)) }
    }
    return @($out)
}

# ---------------- Rendimiento ----------------

function Invoke-Muestreo([int]$Segundos, [bool]$EsJuego) {
    $muestras = New-Object System.Collections.ArrayList
    $gpuPorPid = @{}
    $prevRaw = @{}
    $intervaloMs = 2000

    # Calentamiento: las clases "Formatted" devuelven 0 en la primera lectura
    $null = Get-CimSeguro Win32_PerfFormattedData_PerfOS_Processor
    $null = Get-CimSeguro Win32_PerfFormattedData_PerfDisk_PhysicalDisk
    foreach ($r in @(Get-CimSeguro Win32_PerfRawData_PerfDisk_PhysicalDisk)) { $prevRaw["$($r.Name)"] = $r }
    Start-Sleep -Milliseconds 1000

    $inicio = Get-Date
    $fin = $inicio.AddSeconds($Segundos)
    while ((Get-Date) -lt $fin) {
        $t0 = Get-Date
        $proc = @(Get-CimSeguro Win32_PerfFormattedData_PerfOS_Processor)
        $tot = $proc | Where-Object { $_.Name -eq '_Total' } | Select-Object -First 1
        $nucleos = @($proc | Where-Object { $_.Name -ne '_Total' } | ForEach-Object { [double]$_.PercentProcessorTime })
        $mem = Get-CimSeguro Win32_PerfFormattedData_PerfOS_Memory
        $perf = Get-CimSeguro Win32_PerfFormattedData_Counters_ProcessorInformation -Filtro "Name='_Total'"

        # GPU: suma por adaptador (luid) del motor 3D
        $gpuMax = $null
        $motores = @(Get-CimSeguro Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine | Where-Object { $_.Name -like '*engtype_3D*' })
        if ($motores.Count -gt 0) {
            $porLuid = @{}
            foreach ($g in $motores) {
                $u = Get-Num $g.UtilizationPercentage
                if ($g.Name -match 'luid_(0x[0-9A-Fa-f]+_0x[0-9A-Fa-f]+)') { $porLuid[$Matches[1]] = (Get-Num $porLuid[$Matches[1]]) + $u }
                if ($g.Name -match '^pid_(\d+)_' -and $u -gt 0) { $gpuPorPid[$Matches[1]] = (Get-Num $gpuPorPid[$Matches[1]]) + $u }
            }
            $gpuMax = [math]::Min(100, (($porLuid.Values | Measure-Object -Maximum).Maximum))
        }

        # Discos: % inactivo (formatted) + latencia (raw, calculada por diferencia)
        $dsk = @()
        $fmt = @(Get-CimSeguro Win32_PerfFormattedData_PerfDisk_PhysicalDisk | Where-Object { $_.Name -ne '_Total' })
        $raw = @(Get-CimSeguro Win32_PerfRawData_PerfDisk_PhysicalDisk | Where-Object { $_.Name -ne '_Total' })
        foreach ($f in $fmt) {
            $lat = $null
            $cur = $raw | Where-Object { $_.Name -eq $f.Name } | Select-Object -First 1
            $prev = $prevRaw["$($f.Name)"]
            if ($cur -and $prev) {
                $dc = (Get-Num $cur.AvgDisksecPerTransfer) - (Get-Num $prev.AvgDisksecPerTransfer)
                if ($dc -lt 0) { $dc += 4294967296 }
                $db = (Get-Num $cur.AvgDisksecPerTransfer_Base) - (Get-Num $prev.AvgDisksecPerTransfer_Base)
                $fq = Get-Num $cur.Frequency_PerfTime
                if ($db -gt 0 -and $fq -gt 0) { $lat = [math]::Round(($dc / $fq) / $db * 1000, 1) }
            }
            $dsk += [ordered]@{ Disco = "$($f.Name)"; Inactivo = [math]::Min(100, (Get-Num $f.PercentIdleTime)); LatMs = $lat; Cola = Get-Num $f.CurrentDiskQueueLength; MBs = [math]::Round((Get-Num $f.DiskBytesPersec) / 1MB, 1) }
        }
        foreach ($r in $raw) { $prevRaw["$($r.Name)"] = $r }

        [void]$muestras.Add([ordered]@{
            T          = [math]::Round(((Get-Date) - $inicio).TotalSeconds)
            Cpu        = Get-Num $tot.PercentProcessorTime
            NucleoMax  = if ($nucleos.Count) { ($nucleos | Measure-Object -Maximum).Maximum } else { $null }
            CpuPerf    = if ($perf) { Get-Num $perf.PercentProcessorPerformance } else { $null }
            RamLibreMB = Get-Num $mem.AvailableMBytes
            Commit     = Get-Num $mem.PercentCommittedBytesInUse
            Paginas    = Get-Num $mem.PagesPersec
            Gpu        = $gpuMax
            Discos     = @($dsk)
        })
        $hecho = [math]::Min($Segundos, [math]::Round(((Get-Date) - $inicio).TotalSeconds))
        if ($ModoApp) { Set-Paso ([int](50 + 40 * $hecho / [math]::Max(1, $Segundos))) ("Midiendo{0}... {1}/{2} s · CPU {3} %" -f $(if ($EsJuego) { ' tu partida' } else { '' }), $hecho, $Segundos, [math]::Round((Get-Num $tot.PercentProcessorTime))) }
        else { Write-Host -NoNewline ("`r    Midiendo... {0}/{1} s   CPU {2}%   " -f $hecho, $Segundos, [math]::Round((Get-Num $tot.PercentProcessorTime))) }
        $resto = $intervaloMs - ((Get-Date) - $t0).TotalMilliseconds
        if ($resto -gt 50) { Start-Sleep -Milliseconds ([int]$resto) }
    }
    Write-Host ''

    # Procesos que más consumen (dos instantáneas)
    $logicos = [Environment]::ProcessorCount
    $agg = @{}
    for ($i = 0; $i -lt 2; $i++) {
        foreach ($p in @(Get-CimSeguro Win32_PerfFormattedData_PerfProc_Process)) {
            if ($p.Name -in @('_Total', 'Idle')) { continue }
            $n = "$($p.Name)" -replace '#\d+$', ''
            if (-not $agg.ContainsKey($n)) { $agg[$n] = [ordered]@{ Nombre = $n; Cpu = 0.0; RamMB = 0.0 } }
            $agg[$n].Cpu += (Get-Num $p.PercentProcessorTime) / $logicos / 2
            if ($i -eq 0) { $agg[$n].RamMB += (Get-Num $p.WorkingSetPrivate) / 1MB }
        }
        if ($i -eq 0) { Start-Sleep -Milliseconds 1000 }
    }
    $topCpu = @($agg.Values | Sort-Object { $_.Cpu } -Descending | Select-Object -First 8 | ForEach-Object { [ordered]@{ Nombre = $_.Nombre; Cpu = [math]::Round($_.Cpu, 1); RamMB = [math]::Round($_.RamMB) } })
    $topRam = @($agg.Values | Sort-Object { $_.RamMB } -Descending | Select-Object -First 8 | ForEach-Object { [ordered]@{ Nombre = $_.Nombre; Cpu = [math]::Round($_.Cpu, 1); RamMB = [math]::Round($_.RamMB) } })

    $topGpu = @()
    foreach ($kv in @($gpuPorPid.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3)) {
        $pr = Get-Process -Id ([int]$kv.Key) -ErrorAction SilentlyContinue
        if ($pr) {
            $ruta = ''
            try { $ruta = $pr.Path } catch { }
            $topGpu += [ordered]@{ Nombre = $pr.ProcessName; GpuProm = [math]::Round($kv.Value / [math]::Max(1, $muestras.Count), 1); Unidad = if ($ruta) { Split-Path $ruta -Qualifier } else { '' }; Ruta = Format-RutaPrivada $ruta }
        }
    }

    [ordered]@{
        Segundos  = $Segundos
        ModoJuego = $EsJuego
        Muestras  = @($muestras)
        TopCpu    = $topCpu
        TopRam    = $topRam
        TopGpu    = @($topGpu)
    }
}

# ---------------- Juegos ----------------

function Get-TamanoCarpetaGB([string]$Ruta) {
    try {
        $s = (Get-ChildItem -LiteralPath $Ruta -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        return ConvertTo-GB $s
    } catch { return $null }
}

function Get-ExePrincipal([string]$Ruta) {
    $ex = 'unins|setup|redist|vcredist|dxsetup|crash|report|helper|install|prereq|dotnet|update|cleanup|benchmark|config|unitycrash|easyanticheat|battleye|be_service|dxwebsetup|oalinst|physx'
    $exes = @(Get-ChildItem -LiteralPath $Ruta -Filter '*.exe' -Recurse -Depth 3 -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch $ex })
    if ($exes.Count -eq 0) { return '' }
    return ($exes | Sort-Object Length -Descending | Select-Object -First 1).Name
}

function Get-Juegos([string[]]$Extra) {
    $juegos = @{}
    $agregar = {
        param($Nombre, $Tienda, $Ruta, $AppId, $GB, $Exe)
        if (-not $Ruta -or -not (Test-Path -LiteralPath $Ruta)) { return }
        $k = $Ruta.TrimEnd('\').ToLower()
        if ($juegos.ContainsKey($k)) { return }
        $juegos[$k] = [ordered]@{
            Nombre = $Nombre; Tienda = $Tienda; AppId = $AppId; Ruta = $Ruta; Exe = $Exe
            TamanoGB = $GB; Unidad = $(if ($Ruta -match '^([A-Za-z]:)') { $Matches[1].ToUpper() } else { '' })
        }
    }

    # --- Steam ---
    $steam = $null
    foreach ($k in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $p = Get-ItemProperty -Path $k -ErrorAction Stop
            if ($p.SteamPath) { $steam = $p.SteamPath } elseif ($p.InstallPath) { $steam = $p.InstallPath }
            if ($steam) { break }
        } catch { }
    }
    if ($steam) {
        $steam = $steam -replace '/', '\'
        $libs = @{}; $libs[$steam.ToLower()] = $steam
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            $txt = Get-Content -LiteralPath $vdf -Raw -ErrorAction SilentlyContinue
            foreach ($m in [regex]::Matches("$txt", '"path"\s+"([^"]+)"')) {
                $lp = $m.Groups[1].Value -replace '\\\\', '\'
                $libs[$lp.ToLower()] = $lp
            }
        }
        foreach ($lib in $libs.Values) {
            $sa = Join-Path $lib 'steamapps'
            foreach ($f in @(Get-ChildItem -LiteralPath $sa -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue)) {
                $t = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
                $id = if ($t -match '"appid"\s+"(\d+)"') { [int]$Matches[1] } else { 0 }
                $nom = if ($t -match '"name"\s+"([^"]*)"') { $Matches[1] } else { '' }
                $dir = if ($t -match '"installdir"\s+"([^"]*)"') { $Matches[1] } else { '' }
                $tam = if ($t -match '"SizeOnDisk"\s+"(\d+)"') { ConvertTo-GB $Matches[1] } else { $null }
                if ($id -in @(228980, 1070560, 1391110, 1628350, 1493710, 1826330, 2180100, 250820, 1161040, 2348590)) { continue }
                if ($nom -match 'Redistributable|Proton|Steam Linux Runtime|SteamVR|Dedicated Server|Soundtrack|SDK|Steamworks') { continue }
                & $agregar $nom 'Steam' (Join-Path $sa "common\$dir") $id $tam ''
            }
        }
    }

    # --- Epic Games ---
    $man = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
    foreach ($f in @(Get-ChildItem -LiteralPath $man -Filter '*.item' -ErrorAction SilentlyContinue)) {
        try {
            $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            if ($j.DisplayName -match 'Unreal Engine|Launcher') { continue }
            & $agregar $j.DisplayName 'Epic Games' $j.InstallLocation $null (ConvertTo-GB $j.InstallSize) (Split-Path "$($j.LaunchExecutable)" -Leaf)
        } catch { }
    }

    # --- GOG ---
    foreach ($k in @(Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games' -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if ($p -and $p.path) { & $agregar $p.gameName 'GOG' $p.path $null $null (Split-Path "$($p.exe)" -Leaf) }
    }

    # --- Ubisoft Connect ---
    foreach ($k in @(Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher\Installs' -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if ($p -and $p.InstallDir) { $r = ($p.InstallDir -replace '/', '\').TrimEnd('\'); & $agregar (Split-Path $r -Leaf) 'Ubisoft' $r $null $null '' }
    }

    # --- EA (Origin / EA app) ---
    foreach ($base in @('HKLM:\SOFTWARE\WOW6432Node\EA Games', 'HKLM:\SOFTWARE\WOW6432Node\Electronic Arts')) {
        foreach ($k in @(Get-ChildItem $base -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            $dir = if ($p) { $p.'Install Dir' } else { $null }
            if ($dir) { & $agregar ($(if ($p.DisplayName) { $p.DisplayName } else { $k.PSChildName })) 'EA' $dir.TrimEnd('\') $null $null '' }
        }
    }

    # --- Riot, Xbox, carpetas habituales en todas las unidades ---
    $raices = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Root -match '^[A-Z]:\\$' } | ForEach-Object { $_.Root })
    foreach ($rz in $raices) {
        foreach ($riot in @((Join-Path $rz 'Riot Games'), (Join-Path $rz 'Program Files\Riot Games'))) {
            if (Test-Path -LiteralPath (Join-Path $riot 'VALORANT')) { & $agregar 'VALORANT' 'Riot' (Join-Path $riot 'VALORANT') $null $null 'VALORANT.exe' }
            if (Test-Path -LiteralPath (Join-Path $riot 'League of Legends')) { & $agregar 'League of Legends' 'Riot' (Join-Path $riot 'League of Legends') $null $null 'LeagueClient.exe' }
        }
        $xb = Join-Path $rz 'XboxGames'
        foreach ($g in @(Get-ChildItem -LiteralPath $xb -Directory -ErrorAction SilentlyContinue)) { & $agregar $g.Name 'Xbox / Microsoft Store' $g.FullName $null $null '' }
        foreach ($nombreCarpeta in @('Games', 'Juegos')) { $Extra += (Join-Path $rz $nombreCarpeta) }
    }

    # --- Minecraft / Roblox ---
    if ($env:APPDATA -and (Test-Path -LiteralPath (Join-Path $env:APPDATA '.minecraft'))) { & $agregar 'Minecraft: Java Edition' 'Minecraft' (Join-Path $env:APPDATA '.minecraft') $null $null '' }
    if ($env:LOCALAPPDATA -and (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Roblox\Versions'))) { & $agregar 'Roblox' 'Roblox' (Join-Path $env:LOCALAPPDATA 'Roblox') $null $null '' }

    # --- Carpetas elegidas por el usuario (sin importar la procedencia del juego) ---
    $txt = Join-Path $script:Raiz 'carpetas_juegos.txt'
    if (Test-Path -LiteralPath $txt) {
        $Extra += @(Get-Content -LiteralPath $txt -Encoding UTF8 | Where-Object { $_ -and $_.Trim() -and -not $_.Trim().StartsWith('#') } | ForEach-Object { $_.Trim().Trim('"') })
    }
    foreach ($c in @($Extra | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $c)) { continue }
        foreach ($sub in @(Get-ChildItem -LiteralPath $c -Directory -ErrorAction SilentlyContinue)) {
            $k = $sub.FullName.TrimEnd('\').ToLower()
            if ($juegos.ContainsKey($k)) { continue }
            $exe = Get-ExePrincipal $sub.FullName
            if (-not $exe) { continue }
            $gb = Get-TamanoCarpetaGB $sub.FullName
            if ((Get-Num $gb) -lt 0.3) { continue }
            & $agregar $sub.Name 'Carpeta' $sub.FullName $null $gb $exe
        }
    }
    return @($juegos.Values | Sort-Object { $_.Nombre })
}

# =====================================================================
#  ANÁLISIS
# =====================================================================

function Get-IndiceGpu([string]$Nombre) {
    $r = [ordered]@{ Indice = $null; Integrada = $false; SinDriver = $false }
    if (-not $Nombre -or -not $script:Indices) { return [pscustomobject]$r }
    $Nombre = ($Nombre -replace '\(R\)|\(TM\)', '' -replace '\s+', ' ').Trim()
    foreach ($g in @($script:Indices.gpu)) {
        if ($Nombre -match (ConvertTo-Patron $g.m)) {
            $r.Indice = [double]$g.i; $r.Integrada = [bool]$g.igpu; $r.SinDriver = [bool]$g.sindriver
            break
        }
    }
    if ($r.Indice -and -not $r.Integrada -and $Nombre -match 'Laptop|Max-Q|Mobile') { $r.Indice = [math]::Round($r.Indice * 0.8) }
    if ($null -eq $r.Indice -and $Nombre -match 'Intel') { $r.Integrada = $true }
    return [pscustomobject]$r
}

function Get-IndiceCpu([string]$Nombre, [int]$Hilos) {
    $r = [ordered]@{ Indice = $null; Plataforma = ''; Portatil = $false; Generacion = '' }
    if (-not $Nombre) { return [pscustomobject]$r }
    $n = ($Nombre -replace '\(R\)|\(TM\)', '' -replace '\s+', ' ').Trim()

    foreach ($c in @($(if ($script:Indices) { $script:Indices.cpu }))) {
        if ($n -match (ConvertTo-Patron $c.m)) {
            $r.Indice = [double]$c.i; $r.Plataforma = "$($c.plat)"; $r.Portatil = [bool]$c.portatil
            return [pscustomobject]$r
        }
    }
    if ($n -match 'Ultra ([579]) (\d)(\d{2})([A-Z]*)') {
        $tier = @{ '5' = 1.0; '7' = 1.12; '9' = 1.22 }[$Matches[1]]
        $serie = [int]$Matches[2]; $suf = $Matches[4]
        $base = if ($serie -ge 2) { 195 } else { 150 }
        $f = 1.0
        if ($suf -match 'U|V') { $f = 0.7 } elseif ($suf -match 'H|P') { $f = 0.85 }
        $r.Indice = [math]::Round($base * $tier * $f)
        $r.Portatil = [bool]($suf -match 'U|V|H|P')
        if (-not $r.Portatil -and $serie -ge 2) { $r.Plataforma = 'LGA1851' }
        $r.Generacion = "Core Ultra serie $serie"
        return [pscustomobject]$r
    }
    if ($n -match '\bi([3579])-(\d{3,5})([A-Z]{0,3})') {
        $t = $Matches[1]; $num = $Matches[2]; $suf = $Matches[3]
        if ($num.Length -eq 5) { $gen = [int]$num.Substring(0, 2) }
        elseif ($num.Length -eq 4 -and $num.StartsWith('1')) { $gen = [int]$num.Substring(0, 2) }
        elseif ($num.Length -eq 4) { $gen = [int]$num.Substring(0, 1) }
        else { $gen = 1 }
        $gf = @{ 1 = 40; 2 = 50; 3 = 55; 4 = 62; 5 = 63; 6 = 72; 7 = 78; 8 = 100; 9 = 103; 10 = 110; 11 = 128; 12 = 155; 13 = 170; 14 = 175 }
        $base = if ($gf.ContainsKey($gen)) { $gf[$gen] } else { 100 }
        $tier = @{ '3' = 0.72; '5' = 1.0; '7' = 1.15; '9' = 1.25 }[$t]
        if ($gen -le 7 -and $t -eq '3') { $tier = 0.65 }
        if ($gen -le 7 -and $t -eq '7') { $tier = 1.12 }
        $f = 1.0
        if ($suf -match '^(U|Y|G)') { $f = 0.62 } elseif ($suf -match '^P') { $f = 0.75 } elseif ($suf -match '^(H|M|Q)') { $f = 0.88 } elseif ($suf -match '^T') { $f = 0.9 }
        $r.Indice = [math]::Round($base * $tier * $f)
        $r.Portatil = [bool]($suf -match '^(U|Y|G|P|H|M|Q)')
        $r.Generacion = "Intel Core de $gen.ª generación"
        $hedt = ($num.Length -eq 4 -and $num -match '^(3[89]|4[89]|5[89]|6[89]|7[89])\d\d$')
        if (-not $r.Portatil -and -not $hedt) {
            $plat = @{ 1 = 'LGA1156'; 2 = 'LGA1155'; 3 = 'LGA1155'; 4 = 'LGA1150'; 5 = 'LGA1150'; 6 = 'LGA1151'; 7 = 'LGA1151'; 8 = 'LGA1151v2'; 9 = 'LGA1151v2'; 10 = 'LGA1200'; 11 = 'LGA1200'; 12 = 'LGA1700'; 13 = 'LGA1700'; 14 = 'LGA1700' }
            if ($plat.ContainsKey($gen)) { $r.Plataforma = $plat[$gen] }
        }
        return [pscustomobject]$r
    }
    if ($n -match 'Ryzen ([3579]) (?:PRO )?(\d)(\d)(\d{2})([A-Z0-9]*)') {
        $t = $Matches[1]; $serie = [int]$Matches[2]; $suf = $Matches[5]
        $sf = @{ 1 = 80; 2 = 90; 3 = 115; 4 = 115; 5 = 150; 6 = 150; 7 = 190; 8 = 175; 9 = 210 }
        $base = $sf[$serie]
        $tier = @{ '3' = 0.75; '5' = 1.0; '7' = 1.1; '9' = 1.15 }[$t]
        $port = [bool]($suf -match '^(U|H)')
        $f = 1.0
        if ($suf -match '^U') { $f = 0.72 } elseif ($suf -match '^H') { $f = 0.9 }
        if ($suf -match 'X3D') { $f = $f * 1.2 }
        $r.Indice = [math]::Round($base * $tier * $f)
        $r.Portatil = $port
        $r.Generacion = "AMD Ryzen serie $($serie)000"
        if (-not $port) {
            if ($serie -le 5) { $r.Plataforma = 'AM4' } elseif ($serie -in 7, 8, 9) { $r.Plataforma = 'AM5' }
        }
        return [pscustomobject]$r
    }
    $r.Indice = [math]::Min(150, 20 + [math]::Max(2, $Hilos) * 6)
    return [pscustomobject]$r
}

function New-Hallazgo {
    param(
        [string]$Id, [string]$Categoria,
        [ValidateSet('critico', 'alto', 'medio', 'bajo', 'info')][string]$Severidad,
        [string]$Titulo, [string[]]$Observacion, [string]$Hipotesis, [string]$Prueba, [string[]]$Solucion,
        [string]$Coste = 'Gratis', [ValidateSet('Alta', 'Media', 'Baja')][string]$Confianza = 'Media',
        [string]$Reparacion = ''
    )
    [void]$script:ListaHallazgos.Add([pscustomobject][ordered]@{
        Id = $Id; Categoria = $Categoria; Severidad = $Severidad; Titulo = $Titulo
        Observacion = @($Observacion); Hipotesis = $Hipotesis; Prueba = $Prueba; Solucion = @($Solucion)
        Coste = $Coste; Confianza = $Confianza; Reparacion = $Reparacion
    })
}

$script:ProcesosConocidos = @{
    'MsMpEng'         = 'Antivirus de Windows (Defender) analizando archivos. Es normal tras actualizaciones o descargas; si es constante, programa los análisis para cuando no uses el PC.'
    'TiWorker'        = 'Windows Update instalando actualizaciones. Deja el PC encendido hasta que termine y reinicia.'
    'TrustedInstaller'= 'Windows Update instalando componentes. Suele terminar solo.'
    'SearchIndexer'   = 'Indexado de búsqueda de Windows. Termina solo; en un HDD lento puede tardar horas.'
    'SearchHost'      = 'Búsqueda de Windows.'
    'CompatTelRunner' = 'Telemetría de compatibilidad de Windows. Es temporal.'
    'svchost'         = 'Servicios de Windows agrupados. Puede ser Windows Update, SysMain u otros servicios.'
    'OneDrive'        = 'OneDrive sincronizando archivos. Puedes pausar la sincronización mientras juegas.'
    'chrome'          = 'Google Chrome: cada pestaña consume RAM. Cierra pestañas o activa el ahorro de memoria.'
    'msedge'          = 'Microsoft Edge: cada pestaña consume RAM. Activa "Pestañas en suspensión".'
    'firefox'         = 'Firefox: cada pestaña consume RAM.'
    'Discord'         = 'Discord: desactiva la aceleración por hardware y la superposición si notas tirones.'
    'steamwebhelper'  = 'Interfaz de Steam. Activa el modo de bajo consumo en Configuración de Steam > Interfaz.'
    'EpicGamesLauncher' = 'Lanzador de Epic. Puede cerrarse una vez abierto el juego en muchos títulos.'
    'MemCompression'  = 'Compresión de memoria de Windows: si usa mucho, te falta RAM.'
    'System'          = 'Núcleo de Windows y drivers. Un uso alto constante apunta a un driver problemático.'
}

$script:CodigosPantallazo = @{
    '0x0000001A' = 'MEMORY_MANAGEMENT: suele indicar RAM defectuosa o perfil XMP/DOCP inestable.'
    '0x0000003B' = 'SYSTEM_SERVICE_EXCEPTION: normalmente un driver.'
    '0x0000007E' = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED: normalmente un driver.'
    '0x0000000A' = 'IRQL_NOT_LESS_OR_EQUAL: driver o RAM.'
    '0x000000D1' = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL: driver (a menudo red o Wi-Fi).'
    '0x00000050' = 'PAGE_FAULT_IN_NONPAGED_AREA: RAM o driver.'
    '0x000000EF' = 'CRITICAL_PROCESS_DIED: archivos de sistema dañados o disco con problemas.'
    '0x0000007A' = 'KERNEL_DATA_INPAGE_ERROR: el disco no pudo leer datos (disco o cable).'
    '0x000000F4' = 'CRITICAL_OBJECT_TERMINATION: disco o cable SATA.'
    '0x00000116' = 'VIDEO_TDR_FAILURE: driver de la tarjeta gráfica, temperatura u overclock.'
    '0x00000117' = 'VIDEO_TDR_TIMEOUT: driver de la tarjeta gráfica.'
    '0x00000124' = 'WHEA_UNCORRECTABLE_ERROR: error de hardware (CPU, RAM, temperatura, voltaje u overclock).'
    '0x00000133' = 'DPC_WATCHDOG_VIOLATION: driver o firmware del SSD.'
    '0x00000139' = 'KERNEL_SECURITY_CHECK_FAILURE: driver o RAM.'
    '0x0000009F' = 'DRIVER_POWER_STATE_FAILURE: driver al suspender o reanudar.'
    '0x0000001E' = 'KMODE_EXCEPTION_NOT_HANDLED: driver.'
    '0x000000C2' = 'BAD_POOL_CALLER: driver.'
    '0x00000019' = 'BAD_POOL_HEADER: driver o RAM.'
}

$script:CodigosDispositivo = @{
    1 = 'No está configurado correctamente'; 3 = 'Driver dañado o falta de memoria'; 10 = 'El dispositivo no puede iniciarse'
    12 = 'Conflicto de recursos'; 14 = 'Requiere reiniciar'; 18 = 'Hay que reinstalar el driver'; 19 = 'Configuración del registro dañada'
    21 = 'Windows lo está quitando'; 22 = 'Deshabilitado'; 24 = 'No presente o driver incompleto'; 28 = 'Driver no instalado'
    31 = 'Windows no pudo cargar el driver'; 32 = 'Servicio del driver deshabilitado'; 37 = 'El driver falló al iniciarse'
    39 = 'Driver dañado o ausente'; 43 = 'Windows lo detuvo por un fallo (frecuente en GPU/USB)'; 48 = 'Driver bloqueado por incompatibilidad'; 52 = 'Firma del driver no verificada'
}

function Get-DiscoDeUnidad($D, [string]$Letra) {
    if (-not $Letra) { return $null }
    foreach ($dk in @($D.Discos)) {
        foreach ($v in @($dk.Volumenes)) { if ("$($v.Letra)" -eq $Letra) { return $dk } }
    }
    return $null
}

function Get-Contexto($D) {
    $c = [ordered]@{}
    $s = $D.Sistema
    $c.EsPortatil = [bool]$s.EsPortatil
    $c.Fabricante = "$($s.Fabricante)"
    $c.EsOEM = ($c.Fabricante -match 'Dell|HP|Hewlett|Lenovo|Acer|Compaq|Fujitsu|Toshiba|Packard Bell|Positivo|Siragon|\bVIT\b|Gateway|eMachines')

    # CPU
    $ci = Get-IndiceCpu "$($D.Cpu.Nombre)" ([int](Get-Num $D.Cpu.Hilos))
    $c.CpuIndice = $ci.Indice
    $c.CpuPlataforma = $ci.Plataforma
    $c.CpuPortatil = ($ci.Portatil -or $c.EsPortatil)
    $c.CpuGeneracion = $ci.Generacion

    # GPU principal: una dedicada (aunque no esté en la tabla) tiene prioridad sobre la integrada
    $c.Gpus = @()
    foreach ($g in @($D.Gpus | Where-Object { $_ -and -not $_.Virtual })) {
        $gi = Get-IndiceGpu "$($g.Nombre)"
        $c.Gpus += [pscustomobject]@{ Nombre = "$($g.Nombre)"; Indice = $gi.Indice; Integrada = $gi.Integrada; SinDriver = $gi.SinDriver; VramGB = $g.VramGB; FechaDriver = "$($g.FechaDriver)"; Fabricante = "$($g.Fabricante)"
                                      Dedicada = (-not $gi.Integrada -and -not $gi.SinDriver) }
    }
    $mejor = @($c.Gpus | Sort-Object { [int]$_.Dedicada }, { Get-Num $_.Indice -1 } -Descending) | Select-Object -First 1
    $c.Gpu = $mejor
    $c.GpuIndice = if ($mejor) { $mejor.Indice } else { $null }
    $c.HaySinDriver = (@($c.Gpus | Where-Object { $_.SinDriver }).Count -gt 0)
    $c.SoloIntegrada = (@($c.Gpus | Where-Object { $_.Dedicada }).Count -eq 0) -and -not $c.HaySinDriver
    $c.TieneHibrida = (@($c.Gpus | Where-Object { $_.Integrada }).Count -gt 0) -and (@($c.Gpus | Where-Object { $_.Dedicada }).Count -gt 0)

    # RAM
    $r = $D.Ram
    $mods = @($r.Modulos | Where-Object { $_ })
    $c.RamGB = Get-Num $r.TotalGB
    $inst = Get-Num $r.InstaladaGB
    $c.RamCmp = if ($inst -gt 0) { $inst } else { $c.RamGB + 0.6 }
    $c.RamTexto = if ($inst -gt 0) { "$([math]::Round($inst)) GB" } else { "$([math]::Round($c.RamGB)) GB" }
    $c.RamModulos = $mods.Count
    $c.RamTipo = if ($mods.Count) { ($mods | Group-Object { $_.Tipo } | Sort-Object Count -Descending | Select-Object -First 1).Name } else { '' }
    $c.RamFormato = if ($mods.Count) { "$($mods[0].Formato)" } else { '' }
    $c.RamModuloGB = if ($mods.Count) { [math]::Round((Get-Num $mods[0].CapacidadGB)) } else { 0 }
    $c.RamMHz = if ($mods.Count) { [int](Get-Num $mods[0].MHz) } else { 0 }
    $c.RamRanuras = [int](Get-Num $r.Ranuras)
    $c.RamLibres = if ($c.RamRanuras -gt 0) { [math]::Max(0, $c.RamRanuras - $mods.Count) } else { $null }
    $c.RamMaxGB = Get-Num $r.MaximoGB
    $c.RamSoldada = ($c.RamTipo -like 'LP*')
    $canales = @{}
    foreach ($m in $mods) {
        $loc = "$($m.Ranura) $($m.Banco)"
        if ($loc -match 'Channel\s*([A-D])|DIMM[_\s-]?([A-D])\d|CHANNEL\s*([A-D])') {
            $l = (@($Matches[1], $Matches[2], $Matches[3]) | Where-Object { $_ } | Select-Object -First 1)
            $canales[$l] = $true
        }
    }
    if ($mods.Count -le 1) { $c.RamCanal = 'Simple' }
    elseif ($canales.Count -ge 2) { $c.RamCanal = 'Doble' }
    elseif ($canales.Count -eq 1) { $c.RamCanal = 'Simple (módulos en el mismo canal)' }
    else { $c.RamCanal = 'Probablemente doble' }
    $c.RamTamanosMixtos = (@($mods | ForEach-Object { $_.CapacidadGB } | Select-Object -Unique).Count -gt 1)
    $c.RamBajoVelocidad = (@($mods | Where-Object { (Get-Num $_.MHzActual) -gt 0 -and (Get-Num $_.MHz) -gt 0 -and (Get-Num $_.MHzActual) -lt (Get-Num $_.MHz) * 0.85 }).Count -gt 0)

    # Discos
    $sysLetra = if ($D.Sistema.UnidadSistema) { "$($D.Sistema.UnidadSistema)" } else { 'C:' }
    $c.DiscoSistema = Get-DiscoDeUnidad $D $sysLetra
    $c.SistemaEnHDD = [bool]($c.DiscoSistema -and $c.DiscoSistema.EsHDD)
    $vSys = @($D.Volumenes | Where-Object { "$($_.Letra)" -eq $sysLetra }) | Select-Object -First 1
    if (-not $vSys -and $c.DiscoSistema) { $vSys = @($c.DiscoSistema.Volumenes | Where-Object { "$($_.Letra)" -eq $sysLetra }) | Select-Object -First 1 }
    $c.SysLetra = $sysLetra
    $c.SysLibreGB = if ($vSys) { Get-Num $vSys.LibreGB } else { $null }
    $c.SysTamanoGB = if ($vSys) { Get-Num $vSys.TamanoGB } else { $null }
    $c.SysUsadoGB = if ($vSys) { (Get-Num $vSys.TamanoGB) - (Get-Num $vSys.LibreGB) } else { $null }
    $c.HaySSD = (@($D.Discos | Where-Object { $_.EsSSD -and -not $_.Externo }).Count -gt 0)

    # Muestreo
    $c.Muestreo = $null
    if ($D.Muestreo -and @($D.Muestreo.Muestras).Count -gt 0) {
        $ms = @($D.Muestreo.Muestras)
        $st = [ordered]@{
            ModoJuego = [bool]$D.Muestreo.ModoJuego
            Cpu       = Get-Estadisticas ($ms | ForEach-Object { $_.Cpu })
            NucleoMax = Get-Estadisticas ($ms | ForEach-Object { $_.NucleoMax })
            CpuPerf   = Get-Estadisticas ($ms | ForEach-Object { $_.CpuPerf })
            RamLibre  = Get-Estadisticas ($ms | ForEach-Object { $_.RamLibreMB })
            Commit    = Get-Estadisticas ($ms | ForEach-Object { $_.Commit })
            Paginas   = Get-Estadisticas ($ms | ForEach-Object { $_.Paginas })
            Gpu       = Get-Estadisticas ($ms | ForEach-Object { $_.Gpu })
            Discos    = @()
        }
        $nombres = @($ms | ForEach-Object { @($_.Discos) | ForEach-Object { "$($_.Disco)" } } | Select-Object -Unique)
        foreach ($n in $nombres) {
            $vals = @($ms | ForEach-Object { @($_.Discos) | Where-Object { "$($_.Disco)" -eq $n } })
            $num = if ($n -match '^(\d+)') { [int]$Matches[1] } else { -1 }
            $disco = @($D.Discos | Where-Object { [int](Get-Num $_.Numero -2) -eq $num }) | Select-Object -First 1
            $st.Discos += [pscustomobject]@{
                Nombre   = $n; Numero = $num
                Tipo     = if ($disco) { $disco.Tipo } else { '' }
                EsHDD    = [bool]($disco -and $disco.EsHDD)
                Inactivo = Get-Estadisticas ($vals | ForEach-Object { $_.Inactivo })
                LatMs    = Get-Estadisticas ($vals | ForEach-Object { $_.LatMs })
                Cola     = Get-Estadisticas ($vals | ForEach-Object { $_.Cola })
            }
        }
        $c.Muestreo = [pscustomobject]$st
    }

    # Temperaturas
    $temps = @($D.Temperaturas | Where-Object { $_ })
    $c.TempCpu = (@($temps | Where-Object { $_.Componente -eq 'CPU' } | ForEach-Object { [math]::Max((Get-Num $_.Valor), (Get-Num $_.Max)) }) | Measure-Object -Maximum).Maximum
    $c.TempGpu = (@($temps | Where-Object { $_.Componente -eq 'GPU' } | ForEach-Object { [math]::Max((Get-Num $_.Valor), (Get-Num $_.Max)) }) | Measure-Object -Maximum).Maximum
    $c.TempAcpi = (@($temps | Where-Object { $_.Fuente -eq 'ACPI' } | ForEach-Object { Get-Num $_.Valor }) | Measure-Object -Maximum).Maximum

    # Antigüedad aproximada (fecha de BIOS)
    $c.AniosEquipo = $null
    if ($s.FechaBIOS) { try { $c.AniosEquipo = [math]::Round(((Get-Date) - [datetime]$s.FechaBIOS).TotalDays / 365, 1) } catch { } }
    return [pscustomobject]$c
}

function Find-JuegoCatalogo($J) {
    if (-not $script:Catalogo) { return $null }
    $exe = "$($J.Exe)"
    $carpeta = if ($J.Ruta) { Split-Path "$($J.Ruta)" -Leaf } else { '' }
    foreach ($g in @($script:Catalogo.juegos)) {
        if ($J.AppId -and @($g.steam) -contains [int]$J.AppId) { return $g }
    }
    foreach ($g in @($script:Catalogo.juegos)) {
        foreach ($p in @($g.patrones)) {
            $re = ConvertTo-Patron $p
            if ("$($J.Nombre)" -match $re -or ($carpeta -and $carpeta -match $re) -or ($exe -and $exe -match $re)) { return $g }
        }
    }
    return $null
}

function Get-AnalisisJuegos($D, $Ctx) {
    $out = @()
    foreach ($j in @($D.Juegos | Where-Object { $_ })) {
        $req = Find-JuegoCatalogo $j
        $disco = Get-DiscoDeUnidad $D "$($j.Unidad)"
        $tipoDisco = if ($disco) { $disco.Tipo } else { 'Desconocido' }
        $bajoMin = @(); $bajoRec = @(); $notas = @()
        if ($req) {
            $gpu = Get-Num $Ctx.GpuIndice -1
            $cpu = Get-Num $Ctx.CpuIndice -1
            $vram = if ($Ctx.Gpu -and -not $Ctx.Gpu.Integrada) { Get-Num $Ctx.Gpu.VramGB -1 } else { -1 }
            if ($gpu -ge 0) { if ($gpu -lt $req.min.gpu) { $bajoMin += 'GPU' } elseif ($gpu -lt $req.rec.gpu) { $bajoRec += 'GPU' } }
            if ($cpu -ge 0) { if ($cpu -lt $req.min.cpu) { $bajoMin += 'CPU' } elseif ($cpu -lt $req.rec.cpu) { $bajoRec += 'CPU' } }
            if ($Ctx.RamGB -gt 0) {
                $ramEf = $Ctx.RamCmp   # RAM instalada: los requisitos se refieren a ella
                if ($ramEf -lt $req.min.ram) { $bajoMin += 'RAM' } elseif ($ramEf -lt $req.rec.ram) { $bajoRec += 'RAM' }
            }
            if ($vram -gt 0 -and $req.min.vram) { if ($vram + 0.3 -lt $req.min.vram) { $bajoMin += 'VRAM' } elseif ($req.rec.vram -and $vram + 0.3 -lt $req.rec.vram) { $bajoRec += 'VRAM' } }
            if ($req.ssd -eq 'requerido' -and $disco -and $disco.EsHDD) { $bajoMin += 'Disco (requiere SSD)' }
            elseif ($req.ssd -eq 'recomendado' -and $disco -and $disco.EsHDD) { $bajoRec += 'Disco (SSD recomendado)' }
            if ($req.nota) { $notas += "$($req.nota)" }
        }
        if (-not $req) { $estado = 'Sin datos'; $nivel = 'info' }
        elseif ($bajoMin.Count) { $estado = 'Por debajo del mínimo'; $nivel = 'alto' }
        elseif ($bajoRec.Count) { $estado = 'Jugable en calidad baja/media'; $nivel = 'medio' }
        else { $estado = 'Cumple lo recomendado'; $nivel = 'ok' }
        $out += [pscustomobject][ordered]@{
            Nombre = "$($j.Nombre)"; Tienda = "$($j.Tienda)"; Unidad = "$($j.Unidad)"; TipoDisco = $tipoDisco
            EnHDD = [bool]($disco -and $disco.EsHDD); TamanoGB = $j.TamanoGB; Catalogo = if ($req) { $req.nombre } else { '' }
            RequiereSSD = [bool]($req -and $req.ssd -eq 'requerido'); Estado = $estado; Nivel = $nivel
            BajoMinimo = @($bajoMin); BajoRecomendado = @($bajoRec); Notas = @($notas)
            MinGpu = if ($req) { $req.min.gpu } else { $null }; RecGpu = if ($req) { $req.rec.gpu } else { $null }
            MinCpu = if ($req) { $req.min.cpu } else { $null }; RecCpu = if ($req) { $req.rec.cpu } else { $null }
            MinRam = if ($req) { $req.min.ram } else { $null }; RecRam = if ($req) { $req.rec.ram } else { $null }
        }
    }
    return @($out)
}

function Invoke-Reglas($D, $Ctx, $Juegos) {
    $script:ListaHallazgos.Clear()
    $s = $D.Sistema
    $ev = $D.Eventos
    $m = $Ctx.Muestreo

    # ------------------------------------------------ GPU / driver
    foreach ($g in @($Ctx.Gpus | Where-Object { $_.SinDriver })) {
        New-Hallazgo -Id 'GPU-SIN-DRIVER' -Categoria 'Gráficos' -Severidad 'critico' -Confianza 'Alta' `
            -Titulo 'La tarjeta gráfica funciona sin su driver' `
            -Observacion @("Windows usa '$($g.Nombre)', el adaptador genérico.") `
            -Hipotesis 'Sin el driver del fabricante no hay aceleración 3D real: los juegos van muy lentos o no abren.' `
            -Prueba 'Administrador de dispositivos > Adaptadores de pantalla: si solo aparece el adaptador básico, falta el driver.' `
            -Solucion @('Descarga el driver desde la web de NVIDIA, AMD o Intel (o del fabricante del portátil) e instálalo.', 'También puedes probar Windows Update > Opciones avanzadas > Actualizaciones opcionales.') `
            -Reparacion 'actualizaciones'
    }
    foreach ($g in @($Ctx.Gpus | Where-Object { -not $_.SinDriver -and $_.FechaDriver })) {
        try {
            $meses = [math]::Round(((Get-Date) - [datetime]$g.FechaDriver).TotalDays / 30)
            if ($meses -ge 18 -and -not $g.Integrada) {
                New-Hallazgo -Id 'GPU-DRIVER-ANTIGUO' -Categoria 'Gráficos' -Severidad 'bajo' -Confianza 'Media' `
                    -Titulo "Driver de la tarjeta gráfica con $meses meses" `
                    -Observacion @("$($g.Nombre): driver del $(Format-Fecha $g.FechaDriver).") `
                    -Hipotesis 'Los juegos recientes suelen traer correcciones de rendimiento y fallos en drivers nuevos.' `
                    -Prueba 'Compara tu versión con la última publicada por el fabricante.' `
                    -Solucion @('Actualiza el driver desde la web oficial del fabricante. Si un driver nuevo da problemas, vuelve al anterior desde el Administrador de dispositivos.')
            }
        } catch { }
    }
    if ($Ctx.TieneHibrida -and $Ctx.EsPortatil) {
        New-Hallazgo -Id 'GPU-HIBRIDA' -Categoria 'Gráficos' -Severidad 'info' -Confianza 'Media' `
            -Titulo 'Portátil con dos tarjetas gráficas' `
            -Observacion @("Gráficas detectadas: $(($Ctx.Gpus | ForEach-Object { $_.Nombre }) -join ' + ').") `
            -Hipotesis 'Si un juego arranca con la gráfica integrada en lugar de la dedicada, rinde mucho menos.' `
            -Prueba 'Abre el juego y mira en el Administrador de tareas > Rendimiento qué GPU se activa.' `
            -Solucion @('Configuración > Sistema > Pantalla > Gráficos: añade el .exe del juego y elige "Alto rendimiento".', 'Juega con el cargador conectado: con batería la gráfica dedicada se limita.') `
            -Reparacion 'graficos'
    }

    # ------------------------------------------------ RAM
    $ramEf = $Ctx.RamCmp
    if ($Ctx.RamGB -gt 0 -and $ramEf -lt 6) {
        New-Hallazgo -Id 'RAM-MUY-POCA' -Categoria 'Memoria' -Severidad 'critico' -Confianza 'Alta' `
            -Titulo "Solo $($Ctx.RamTexto) de RAM" `
            -Observacion @("RAM utilizable: $($Ctx.RamGB) GB.", 'Windows 10/11 ya ocupa 2-3 GB solo con el sistema y el navegador.') `
            -Hipotesis 'Con tan poca memoria Windows usa el disco como RAM (paginación) y todo se vuelve lento.' `
            -Prueba 'Administrador de tareas > Rendimiento > Memoria: si "En uso" supera el 85 % con poco abierto, falta RAM.' `
            -Solucion @('Ampliar a 8 GB como mínimo (16 GB para juegos actuales).', 'Mientras tanto: cierra el navegador al jugar y reduce los programas de inicio.') `
            -Coste 'Compra' -Reparacion 'inicio'
    }
    elseif ($Ctx.RamGB -gt 0 -and $ramEf -lt 12) {
        $exigen16 = @($Juegos | Where-Object { $_.MinRam -ge 12 -or $_.RecRam -ge 16 } | ForEach-Object { $_.Nombre })
        if ($exigen16.Count -gt 0 -or ($m -and $m.ModoJuego)) {
            New-Hallazgo -Id 'RAM-8GB' -Categoria 'Memoria' -Severidad 'medio' -Confianza 'Media' `
                -Titulo "$($Ctx.RamTexto) de RAM se quedan cortos para juegos actuales" `
                -Observacion @("RAM utilizable: $($Ctx.RamGB) GB.", $(if ($exigen16.Count) { "Juegos que recomiendan 16 GB: $($exigen16 -join ', ')." } else { '' })) `
                -Hipotesis 'Al quedarse sin memoria aparecen tirones, cargas largas y cierres del juego.' `
                -Prueba 'Ejecuta Doctor PC en modo juego: si la RAM libre baja de 500 MB durante la partida, la RAM es un límite real.' `
                -Solucion @('Ampliar a 16 GB (idealmente 2 módulos iguales en doble canal).', 'Cierra el navegador y Discord mientras juegas.') `
                -Coste 'Compra'
        }
    }
    if ($Ctx.RamModulos -eq 1 -and -not $Ctx.RamSoldada) {
        $sev = if ($Ctx.SoloIntegrada) { 'alto' } else { 'medio' }
        $libre = if ($null -ne $Ctx.RamLibres) { "Ranuras libres: $($Ctx.RamLibres) de $($Ctx.RamRanuras)." } else { 'No se pudo leer el número de ranuras.' }
        New-Hallazgo -Id 'RAM-CANAL-SIMPLE' -Categoria 'Memoria' -Severidad $sev -Confianza 'Alta' `
            -Titulo 'La RAM funciona en canal simple (un solo módulo)' `
            -Observacion @("1 módulo de $($Ctx.RamModuloGB) GB $($Ctx.RamTipo).", $libre) `
            -Hipotesis $(if ($Ctx.SoloIntegrada) { 'Con gráficos integrados, el canal simple puede reducir los FPS entre un 20 y un 40 %: la gráfica usa la RAM como memoria de vídeo.' } else { 'El canal simple reduce el ancho de banda de memoria; en juegos que dependen del procesador se pierden FPS y aparecen tirones.' }) `
            -Prueba 'En CPU-Z (pestaña Memory) verás "Channel #: Single".' `
            -Solucion @("Añade un segundo módulo igual: $($Ctx.RamModuloGB) GB $($Ctx.RamTipo) $($Ctx.RamFormato) a $($Ctx.RamMHz) MHz.", 'Colócalo en la ranura del otro canal (mira el manual: suelen ser A2 y B2).') `
            -Coste 'Compra'
    }
    elseif ($Ctx.RamCanal -like 'Simple (*') {
        New-Hallazgo -Id 'RAM-MISMO-CANAL' -Categoria 'Memoria' -Severidad 'medio' -Confianza 'Baja' `
            -Titulo 'Los módulos de RAM podrían estar en el mismo canal' `
            -Observacion @("Ranuras usadas: $((@($D.Ram.Modulos) | ForEach-Object { $_.Ranura }) -join ', ').") `
            -Hipotesis 'Si los dos módulos están en el mismo canal, la memoria funciona como canal simple.' `
            -Prueba 'Comprueba en CPU-Z (Memory > Channel #) si dice "Dual".' `
            -Solucion @('Mueve un módulo a la ranura del otro canal según el manual de la placa (con el PC apagado y desenchufado).')
    }
    if ($Ctx.RamBajoVelocidad) {
        $mod = @($D.Ram.Modulos)[0]
        New-Hallazgo -Id 'RAM-XMP' -Categoria 'Memoria' -Severidad 'medio' -Confianza 'Media' `
            -Titulo 'La RAM funciona por debajo de su velocidad nominal' `
            -Observacion @("Velocidad nominal: $($mod.MHz) MHz; velocidad actual: $($mod.MHzActual) MHz.") `
            -Hipotesis 'El perfil XMP/DOCP/EXPO no está activado en la BIOS.' `
            -Prueba 'Entra en la BIOS y busca "XMP", "DOCP" o "EXPO".' `
            -Solucion @('Activa el perfil XMP/DOCP/EXPO en la BIOS.', 'Si después aparecen pantallazos azules, desactívalo: algunos módulos o placas no lo soportan bien.')
    }
    if ($Ctx.RamTamanosMixtos) {
        New-Hallazgo -Id 'RAM-MIXTA' -Categoria 'Memoria' -Severidad 'info' -Confianza 'Media' `
            -Titulo 'Módulos de RAM de distinto tamaño' `
            -Observacion @("Módulos: $((@($D.Ram.Modulos) | ForEach-Object { "$($_.CapacidadGB) GB" }) -join ' + ').") `
            -Hipotesis 'Funcionan en modo flexible: solo una parte de la memoria trabaja en doble canal.' `
            -Prueba 'No es un fallo; solo afecta algo al rendimiento.' `
            -Solucion @('Si en el futuro amplías, usa módulos iguales.')
    }
    $pp = Get-Num $s.PaginacionMB
    if ($s.PaginacionAuto -eq $false -and $pp -le 0 -and $Ctx.RamGB -le 16) {
        New-Hallazgo -Id 'RAM-SIN-PAGINACION' -Categoria 'Memoria' -Severidad 'medio' -Confianza 'Alta' `
            -Titulo 'El archivo de paginación está desactivado' `
            -Observacion @("RAM: $($Ctx.RamGB) GB y sin archivo de paginación.") `
            -Hipotesis 'Muchos juegos se cierran sin aviso cuando se acaba la memoria si no hay paginación.' `
            -Prueba 'Sistema > Configuración avanzada > Rendimiento > Opciones avanzadas > Memoria virtual.' `
            -Solucion @('Activa "Administrar automáticamente el tamaño del archivo de paginación".')
    }
    if ((Get-Num $ev.MemoriaVirtualBaja) -gt 0) {
        New-Hallazgo -Id 'RAM-AGOTADA' -Categoria 'Memoria' -Severidad $(if ((Get-Num $ev.MemoriaVirtualBaja) -ge 3) { 'alto' } else { 'medio' }) -Confianza 'Alta' `
            -Titulo 'Windows se quedó sin memoria' `
            -Observacion @("Avisos de memoria virtual baja en los últimos $($ev.Dias) días: $($ev.MemoriaVirtualBaja).") `
            -Hipotesis 'Algún programa o juego consumió toda la memoria disponible.' `
            -Prueba 'Revisa en el Administrador de tareas qué proceso usa más memoria cuando ocurre.' `
            -Solucion @('Cierra programas en segundo plano al jugar.', 'Mantén la paginación automática activada.', 'Si se repite con frecuencia, amplía la RAM.')
    }

    # ------------------------------------------------ Discos
    if ($Ctx.SistemaEnHDD) {
        New-Hallazgo -Id 'DISCO-SISTEMA-HDD' -Categoria 'Almacenamiento' -Severidad 'alto' -Confianza 'Alta' `
            -Titulo 'Windows está instalado en un disco mecánico (HDD)' `
            -Observacion @("Disco del sistema: $($Ctx.DiscoSistema.Modelo) ($($Ctx.DiscoSistema.Tipo)).") `
            -Hipotesis 'Un HDD es entre 50 y 100 veces más lento en accesos aleatorios que un SSD: arranque lento, programas que tardan en abrir y Windows Update eterno.' `
            -Prueba 'Administrador de tareas > Rendimiento > Disco: si marca 100 % con frecuencia sin hacer nada pesado, el disco es el cuello de botella.' `
            -Solucion @('Pasar Windows a un SSD es la mejora más barata y la que más se nota en un PC lento.', 'Puedes clonar el disco (Macrium Reflect Free, Clonezilla) o instalar Windows limpio en el SSD y usar el HDD para archivos.') `
            -Coste 'Compra'
    }
    if ($null -ne $Ctx.SysLibreGB -and $Ctx.SysTamanoGB -gt 0) {
        $pct = [math]::Round($Ctx.SysLibreGB / $Ctx.SysTamanoGB * 100)
        if ($Ctx.SysLibreGB -lt 10 -or $pct -lt 8) { $sev = 'alto' } elseif ($Ctx.SysLibreGB -lt 25 -or $pct -lt 15) { $sev = 'medio' } else { $sev = '' }
        if ($sev) {
            New-Hallazgo -Id 'DISCO-LLENO' -Categoria 'Almacenamiento' -Severidad $sev -Confianza 'Alta' `
                -Titulo "Poco espacio libre en $($Ctx.SysLetra)" `
                -Observacion @("Libre: $($Ctx.SysLibreGB) GB de $($Ctx.SysTamanoGB) GB ($pct %).") `
                -Hipotesis 'Sin espacio, Windows no puede actualizarse ni ampliar la paginación, y los juegos fallan al guardar o actualizar.' `
                -Prueba 'Configuración > Sistema > Almacenamiento muestra qué ocupa más.' `
                -Solucion @('Usa el Liberador de espacio en disco (incluye "Limpiar archivos del sistema").', 'Activa el Sensor de almacenamiento.', 'Mueve juegos o descargas a otro disco.') `
                -Reparacion 'liberador'
        }
    }
    foreach ($dk in @($D.Discos)) {
        $probs = @()
        if ($dk.Salud -and $dk.Salud -notmatch 'Healthy|OK|Correcto|^0$') { $probs += "Estado de salud: $($dk.Salud)." }
        if ((Get-Num $dk.ErroresLectura) -gt 0) { $probs += "Errores de lectura no corregidos: $($dk.ErroresLectura)." }
        if (@($ev.DiscosConError) -contains [int](Get-Num $dk.Numero -9)) { $probs += 'Windows registró errores de E/S o bloques dañados en este disco.' }
        if ($probs.Count) {
            New-Hallazgo -Id "DISCO-SALUD-$($dk.Numero)" -Categoria 'Almacenamiento' -Severidad 'critico' -Confianza 'Alta' `
                -Titulo "El disco $($dk.Modelo) muestra señales de fallo" `
                -Observacion $probs `
                -Hipotesis 'El disco puede estar degradándose: riesgo de perder datos, cuelgues y archivos dañados.' `
                -Prueba 'Comprueba los atributos SMART con CrystalDiskInfo (Reallocated, Pending, Uncorrectable).' `
                -Solucion @('Haz una copia de seguridad de tus archivos importantes HOY.', 'Si es el disco del sistema, sustitúyelo por un SSD y clona o reinstala.', 'Revisa también el cable SATA (cámbialo si es posible).') `
                -Coste 'Compra' -Reparacion 'chkdsk'
        }
        if ($dk.EsSSD -and (Get-Num $dk.DesgastePct) -ge 80) {
            New-Hallazgo -Id "DISCO-DESGASTE-$($dk.Numero)" -Categoria 'Almacenamiento' -Severidad 'medio' -Confianza 'Media' `
                -Titulo "SSD con $($dk.DesgastePct) % de desgaste" -Observacion @("$($dk.Modelo): desgaste $($dk.DesgastePct) %.") `
                -Hipotesis 'El SSD se acerca al final de su vida útil estimada.' -Prueba 'Confírmalo con CrystalDiskInfo.' `
                -Solucion @('Mantén copias de seguridad y planifica su sustitución.') -Coste 'Compra'
        }
        $tmax = if ($dk.EsHDD) { 55 } else { 70 }
        if ((Get-Num $dk.TempC) -ge $tmax) {
            New-Hallazgo -Id "DISCO-TEMP-$($dk.Numero)" -Categoria 'Temperatura' -Severidad 'medio' -Confianza 'Media' `
                -Titulo "Disco caliente: $($dk.TempC) °C" -Observacion @("$($dk.Modelo) a $($dk.TempC) °C.") `
                -Hipotesis 'Poca ventilación en la caja o el disco trabaja sin pausa.' -Prueba 'Vigila la temperatura tras una sesión de uso normal.' `
                -Solucion @('Mejora el flujo de aire o separa el disco de otras fuentes de calor.')
        }
    }
    if (@($D.FalloPredicho).Count -gt 0) {
        New-Hallazgo -Id 'DISCO-SMART' -Categoria 'Almacenamiento' -Severidad 'critico' -Confianza 'Alta' `
            -Titulo 'SMART predice el fallo de un disco' `
            -Observacion @("Unidad(es) con aviso SMART: $((@($D.FalloPredicho)) -join ', ').") `
            -Hipotesis 'El propio disco informa de que es probable que falle pronto.' `
            -Prueba 'Revisa cuál es con CrystalDiskInfo (aparecerá en amarillo o rojo).' `
            -Solucion @('Copia de seguridad inmediata de tus archivos.', 'Sustituye el disco.') -Coste 'Compra'
    }
    if ((Get-Num $ev.ReiniciosControladorDisco) -gt 3) {
        New-Hallazgo -Id 'DISCO-CONTROLADOR' -Categoria 'Almacenamiento' -Severidad 'medio' -Confianza 'Media' `
            -Titulo 'El controlador del disco se reinicia' `
            -Observacion @("Reinicios del controlador (evento 129) en $($ev.Dias) días: $($ev.ReiniciosControladorDisco).") `
            -Hipotesis 'Cable SATA defectuoso, puerto con problemas, firmware del SSD o modo de ahorro de energía agresivo.' `
            -Prueba 'Coincide con congelamientos de varios segundos.' `
            -Solucion @('Cambia el cable SATA o el puerto.', 'Actualiza el firmware del SSD desde la herramienta del fabricante.')
    }
    if ((Get-Num $ev.ErroresNtfs) -gt 0) {
        New-Hallazgo -Id 'DISCO-NTFS' -Categoria 'Almacenamiento' -Severidad 'medio' -Confianza 'Media' `
            -Titulo 'Errores en el sistema de archivos' -Observacion @("Errores NTFS en $($ev.Dias) días: $($ev.ErroresNtfs).") `
            -Hipotesis 'Apagados bruscos o un disco con problemas dañaron la estructura de archivos.' `
            -Prueba 'Ejecuta una comprobación de disco en modo solo lectura.' `
            -Solucion @('Usa la reparación guiada "Revisar disco".') -Reparacion 'chkdsk'
    }

    # Juegos en HDD
    $enHDD = @($Juegos | Where-Object { $_.EnHDD })
    if ($enHDD.Count -gt 0) {
        $req = @($enHDD | Where-Object { $_.RequiereSSD })
        $libreSSD = 0
        foreach ($dk in @($D.Discos | Where-Object { $_.EsSSD -and -not $_.Externo })) { foreach ($v in @($dk.Volumenes)) { $libreSSD = [math]::Max($libreSSD, (Get-Num $v.LibreGB)) } }
        $caben = @($enHDD | Where-Object { (Get-Num $_.TamanoGB 999) + 10 -lt $libreSSD } | Sort-Object { -[int]$_.RequiereSSD }, { Get-Num $_.TamanoGB })
        $sev = if ($req.Count) { 'alto' } else { 'medio' }
        $sol = @()
        if ($caben.Count) { $sol += "Tienes $([math]::Round($libreSSD)) GB libres en un SSD: mueve allí $(($caben | Select-Object -First 3 | ForEach-Object { $_.Nombre }) -join ', ') (gratis)." }
        $sol += 'En Steam: clic derecho en el juego > Propiedades > Archivos instalados > Mover carpeta de instalación.'
        $sol += 'En Epic, Xbox o juegos de carpeta: desinstala y reinstala en el SSD, o mueve la carpeta y vuelve a vincularla desde el lanzador.'
        New-Hallazgo -Id 'JUEGOS-EN-HDD' -Categoria 'Juegos' -Severidad $sev -Confianza $(if ($req.Count) { 'Alta' } else { 'Media' }) `
            -Titulo "$($enHDD.Count) juego(s) instalados en un disco mecánico" `
            -Observacion @("En HDD: $(($enHDD | ForEach-Object { $_.Nombre }) -join ', ').", $(if ($req.Count) { "Requieren SSD oficialmente: $(($req | ForEach-Object { $_.Nombre }) -join ', ')." } else { '' })) `
            -Hipotesis 'Los juegos de mundo abierto cargan texturas mientras juegas; en un HDD eso provoca cargas largas, texturas que aparecen tarde y tirones. No siempre es la causa: hay que confirmarlo.' `
            -Prueba 'Ejecuta Doctor PC en modo juego: si el disco del juego está ocupado casi al 100 % justo en los tirones, el HDD es el culpable.' `
            -Solucion $sol -Coste $(if ($caben.Count) { 'Gratis' } else { 'Compra' })
    }

    # ------------------------------------------------ CPU / energía / temperatura
    if ($s.PlanEnergiaGuid -eq 'a1841308-3541-4fab-bc81-f71556f20b4a') {
        New-Hallazgo -Id 'ENERGIA-AHORRO' -Categoria 'Energía' -Severidad 'medio' -Confianza 'Alta' `
            -Titulo 'Plan de energía "Economizador" activo' -Observacion @("Plan activo: $($s.PlanEnergia).") `
            -Hipotesis 'El plan de ahorro limita la frecuencia del procesador.' `
            -Prueba 'Compara el rendimiento con el plan Equilibrado.' `
            -Solucion @('Cambia al plan Equilibrado (o Alto rendimiento en sobremesa).') -Reparacion 'energia'
    }
    if ($s.Bateria -and -not $s.Bateria.Conectado) {
        New-Hallazgo -Id 'ENERGIA-BATERIA' -Categoria 'Energía' -Severidad 'info' -Confianza 'Alta' `
            -Titulo 'El análisis se hizo con el portátil usando batería' -Observacion @("Carga: $($s.Bateria.Carga) %.") `
            -Hipotesis 'Con batería, CPU y GPU se limitan para ahorrar energía; las mediciones salen peores.' `
            -Prueba 'Repite el análisis con el cargador conectado.' -Solucion @('Juega siempre con el cargador conectado.')
    }
    if ($s.Bateria -and $s.Bateria.SaludPct -and $s.Bateria.SaludPct -lt 60) {
        New-Hallazgo -Id 'BATERIA-DESGASTADA' -Categoria 'Energía' -Severidad 'bajo' -Confianza 'Media' `
            -Titulo "La batería conserva el $($s.Bateria.SaludPct) % de su capacidad" -Observacion @("Capacidad actual frente a la de fábrica: $($s.Bateria.SaludPct) %.") `
            -Hipotesis 'Batería desgastada: dura poco y, en algunos portátiles, limita el rendimiento.' `
            -Prueba 'Genera un informe con: powercfg /batteryreport' -Solucion @('Sustituir la batería si la autonomía es importante para ti.') -Coste 'Compra'
    }
    $tCpu = Get-Num $Ctx.TempCpu; $tGpu = Get-Num $Ctx.TempGpu; $tAcpi = Get-Num $Ctx.TempAcpi
    if ($tCpu -ge 90 -or $tGpu -ge 87) {
        New-Hallazgo -Id 'TEMP-ALTA' -Categoria 'Temperatura' -Severidad 'alto' -Confianza 'Alta' `
            -Titulo 'Temperaturas muy altas' `
            -Observacion @($(if ($tCpu) { "CPU: hasta $tCpu °C." } else { '' }), $(if ($tGpu) { "GPU: hasta $tGpu °C." } else { '' })) `
            -Hipotesis 'Polvo, pasta térmica seca o ventiladores que no giran. El procesador baja su velocidad para protegerse (thermal throttling).' `
            -Prueba 'Vigila la temperatura con HWiNFO mientras juegas; si sube a 90-100 °C y bajan los FPS, es throttling.' `
            -Solucion @('Limpia el polvo de disipadores y ventiladores.', 'Cambia la pasta térmica si el equipo tiene más de 3-4 años.', 'En portátiles: base elevada y rejillas despejadas.') `
            -Coste 'Mantenimiento'
    }
    elseif ($tAcpi -ge 85) {
        New-Hallazgo -Id 'TEMP-ACPI' -Categoria 'Temperatura' -Severidad 'medio' -Confianza 'Baja' `
            -Titulo "Zona térmica a $tAcpi °C" -Observacion @("Sensor ACPI: $tAcpi °C (es un sensor aproximado).") `
            -Hipotesis 'Posible calentamiento del equipo.' `
            -Prueba 'Confirma con LibreHardwareMonitor o HWiNFO (sensores reales del CPU).' `
            -Solucion @('Si se confirma: limpieza y pasta térmica.') -Coste 'Mantenimiento'
    }
    if (@($D.Temperaturas).Count -eq 0) {
        New-Hallazgo -Id 'TEMP-SIN-SENSORES' -Categoria 'Temperatura' -Severidad 'info' -Confianza 'Alta' `
            -Titulo 'No se pudieron leer temperaturas del procesador' `
            -Observacion @('Windows no expone sensores de CPU/GPU sin herramientas adicionales.') `
            -Hipotesis 'Sin temperaturas no se puede descartar el sobrecalentamiento.' `
            -Prueba 'Abre LibreHardwareMonitor (gratuito) antes de ejecutar Doctor PC: Doctor PC leerá sus sensores automáticamente.' `
            -Solucion @('Descarga LibreHardwareMonitor desde su página oficial en GitHub, ábrelo como administrador y vuelve a ejecutar Doctor PC.')
    }

    # ------------------------------------------------ Muestreo
    if ($m) {
        $sysDisk = @($m.Discos | Where-Object { $Ctx.DiscoSistema -and $_.Numero -eq [int](Get-Num $Ctx.DiscoSistema.Numero -9) }) | Select-Object -First 1
        $topCpu = @($D.Muestreo.TopCpu | Where-Object { (Get-Num $_.Cpu) -ge 5 })
        $explica = @()
        foreach ($p in ($topCpu + @($D.Muestreo.TopRam | Select-Object -First 3))) {
            if ($script:ProcesosConocidos.ContainsKey("$($p.Nombre)")) { $explica += "$($p.Nombre): $($script:ProcesosConocidos["$($p.Nombre)"])" }
        }
        $explica = @($explica | Select-Object -Unique)
        $listaCpu = ($topCpu | Select-Object -First 4 | ForEach-Object { "$($_.Nombre) ($($_.Cpu) %)" }) -join ', '

        if (-not $m.ModoJuego) {
            if ((Get-Num $m.Cpu.Prom) -ge 50) {
                New-Hallazgo -Id 'CPU-ALTA-REPOSO' -Categoria 'Rendimiento' -Severidad 'medio' -Confianza 'Media' `
                    -Titulo "Procesador ocupado sin jugar (media $($m.Cpu.Prom) %)" `
                    -Observacion (@("Uso medio de CPU durante $($D.Muestreo.Segundos) s: $($m.Cpu.Prom) %.", "Procesos: $listaCpu.") + $explica) `
                    -Hipotesis 'Una tarea en segundo plano (actualización, antivirus, indexado) o un programa innecesario consume el procesador.' `
                    -Prueba 'Repite el análisis en 30 minutos: si el uso sigue alto con los mismos procesos, no es temporal.' `
                    -Solucion @('Deja terminar Windows Update y los análisis del antivirus.', 'Desinstala o desactiva del inicio lo que no uses.', 'Si un proceso desconocido usa mucho CPU, analízalo con tu antivirus.') `
                    -Reparacion 'inicio'
            }
            $ramTotalMB = $Ctx.RamGB * 1024
            if ($ramTotalMB -gt 0 -and (Get-Num $m.RamLibre.Min) -gt 0 -and (Get-Num $m.RamLibre.Min) -lt [math]::Max(600, $ramTotalMB * 0.12)) {
                New-Hallazgo -Id 'RAM-LLENA-REPOSO' -Categoria 'Rendimiento' -Severidad 'medio' -Confianza 'Media' `
                    -Titulo 'La memoria está casi llena antes de abrir un juego' `
                    -Observacion @("RAM libre mínima: $($m.RamLibre.Min) MB de $([math]::Round($ramTotalMB)) MB.", "Mayores consumidores: $(($D.Muestreo.TopRam | Select-Object -First 4 | ForEach-Object { "$($_.Nombre) ($($_.RamMB) MB)" }) -join ', ').") `
                    -Hipotesis 'Al abrir un juego, Windows tendrá que usar el disco como memoria: tirones y cargas largas.' `
                    -Prueba 'Cierra el navegador y vuelve a mirar la RAM libre en el Administrador de tareas.' `
                    -Solucion @('Cierra navegador, Discord y lanzadores que no uses antes de jugar.', 'Reduce los programas que arrancan con Windows.') -Reparacion 'inicio'
            }
            if ($sysDisk -and (Get-Num $sysDisk.Inactivo.Prom 100) -lt 40) {
                New-Hallazgo -Id 'DISCO-OCUPADO-REPOSO' -Categoria 'Rendimiento' -Severidad $(if ($sysDisk.EsHDD) { 'alto' } else { 'medio' }) -Confianza 'Media' `
                    -Titulo 'El disco del sistema está muy ocupado sin hacer nada pesado' `
                    -Observacion (@("Disco $($sysDisk.Nombre) ($($sysDisk.Tipo)) activo el $([math]::Round(100 - $sysDisk.Inactivo.Prom)) % del tiempo; latencia p95: $($sysDisk.LatMs.P95) ms.") + $explica) `
                    -Hipotesis $(if ($sysDisk.EsHDD) { 'Típico de un HDD con Windows 10/11: actualizaciones, antivirus e indexado saturan el disco y todo se vuelve lento.' } else { 'Una tarea en segundo plano está leyendo o escribiendo mucho.' }) `
                    -Prueba 'Administrador de tareas > Procesos: ordena por "Disco" para ver quién lo usa.' `
                    -Solucion @('Reduce los programas de inicio y deja terminar las actualizaciones o análisis en curso.', $(if ($sysDisk.EsHDD) { 'Solución definitiva: pasar Windows a un SSD.' } else { '' })) `
                    -Reparacion 'inicio'
            }
        }
        else {
            $juegoProc = @($D.Muestreo.TopGpu)[0]
            $nomJuego = if ($juegoProc) { "$($juegoProc.Nombre)" } else { 'el juego' }
            $gpuP = Get-Num $m.Gpu.Prom -1; $cpuP = Get-Num $m.Cpu.Prom; $nucP = Get-Num $m.NucleoMax.Prom
            $obsBase = @("Medición de $($D.Muestreo.Segundos) s con $nomJuego en marcha.", "GPU media: $($m.Gpu.Prom) %; CPU media: $cpuP %; núcleo más cargado: $nucP %; RAM libre mínima: $($m.RamLibre.Min) MB.")
            if ($gpuP -ge 90) {
                New-Hallazgo -Id 'JUEGO-LIMITE-GPU' -Categoria 'Cuello de botella' -Severidad 'info' -Confianza 'Alta' `
                    -Titulo 'En la partida medida, la tarjeta gráfica trabaja al máximo' -Observacion $obsBase `
                    -Hipotesis 'Límite gráfico: es lo normal en juegos exigentes. El procesador no frena a la GPU.' `
                    -Prueba 'Baja la resolución: si los FPS suben claramente, se confirma el límite de GPU.' `
                    -Solucion @('Baja sombras, calidad de efectos y resolución de render.', 'Activa FSR, DLSS o XeSS en modo Calidad o Equilibrado.', 'Para ganar más FPS de forma permanente hay que mejorar la GPU (ver plan de mejora).')
            }
            elseif ($gpuP -ge 0 -and $gpuP -lt 75 -and ($cpuP -ge 85 -or $nucP -ge 95)) {
                New-Hallazgo -Id 'JUEGO-LIMITE-CPU' -Categoria 'Cuello de botella' -Severidad 'alto' -Confianza 'Media' `
                    -Titulo 'En la partida medida, el procesador limita al juego' -Observacion ($obsBase + @("Procesos que más CPU usan: $listaCpu.")) `
                    -Hipotesis 'La GPU espera al procesador: bajar gráficos casi no mejorará los FPS.' `
                    -Prueba 'Baja la resolución: si los FPS NO cambian, se confirma el límite de CPU.' `
                    -Solucion @('Cierra todo lo que no sea el juego (navegador, grabación, RGB).', 'Baja ajustes que cargan la CPU: distancia de visión, densidad de multitudes, física.', 'Limita los FPS a un valor estable (por ejemplo 60) para reducir tirones.', 'Si se confirma siempre, mejora el procesador (ver plan de mejora).')
            }
            if ($juegoProc -and $juegoProc.Unidad) {
                $dj = Get-DiscoDeUnidad $D "$($juegoProc.Unidad)"
                $dm = if ($dj) { @($m.Discos | Where-Object { $_.Numero -eq [int](Get-Num $dj.Numero -9) }) | Select-Object -First 1 } else { $null }
                if ($dm -and ((Get-Num $dm.Inactivo.Min 100) -lt 10 -or (Get-Num $dm.LatMs.P95) -gt 60)) {
                    New-Hallazgo -Id 'JUEGO-LIMITE-DISCO' -Categoria 'Cuello de botella' -Severidad $(if ($dj.EsHDD) { 'alto' } else { 'medio' }) -Confianza 'Media' `
                        -Titulo "El disco del juego se satura durante la partida ($($dj.Tipo))" `
                        -Observacion ($obsBase + @("Disco $($dm.Nombre): inactivo mínimo $($dm.Inactivo.Min) %, latencia p95 $($dm.LatMs.P95) ms.")) `
                        -Hipotesis 'Los tirones coinciden con el disco al límite: el juego espera datos del almacenamiento.' `
                        -Prueba 'Compara los tirones antes y después de mover el juego a un SSD.' `
                        -Solucion @('Mueve el juego a un SSD.', 'Desactiva el desfragmentado programado y los análisis del antivirus durante la partida.')
                }
            }
            if ((Get-Num $m.RamLibre.Min 99999) -lt 500 -or (Get-Num $m.Commit.Max) -ge 92 -or (Get-Num $m.Paginas.Prom) -ge 500) {
                New-Hallazgo -Id 'JUEGO-LIMITE-RAM' -Categoria 'Cuello de botella' -Severidad 'alto' -Confianza 'Media' `
                    -Titulo 'La memoria RAM se agota durante la partida' `
                    -Observacion ($obsBase + @("Memoria comprometida máxima: $($m.Commit.Max) %; páginas/s media: $($m.Paginas.Prom).")) `
                    -Hipotesis 'Windows mueve datos al disco porque no caben en la RAM: tirones y cargas largas.' `
                    -Prueba 'Repite cerrando el navegador: si mejora, la RAM es el límite.' `
                    -Solucion @('Cierra programas en segundo plano.', 'Amplía la RAM (ver plan de mejora).')
            }
            if ($cpuP -ge 40 -and (Get-Num $m.CpuPerf.Prom 100) -gt 0 -and (Get-Num $m.CpuPerf.Prom 100) -lt 65) {
                New-Hallazgo -Id 'JUEGO-THROTTLING' -Categoria 'Temperatura' -Severidad 'medio' -Confianza 'Baja' `
                    -Titulo 'El procesador trabaja por debajo de su velocidad bajo carga' `
                    -Observacion ($obsBase + @("Rendimiento del procesador medio: $($m.CpuPerf.Prom) % de su velocidad base.")) `
                    -Hipotesis 'Posible limitación térmica (calor) o energética (plan de ahorro, batería, límites del fabricante).' `
                    -Prueba 'Mide la temperatura con HWiNFO mientras juegas.' `
                    -Solucion @('Limpieza y pasta térmica.', 'Plan de energía Equilibrado o Alto rendimiento.', 'En portátiles: cargador conectado y modo rendimiento del fabricante.') `
                    -Reparacion 'energia' -Coste 'Mantenimiento'
            }
        }
    }

    # ------------------------------------------------ Windows: eventos y estabilidad
    $ka = [int](Get-Num $ev.ApagadosInesperados)
    if ($ka -gt 0) {
        $sev = if ($ka -ge 3) { 'alto' } else { 'medio' }
        New-Hallazgo -Id 'WIN-APAGADOS' -Categoria 'Estabilidad' -Severidad $sev -Confianza 'Media' `
            -Titulo "$ka apagado(s) o reinicio(s) inesperado(s) en $($ev.Dias) días" `
            -Observacion @("Evento Kernel-Power 41. Últimos: $((@($ev.FechasApagados) | Select-Object -First 3) -join '; ').") `
            -Hipotesis 'Cortes de luz, botón de encendido, fuente de alimentación débil o defectuosa, sobrecalentamiento o pantallazos azules.' `
            -Prueba '¿Coinciden con cortes de luz o con momentos de mucha carga (jugando)? Si es jugando, sospecha de la fuente o la temperatura.' `
            -Solucion @('Si hay cortes o variaciones de luz: un regulador de voltaje o un UPS protege el equipo.', 'Si ocurre al jugar: revisa temperaturas y la potencia real de la fuente.', 'Si coinciden con pantallazos azules: mira el hallazgo correspondiente.')
    }
    $pz = @($ev.Pantallazos)
    if ($pz.Count -gt 0) {
        $codigos = @($pz | Group-Object { $_.Codigo } | Sort-Object Count -Descending)
        $obs = @("Pantallazos azules en $($ev.Dias) días: $($pz.Count).")
        foreach ($g in $codigos | Select-Object -First 4) {
            $desc = if ($script:CodigosPantallazo.ContainsKey($g.Name)) { $script:CodigosPantallazo[$g.Name] } else { 'Código no catalogado.' }
            $obs += "$($g.Name) x$($g.Count): $desc"
        }
        $sol = @()
        $todos = ($codigos | ForEach-Object { $_.Name }) -join ' '
        if ($todos -match '0x0000001A|0x00000050|0x00000139|0x00000019|0x0000000A') { $sol += 'Prueba la RAM con el Diagnóstico de memoria de Windows; si usas XMP, desactívalo para probar.' }
        if ($todos -match '0x00000116|0x00000117') { $sol += 'Reinstala el driver de la tarjeta gráfica (limpio) y vigila su temperatura.' }
        if ($todos -match '0x000000EF|0x0000007A|0x000000F4') { $sol += 'Revisa el disco y su cable; luego repara los archivos de Windows (DISM + SFC).' }
        if ($todos -match '0x00000124') { $sol += 'Quita cualquier overclock, revisa temperaturas y la fuente de alimentación.' }
        $sol += 'Actualiza drivers de chipset, red y gráficos desde la web del fabricante.'
        $sol += 'Analiza los volcados en C:\Windows\Minidump con WinDbg o BlueScreenView para ver el driver culpable.'
        New-Hallazgo -Id 'WIN-PANTALLAZOS' -Categoria 'Estabilidad' -Severidad 'alto' -Confianza 'Media' `
            -Titulo 'Pantallazos azules recientes' -Observacion $obs `
            -Hipotesis 'El código de error orienta hacia la causa más probable (driver, RAM, disco o hardware).' `
            -Prueba 'Si el mismo código se repite, la causa suele ser la misma; si cambian, sospecha de RAM, fuente o temperatura.' `
            -Solucion $sol -Reparacion 'memoria'
    }
    if ((Get-Num $ev.ErroresWhea) -gt 0) {
        New-Hallazgo -Id 'WIN-WHEA' -Categoria 'Estabilidad' -Severidad $(if ((Get-Num $ev.WheaFatales) -gt 0) { 'alto' } else { 'medio' }) -Confianza 'Media' `
            -Titulo 'Errores de hardware registrados (WHEA)' `
            -Observacion @("Eventos WHEA en $($ev.Dias) días: $($ev.ErroresWhea) (graves: $($ev.WheaFatales)).") `
            -Hipotesis 'El propio hardware reporta errores: overclock o XMP inestable, temperatura, voltaje o un componente (CPU, RAM, PCIe) con fallos.' `
            -Prueba 'Revisa el Visor de eventos > Sistema > WHEA-Logger para ver el componente afectado.' `
            -Solucion @('Quita overclock y XMP para probar.', 'Revisa temperaturas.', 'Actualiza la BIOS si el fabricante publicó correcciones de estabilidad.')
    }
    if ((Get-Num $ev.ReiniciosDriverVideo) -gt 0) {
        New-Hallazgo -Id 'WIN-TDR' -Categoria 'Gráficos' -Severidad 'medio' -Confianza 'Media' `
            -Titulo 'El driver de vídeo dejó de responder y se reinició' `
            -Observacion @("Eventos Display 4101 en $($ev.Dias) días: $($ev.ReiniciosDriverVideo).") `
            -Hipotesis 'Driver gráfico inestable, GPU caliente, overclock o fuente que no da la potencia necesaria.' `
            -Prueba '¿Ocurre solo jugando? Vigila la temperatura de la GPU.' `
            -Solucion @('Reinstala el driver gráfico desde cero.', 'Limpia la tarjeta gráfica y revisa que los ventiladores giren.', 'Quita cualquier overclock de la GPU.')
    }
    $cierres = @($ev.CierresApps | Where-Object { (Get-Num $_.Veces) -ge 2 })
    if ($cierres.Count -gt 0) {
        $exesJuegos = @($D.Juegos | ForEach-Object { "$($_.Exe)".ToLower() } | Where-Object { $_ })
        $deJuegos = @($cierres | Where-Object { $exesJuegos -contains "$($_.App)".ToLower() })
        $lista = ($cierres | Select-Object -First 5 | ForEach-Object { "$($_.App) x$($_.Veces) (módulo: $($_.Modulo))" }) -join '; '
        New-Hallazgo -Id 'WIN-CIERRES' -Categoria 'Estabilidad' -Severidad $(if ($deJuegos.Count) { 'medio' } else { 'bajo' }) -Confianza 'Media' `
            -Titulo 'Programas que se cierran solos' -Observacion @("Cierres repetidos en $($ev.Dias) días: $lista.") `
            -Hipotesis 'El módulo que falla orienta la causa: d3d/dxgi/nvwgf/amdxx = gráficos; ntdll/KERNELBASE = genérico; ucrtbase/msvcp = librerías de Visual C++.' `
            -Prueba 'Mira si el cierre se repite con la misma acción en el programa.' `
            -Solucion @('Verifica la integridad de los archivos del juego desde su lanzador.', 'Instala o repara los paquetes Visual C++ Redistributable.', 'Actualiza el driver gráfico.')
    }
    $disp = @($D.Dispositivos | Where-Object { [int]$_.Codigo -ne 22 })
    if ($disp.Count -gt 0) {
        $obs = @($disp | Select-Object -First 6 | ForEach-Object {
            $desc = if ($script:CodigosDispositivo.ContainsKey([int]$_.Codigo)) { $script:CodigosDispositivo[[int]$_.Codigo] } else { 'Error' }
            "$($_.Nombre) - código $($_.Codigo): $desc"
        })
        New-Hallazgo -Id 'WIN-DISPOSITIVOS' -Categoria 'Drivers' -Severidad 'medio' -Confianza 'Alta' `
            -Titulo "$($disp.Count) dispositivo(s) con problemas de driver" -Observacion $obs `
            -Hipotesis 'Falta el driver o falla: puede afectar al sonido, red, USB o rendimiento.' `
            -Prueba 'Administrador de dispositivos: aparecen con un triángulo amarillo.' `
            -Solucion @('Instala los drivers del chipset y de la placa/portátil desde la web del fabricante.', 'Windows Update > Opciones avanzadas > Actualizaciones opcionales.') -Reparacion 'actualizaciones'
    }
    $inicio = @($D.Inicio | Where-Object { $_.Activo })
    if ($inicio.Count -ge 10) {
        New-Hallazgo -Id 'WIN-INICIO' -Categoria 'Rendimiento' -Severidad $(if ($inicio.Count -ge 18) { 'medio' } else { 'bajo' }) -Confianza 'Media' `
            -Titulo "$($inicio.Count) programas arrancan con Windows" `
            -Observacion @("Ejemplos: $(($inicio | Select-Object -First 8 | ForEach-Object { $_.Nombre }) -join ', ').") `
            -Hipotesis 'Cada programa de inicio alarga el arranque y consume RAM y CPU en segundo plano.' `
            -Prueba 'Administrador de tareas > Aplicaciones de arranque muestra el impacto de cada uno.' `
            -Solucion @('Desactiva los que no necesitas al encender (lanzadores de juegos, actualizadores, mensajería). No desactives el antivirus ni los drivers de audio/táctil.') `
            -Reparacion 'inicio'
    }
    $avActivos = @($s.Antivirus | Where-Object { $_.Activo -and "$($_.Nombre)" -notmatch 'Windows Defender|Microsoft Defender' })
    if ($avActivos.Count -ge 2) {
        New-Hallazgo -Id 'WIN-VARIOS-AV' -Categoria 'Rendimiento' -Severidad 'medio' -Confianza 'Alta' `
            -Titulo 'Hay varios antivirus activos a la vez' -Observacion @("Activos: $(($avActivos | ForEach-Object { $_.Nombre }) -join ', ').") `
            -Hipotesis 'Dos antivirus analizan cada archivo dos veces y pueden chocar entre sí: lentitud y bloqueos.' `
            -Prueba 'Desinstala uno y compara.' -Solucion @('Deja solo uno. Microsoft Defender es suficiente para la mayoría.')
    }
    if ((Get-Num $s.UptimeDias) -ge 7) {
        $nota = if ($s.InicioRapido -eq 1) { ' Con el "Inicio rápido" activo, apagar no reinicia Windows por completo: usa "Reiniciar".' } else { '' }
        New-Hallazgo -Id 'WIN-UPTIME' -Categoria 'Mantenimiento' -Severidad 'bajo' -Confianza 'Alta' `
            -Titulo "Windows lleva $($s.UptimeDias) días sin reiniciarse" -Observacion @("Último arranque hace $($s.UptimeDias) días.$nota") `
            -Hipotesis 'Fugas de memoria y actualizaciones pendientes se acumulan.' -Prueba 'Reinicia y compara.' `
            -Solucion @('Usa "Reiniciar" (no "Apagar") al menos una vez por semana.')
    }
    elseif ($s.ReinicioPendiente) {
        New-Hallazgo -Id 'WIN-REINICIO-PENDIENTE' -Categoria 'Mantenimiento' -Severidad 'bajo' -Confianza 'Alta' `
            -Titulo 'Hay un reinicio pendiente de Windows Update' -Observacion @('Windows espera un reinicio para terminar actualizaciones.') `
            -Hipotesis 'Mientras no reinicies, las actualizaciones siguen a medias y consumen recursos.' -Prueba '-' `
            -Solucion @('Reinicia el equipo cuando puedas.')
    }
    if ($s.Windows -match 'Windows 10' -and [int](Get-Num $s.Build) -lt 22000) {
        New-Hallazgo -Id 'WIN10-SOPORTE' -Categoria 'Seguridad' -Severidad 'info' -Confianza 'Alta' `
            -Titulo 'Windows 10 ya no recibe actualizaciones gratuitas' `
            -Observacion @("Sistema: $($s.Windows) $($s.VersionWindows).", 'El soporte general terminó el 14 de octubre de 2025.') `
            -Hipotesis 'Sin parches de seguridad el riesgo aumenta con el tiempo; algunos juegos y antitrampas nuevos dejarán de funcionar.' `
            -Prueba 'Usa la app "Comprobación de estado del PC" para saber si tu equipo admite Windows 11.' `
            -Solucion @('Si es compatible, actualiza a Windows 11.', 'Si no, mantén navegador y antivirus al día y valora las opciones de actualizaciones extendidas (ESU).')
    }
    $integridad = ($pz.Count -gt 0) -or ((Get-Num $ev.ErroresNtfs) -gt 0) -or ($cierres.Count -ge 3)
    if ($integridad) {
        New-Hallazgo -Id 'WIN-INTEGRIDAD' -Categoria 'Reparación' -Severidad 'bajo' -Confianza 'Baja' `
            -Titulo 'Conviene comprobar la integridad de Windows' `
            -Observacion @('Hay síntomas compatibles con archivos de sistema dañados (pantallazos, errores de disco o cierres repetidos).') `
            -Hipotesis 'Si algún archivo de Windows está dañado, DISM y SFC lo detectan y lo restauran desde copias oficiales.' `
            -Prueba 'SFC indicará si encontró y reparó archivos.' `
            -Solucion @('Ejecuta la reparación guiada "DISM + SFC" (no borra tus archivos; tarda 15-40 min).') -Reparacion 'dism_sfc'
    }

    # ------------------------------------------------ Juegos por requisitos
    $bajoMin = @($Juegos | Where-Object { $_.Nivel -eq 'alto' })
    if ($bajoMin.Count -gt 0) {
        $obs = @($bajoMin | Select-Object -First 8 | ForEach-Object { "$($_.Nombre): limita $($_.BajoMinimo -join ', ')" })
        $comp = @($bajoMin | ForEach-Object { $_.BajoMinimo } | Group-Object | Sort-Object Count -Descending | ForEach-Object { $_.Name })
        New-Hallazgo -Id 'JUEGOS-BAJO-MINIMO' -Categoria 'Juegos' -Severidad 'medio' -Confianza 'Media' `
            -Titulo "$($bajoMin.Count) juego(s) por debajo de los requisitos mínimos" -Observacion $obs `
            -Hipotesis "El componente que más se repite es: $($comp[0]). Mejorarlo es lo que más ayuda a estos juegos." `
            -Prueba 'Los índices son aproximados: confirma con la ficha oficial y con el modo juego de Doctor PC.' `
            -Solucion @('Usa el preset gráfico más bajo, resolución de render al 70-80 % y escalado FSR si está disponible.', 'Consulta el plan de mejora para el componente limitante.')
    }

    # ------------------------------------------------ Cuello de botella por especificaciones
    $gi = Get-Num $Ctx.GpuIndice -1; $ci = Get-Num $Ctx.CpuIndice -1
    if ($gi -gt 0 -and $ci -gt 0 -and -not $Ctx.SoloIntegrada) {
        $ratio = $gi / $ci
        if ($ratio -ge 2.0) {
            New-Hallazgo -Id 'BALANCE-CPU' -Categoria 'Cuello de botella' -Severidad 'bajo' -Confianza 'Baja' `
                -Titulo 'La tarjeta gráfica es mucho más potente que el procesador' `
                -Observacion @("Índice GPU: $gi; índice CPU: $ci (relación $([math]::Round($ratio, 1)):1).") `
                -Hipotesis 'En juegos competitivos y de mundo abierto el procesador probablemente limitará los FPS. Es una hipótesis por especificaciones, no una medición.' `
                -Prueba 'Ejecuta Doctor PC con -ModoJuego 120 mientras juegas para confirmarlo.' `
                -Solucion @('Aprovecha la GPU subiendo resolución o calidad: el coste en FPS será bajo.', 'Si se confirma el límite, mejora el procesador (ver plan de mejora).')
        }
        elseif ($ratio -le 0.45) {
            New-Hallazgo -Id 'BALANCE-GPU' -Categoria 'Cuello de botella' -Severidad 'bajo' -Confianza 'Baja' `
                -Titulo 'El procesador es mucho más potente que la tarjeta gráfica' `
                -Observacion @("Índice GPU: $gi; índice CPU: $ci.") `
                -Hipotesis 'En casi todos los juegos la GPU será el límite. Es una hipótesis por especificaciones.' `
                -Prueba 'Ejecuta Doctor PC con -ModoJuego 120 mientras juegas.' `
                -Solucion @('La mejora con más impacto en juegos sería la tarjeta gráfica (ver plan de mejora).')
        }
    }
    if ($Ctx.SoloIntegrada -and @($Juegos).Count -gt 0) {
        New-Hallazgo -Id 'GPU-INTEGRADA' -Categoria 'Gráficos' -Severidad 'medio' -Confianza 'Alta' `
            -Titulo 'El equipo solo tiene gráficos integrados' `
            -Observacion @("Gráficos: $(($Ctx.Gpus | ForEach-Object { $_.Nombre }) -join ', ').") `
            -Hipotesis 'Los gráficos integrados comparten la RAM y tienen poca potencia: limitan casi todos los juegos 3D.' `
            -Prueba 'Mira la tabla de juegos de este informe.' `
            -Solucion @('Gratis: preset bajo, 720p o escalado FSR, y RAM en doble canal.', $(if ($Ctx.EsPortatil) { 'En portátiles la gráfica no se puede cambiar: prioriza RAM en doble canal y SSD.' } else { 'En sobremesa, una tarjeta gráfica dedicada es la mejora más grande para jugar.' }))
    }

    # Orden por severidad
    $orden = @{ critico = 0; alto = 1; medio = 2; bajo = 3; info = 4 }
    return @($script:ListaHallazgos | Sort-Object { $orden[$_.Severidad] }, { $_.Categoria })
}

function Get-PuntuacionSalud($Hallazgos) {
    $pen = 0
    foreach ($h in $Hallazgos) {
        switch ($h.Severidad) { 'critico' { $pen += 30 } 'alto' { $pen += 12 } 'medio' { $pen += 5 } 'bajo' { $pen += 1.5 } }
    }
    $p = [int][math]::Round(100 * [math]::Exp(-$pen / 75))
    if (@($Hallazgos | Where-Object { $_.Severidad -eq 'critico' }).Count -gt 0) { $p = [math]::Min($p, 45) }
    $et = if ($p -ge 85) { 'Buena' } elseif ($p -ge 65) { 'Mejorable' } elseif ($p -ge 40) { 'Con problemas' } else { 'Necesita atención' }
    [pscustomobject]@{ Puntos = $p; Etiqueta = $et }
}

# =====================================================================
#  PLAN DE MEJORA
# =====================================================================

function Get-PrecioOpcion($Op, [bool]$Usados) {
    $usado = $null; $nuevo = $null
    if ($Op.usado) { $usado = @($Op.usado) }
    if ($Op.nuevo) { $nuevo = @($Op.nuevo) }
    $f = Get-Num $script:PaisInfo.factor 1
    if ($Usados -and $usado) { $r = $usado; $estado = 'usado' }
    elseif ($nuevo) { $r = $nuevo; $estado = 'nuevo' }
    elseif ($usado) { $r = $usado; $estado = 'usado (no hay nuevo)' }
    else { return $null }
    $min = [math]::Round((Get-Num $r[0]) * $f); $max = [math]::Round((Get-Num $r[1]) * $f)
    [pscustomobject]@{ Min = $min; Max = $max; Medio = [math]::Round(($min + $max) / 2); Estado = $estado }
}

function Format-Precio($P) {
    if (-not $P) { return 'Sin precio de referencia' }
    $t = "US`$$($P.Min)-$($P.Max)"
    $tasa = Get-Num $script:PaisInfo.tasa_usd 1
    $mon = "$($script:PaisInfo.moneda)"
    if ($mon -and $mon -ne 'USD' -and $tasa -gt 0) {
        $paso = if ($tasa -ge 100) { 100 } elseif ($tasa -ge 10) { 10 } else { 1 }
        $a = [math]::Round($P.Min * $tasa / $paso) * $paso; $b = [math]::Round($P.Max * $tasa / $paso) * $paso
        $t += (" (~{0:N0}-{1:N0} {2})" -f $a, $b, $mon)
    }
    return $t
}

function New-PlanMejora($D, $Ctx, $Juegos, $Hallazgos, [double]$Presupuesto, [bool]$Usados) {
    $cand = New-Object System.Collections.ArrayList
    $bloq = New-Object System.Collections.ArrayList
    $Tabla = $script:Precios

    # Gratis: hallazgos que se resuelven sin comprar
    $gratis = @($Hallazgos | Where-Object { $_.Coste -eq 'Gratis' -and $_.Severidad -in @('critico', 'alto', 'medio', 'bajo') } | Select-Object -First 8 | ForEach-Object { [pscustomobject]@{ Titulo = $_.Titulo; Accion = @($_.Solucion)[0]; Severidad = $_.Severidad; Reparacion = $_.Reparacion } })

    if (-not $Tabla) { return [pscustomobject]@{ Gratis = $gratis; Dentro = @(); Fuera = @(); Bloqueadas = @(); Total = 0; Presupuesto = $Presupuesto; Notas = @('Falta datos\precios.json: no se pueden estimar compras.') } }

    $maxMinGpu = Get-Num (@($Juegos | ForEach-Object { Get-Num $_.MinGpu }) | Measure-Object -Maximum).Maximum
    $maxRecGpu = Get-Num (@($Juegos | ForEach-Object { Get-Num $_.RecGpu }) | Measure-Object -Maximum).Maximum
    $maxMinCpu = Get-Num (@($Juegos | ForEach-Object { Get-Num $_.MinCpu }) | Measure-Object -Maximum).Maximum
    $maxRecCpu = Get-Num (@($Juegos | ForEach-Object { Get-Num $_.RecCpu }) | Measure-Object -Maximum).Maximum
    $ramRec = Get-Num (@($Juegos | ForEach-Object { Get-Num $_.RecRam }) | Measure-Object -Maximum).Maximum
    $gi = Get-Num $Ctx.GpuIndice 0; $ci = Get-Num $Ctx.CpuIndice 0
    $limCpuMedido = @($Hallazgos | Where-Object { $_.Id -eq 'JUEGO-LIMITE-CPU' }).Count -gt 0
    $limRamMedido = @($Hallazgos | Where-Object { $_.Id -in @('JUEGO-LIMITE-RAM', 'RAM-AGOTADA', 'RAM-LLENA-REPOSO') }).Count -gt 0

    $add = {
        param($Cat, $Nombre, $Precio, [int]$Impacto, $Motivo, $Compat)
        if (-not $Precio) { return }
        [void]$cand.Add([pscustomobject]@{ Categoria = $Cat; Nombre = $Nombre; Precio = $Precio; Impacto = $Impacto; Motivo = $Motivo; Compatibilidad = @($Compat | Where-Object { $_ }); Puntuacion = [math]::Round($Impacto * 10 / ($Precio.Medio + 10), 2) })
    }

    # ---- SSD para Windows
    if ($Ctx.SistemaEnHDD) {
        $usado = Get-Num $Ctx.SysUsadoGB 150
        if ($Ctx.EsPortatil) { $necesario = [math]::Max(200, $usado * 1.15 + 20) }      # una sola bahía: tiene que caber todo
        elseif ($usado -le 150) { $necesario = 200 }
        else { $necesario = 450 }                                                       # Windows + programas; el HDD sigue para juegos y archivos
        $op = @($Tabla.ssd | Where-Object { $_.interfaz -eq 'SATA' -and $_.gb -ge $necesario } | Sort-Object { $_.gb }) | Select-Object -First 1
        if (-not $op) { $op = @($Tabla.ssd | Where-Object { $_.interfaz -eq 'SATA' } | Sort-Object { $_.gb } -Descending) | Select-Object -First 1 }
        $compat = @()
        if ($Ctx.EsPortatil) { $compat += 'Portátil: sustituye al HDD de 2,5" (mismo tamaño). Clona el disco o reinstala Windows.' }
        else {
            $compat += 'Sobremesa: necesitas un puerto SATA libre y un cable SATA de datos; la alimentación sale de la fuente.'
            if ($usado -gt 150) { $compat += "Instala Windows y programas en el SSD y deja el HDD actual como segundo disco para juegos grandes y archivos (hoy ocupas $([math]::Round($usado)) GB)." }
        }
        if ($Ctx.CpuPlataforma -match 'LGA1151|LGA1200|LGA1700|AM4|AM5|LGA1851') { $compat += 'Tu plataforma suele tener ranura M.2: si la tiene, un SSD NVMe cuesta parecido y es más rápido (revisa el manual).' }
        if ($Ctx.EsPortatil) { $compat += "Capacidad elegida para que quepa lo que ocupa hoy $($Ctx.SysLetra) ($([math]::Round($usado)) GB)." }
        & $add 'SSD' $op.nombre (Get-PrecioOpcion $op $Usados) 9 'Windows en HDD: es la mejora que más se nota en el uso diario (arranque, programas, actualizaciones).' $compat
    }
    else {
        $enHDD = @($Juegos | Where-Object { $_.EnHDD })
        $libreSSD = 0
        foreach ($dk in @($D.Discos | Where-Object { $_.EsSSD -and -not $_.Externo })) { foreach ($v in @($dk.Volumenes)) { $libreSSD = [math]::Max($libreSSD, (Get-Num $v.LibreGB)) } }
        $tamHDD = (@($enHDD | ForEach-Object { Get-Num $_.TamanoGB 40 }) | Measure-Object -Sum).Sum
        if ($enHDD.Count -gt 0 -and $tamHDD + 20 -gt $libreSSD) {
            $op = @($Tabla.ssd | Where-Object { $_.gb -ge [math]::Max(450, $tamHDD * 1.2) } | Sort-Object { (Get-Num @($_.nuevo)[0]) }) | Select-Object -First 1
            if (-not $op) { $op = @($Tabla.ssd | Sort-Object { $_.gb } -Descending) | Select-Object -First 1 }
            $imp = if (@($enHDD | Where-Object { $_.RequiereSSD }).Count) { 8 } else { 6 }
            & $add 'SSD' "$($op.nombre) para juegos" (Get-PrecioOpcion $op $Usados) $imp "Juegos en HDD: $(($enHDD | Select-Object -First 4 | ForEach-Object { $_.Nombre }) -join ', ')." @('Comprueba si tu placa tiene ranura M.2 libre o un puerto SATA libre.')
        }
    }

    # ---- RAM
    $tipo = $Ctx.RamTipo
    $necesitaRam = ($Ctx.RamCmp -lt 8) -or ($Ctx.RamModulos -eq 1) -or (($Ctx.RamCmp -lt 16) -and ($ramRec -ge 16 -or $limRamMedido))
    if ($necesitaRam) {
        if ($Ctx.RamSoldada) { [void]$bloq.Add([pscustomobject]@{ Nombre = 'Ampliar RAM'; Motivo = "La memoria es $tipo (soldada a la placa): no se puede ampliar." }) }
        elseif ($tipo -notin @('DDR3', 'DDR4', 'DDR5')) { [void]$bloq.Add([pscustomobject]@{ Nombre = 'Ampliar RAM'; Motivo = "Memoria ${tipo}: plataforma demasiado antigua para invertir en ella." }) }
        else {
            $modGB = [int]$Ctx.RamModuloGB; $compat = @(); $nombre = ''; $precio = $null
            $libres = $Ctx.RamLibres
            $objetivo = if ($Ctx.RamCmp -lt 8) { 8 } else { 16 }
            if ($Ctx.RamModulos -eq 1 -and ($null -eq $libres -or $libres -ge 1)) {
                # Añadir un módulo igual -> doble canal
                $o = @($Tabla.ram | Where-Object { $_.tipo -eq $tipo -and $_.gb -eq $modGB }) | Select-Object -First 1
                if ($o) {
                    $nombre = "1 módulo $modGB GB $tipo $($Ctx.RamFormato) $($Ctx.RamMHz) MHz (igual al actual)"
                    $precio = Get-PrecioOpcion $o $Usados
                    $compat += "Total resultante: $($modGB * 2) GB en doble canal."
                    if ($Ctx.RamCmp + $modGB -lt $objetivo) {
                        $o2 = @($Tabla.ram | Where-Object { $_.tipo -eq $tipo -and $_.gb -ge ($objetivo / 2) } | Sort-Object { $_.gb }) | Select-Object -First 1
                        if ($o2) { $compat += "Para llegar a $objetivo GB habría que usar 2 módulos de $($o2.gb) GB." }
                    }
                }
            }
            else {
                $o = @($Tabla.ram | Where-Object { $_.tipo -eq $tipo -and $_.gb -ge ($objetivo / 2) } | Sort-Object { $_.gb }) | Select-Object -First 1
                if ($o) {
                    $pp = Get-PrecioOpcion $o $Usados
                    if ($pp) { $precio = [pscustomobject]@{ Min = $pp.Min * 2; Max = $pp.Max * 2; Medio = $pp.Medio * 2; Estado = $pp.Estado } }
                    if ($null -ne $libres -and $libres -ge 2) { $nombre = "Kit 2x$($o.gb) GB $tipo $($Ctx.RamFormato) (añadir en las ranuras libres)" ; $compat += "Total resultante: $([math]::Round($Ctx.RamGB + 2 * $o.gb)) GB." }
                    else { $nombre = "Kit 2x$($o.gb) GB $tipo $($Ctx.RamFormato) (sustituye a los actuales)"; $compat += "Total resultante: $(2 * $o.gb) GB. Puedes vender los módulos actuales." }
                }
            }
            if ($nombre -and $precio) {
                if ($Ctx.RamMaxGB -gt 0 -and $Ctx.RamMaxGB -lt 512) { $compat += "Máximo que admite la placa según el BIOS: $($Ctx.RamMaxGB) GB." }
                $compat += "Busca la misma velocidad ($($Ctx.RamMHz) MHz) o superior; funcionará a la del módulo más lento."
                if ($Ctx.EsPortatil) { $compat += 'Portátil: formato SODIMM. Comprueba que haya una ranura libre (algunos tienen memoria soldada + 1 ranura).' }
                $imp = 5
                if ($Ctx.RamCmp -lt 8) { $imp = 9 } elseif ($Ctx.RamModulos -eq 1 -and $Ctx.SoloIntegrada) { $imp = 8 } elseif ($limRamMedido) { $imp = 8 } elseif ($ramRec -ge 16 -and $Ctx.RamCmp -lt 16) { $imp = 7 } elseif ($Ctx.RamModulos -eq 1) { $imp = 6 }
                $motivo = if ($Ctx.RamModulos -eq 1) { 'Activa el doble canal y amplía la memoria.' } else { "Amplía a $objetivo GB." }
                & $add 'RAM' $nombre $precio $imp $motivo $compat
            }
        }
    }

    # ---- GPU
    $necGpu = (-not $Ctx.HaySinDriver) -and (($Ctx.SoloIntegrada -and @($Juegos).Count -gt 0) -or ($gi -gt 0 -and $maxMinGpu -gt 0 -and $gi -lt $maxMinGpu) -or ($gi -gt 0 -and $maxRecGpu -gt 0 -and $gi -lt $maxRecGpu * 0.8))
    if ($necGpu) {
        if ($Ctx.EsPortatil) { [void]$bloq.Add([pscustomobject]@{ Nombre = 'Cambiar tarjeta gráfica'; Motivo = 'En portátiles la gráfica va soldada a la placa: no se puede cambiar.' }) }
        else {
            $objetivo = [math]::Max(($gi * 1.6), [math]::Max($maxMinGpu, 60))
            $ops = @($Tabla.gpu | Where-Object { (Get-Num $_.indice) -ge $objetivo })
            if ($script:FuenteW -gt 0) { $ops = @($ops | Where-Object { (Get-Num $_.fuente_w) -le $script:FuenteW }) }
            elseif ($Ctx.EsOEM) {
                $sinConector = @($ops | Where-Object { $_.conector -eq 'ninguno' })
                if ($sinConector.Count) { $ops = $sinConector }
            }
            $op = @($ops | Sort-Object { $p = Get-PrecioOpcion $_ $Usados; if ($p) { $p.Medio } else { 99999 } }) | Select-Object -First 1
            if ($op) {
                $compat = @()
                $compat += "Rendimiento aproximado: índice $($op.indice) frente a $gi actual (x$([math]::Round($op.indice / [math]::Max(1, $gi), 1)))."
                if ($op.conector -eq 'ninguno') { if (-not $op.nota) { $compat += 'No necesita conector de la fuente: válida para PC de marca con fuente pequeña.' } }
                else { $compat += "Necesita una fuente de al menos $($op.fuente_w) W reales con conector PCIe $($op.conector). $(if ($script:FuenteW -gt 0) { "Indicaste $($script:FuenteW) W." } else { 'Revisa la etiqueta de tu fuente (no se puede leer por software).' })" }
                if ($Ctx.EsOEM -and $op.conector -ne 'ninguno') { $compat += 'Los PC de marca suelen traer fuentes de 180-300 W sin conector PCIe: probablemente habría que cambiar la fuente.' }
                if ($ci -gt 0 -and $op.indice / $ci -ge 2.2) { $compat += "Tu procesador (índice $ci) limitará parte del rendimiento de esta GPU." }
                if ($op.nota) { $compat += "$($op.nota)" }
                $imp = if ($Ctx.SoloIntegrada) { 9 } elseif ($gi -lt $maxMinGpu) { 8 } else { 6 }
                & $add 'GPU' $op.nombre (Get-PrecioOpcion $op $Usados) $imp $(if ($Ctx.SoloIntegrada) { 'Pasar de gráficos integrados a una tarjeta dedicada.' } else { 'La tarjeta gráfica actual limita los juegos detectados.' }) $compat
            }
        }
    }

    # ---- CPU
    $necCpu = ($ci -gt 0) -and (($maxMinCpu -gt 0 -and $ci -lt $maxMinCpu) -or ($maxRecCpu -gt 0 -and $ci -lt $maxRecCpu * 0.75) -or $limCpuMedido -or ($gi -gt 0 -and -not $Ctx.SoloIntegrada -and $ci -lt $gi * 0.55))
    if ($necCpu) {
        if ($Ctx.CpuPortatil) { [void]$bloq.Add([pscustomobject]@{ Nombre = 'Cambiar procesador'; Motivo = 'En portátiles el procesador va soldado: no se puede cambiar.' }) }
        elseif (-not $Ctx.CpuPlataforma) { [void]$bloq.Add([pscustomobject]@{ Nombre = 'Cambiar procesador'; Motivo = 'No se pudo determinar el socket de la placa: consulta el modelo de placa antes de comprar.' }) }
        else {
            $lista = @()
            $prop = $Tabla.cpu.PSObject.Properties[$Ctx.CpuPlataforma]
            if ($prop) { $lista = @($prop.Value) }
            $ops = @($lista | Where-Object { (Get-Num $_.indice) -ge $ci * 1.25 })
            $op = @($ops | Sort-Object { $p = Get-PrecioOpcion $_ $Usados; if ($p) { $p.Medio } else { 99999 } }) | Select-Object -First 1
            if ($op) {
                $compat = @("Mismo socket que tu procesador actual ($($Ctx.CpuPlataforma)): no hace falta cambiar placa ni RAM.", "Rendimiento aproximado: índice $($op.indice) frente a $ci actual.")
                if ($op.nota) { $compat += "$($op.nota)" }
                if ($op.nombre -match 'Xeon|F$|5500|5600|5700X3D|7500F|9400F|10400F|11400F|12400F|13400F' -and $Ctx.SoloIntegrada) { $compat += 'ATENCIÓN: este procesador no tiene gráficos integrados y tú no tienes tarjeta gráfica dedicada.' }
                if ($Ctx.EsOEM) { $compat += 'PC de marca: el fabricante a veces limita los procesadores admitidos por BIOS. Busca "<modelo de tu PC> CPU support list".' }
                $compat += 'Necesitarás pasta térmica nueva al cambiarlo.'
                $imp = if ($limCpuMedido -or ($maxMinCpu -gt 0 -and $ci -lt $maxMinCpu)) { 7 } else { 5 }
                & $add 'CPU' $op.nombre (Get-PrecioOpcion $op $Usados) $imp 'El procesador limita los juegos detectados o a tu tarjeta gráfica.' $compat
            }
        }
    }

    # ---- Mantenimiento térmico
    $termico = @($Hallazgos | Where-Object { $_.Coste -eq 'Mantenimiento' }).Count -gt 0
    $viejo = (Get-Num $Ctx.AniosEquipo) -ge 4
    if (($termico -or $viejo) -and $Tabla.otros.pasta_termica) {
        $imp = if ($termico) { 7 } else { 3 }
        & $add 'Mantenimiento' $Tabla.otros.pasta_termica.nombre (Get-PrecioOpcion $Tabla.otros.pasta_termica $false) $imp $(if ($termico) { 'Hay indicios de temperatura alta o limitación térmica.' } else { "El equipo tiene unos $([math]::Round((Get-Num $Ctx.AniosEquipo))) años: el mantenimiento preventivo evita calentamientos." }) @('Hazlo con el equipo desenchufado. En portátiles, si no tienes experiencia, mejor un técnico.')
    }

    # ---- Ajuste al presupuesto (mayor beneficio por dólar primero)
    $orden = @($cand | Sort-Object { $_.Puntuacion } -Descending)
    $dentro = @(); $fuera = @(); $total = 0
    foreach ($c in $orden) {
        if ($Presupuesto -lt 0 -or ($total + $c.Precio.Medio) -le $Presupuesto) { $dentro += $c; $total += $c.Precio.Medio }
        else { $fuera += $c }
    }
    $notas = @()
    $notas += "Precios de referencia ($($Tabla.actualizado)) para $script:PaisNombre$(if ($Usados) { ', priorizando usados' } else { ', solo nuevos' }). Edita datos\precios.json con precios de tu zona."
    if ($script:PaisInfo.nota) { $notas += "$($script:PaisInfo.nota)" }
    if ($Presupuesto -ge 0 -and $dentro.Count -eq 0 -and $fuera.Count -gt 0) { $notas += "Con US`$$Presupuesto no alcanza para ninguna compra útil. La más barata con impacto real: $($fuera[0].Nombre) ($(Format-Precio $fuera[0].Precio))." }
    if ($Usados) { $notas += 'Al comprar usado: prueba el componente antes de pagar y pide fotos del modelo exacto.' }
    [pscustomobject]@{ Gratis = @($gratis); Dentro = @($dentro); Fuera = @($fuera); Bloqueadas = @($bloq); Total = $total; Presupuesto = $Presupuesto; Notas = $notas }
}

# =====================================================================
#  INFORMES
# =====================================================================

function ConvertTo-HtmlSeguro([string]$s) { [System.Net.WebUtility]::HtmlEncode($s) }

function New-Sparkline($Valores, [double]$Max = 100, [string]$Clase = 'l1') {
    $v = @($Valores | ForEach-Object { if ($null -eq $_ -or "$_" -eq '') { $null } else { [double]$_ } })
    if ($v.Count -lt 2) { return '<div class="nodata">Sin datos</div>' }
    $w = 300; $h = 56
    $pts = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $v.Count; $i++) {
        if ($null -eq $v[$i]) { continue }
        $x = [math]::Round($i * $w / ($v.Count - 1), 1)
        $y = [math]::Round($h - [math]::Min($Max, [math]::Max(0, $v[$i])) / $Max * ($h - 4) - 2, 1)
        [void]$pts.Add(('{0},{1}' -f $x.ToString($script:Inv), $y.ToString($script:Inv)))
    }
    return "<svg class=`"spark`" viewBox=`"0 0 $w $h`" preserveAspectRatio=`"none`" role=`"img`"><polyline class=`"$Clase`" points=`"$($pts -join ' ')`" /></svg>"
}

function Get-TextoResumen($D, $Ctx, $Hallazgos, $Plan, $Salud) {
    $s = $D.Sistema
    $l = New-Object System.Collections.ArrayList
    [void]$l.Add("DOCTOR PC - $($D.Equipo) - $(Format-Fecha $D.Fecha -Hora)")
    [void]$l.Add("Salud: $($Salud.Puntos)/100 ($($Salud.Etiqueta))")
    [void]$l.Add("Equipo: $($s.Fabricante) $($s.Modelo)$(if ($Ctx.EsPortatil) { ' (portátil)' })")
    [void]$l.Add("CPU: $($D.Cpu.Nombre) ($($D.Cpu.Nucleos)C/$($D.Cpu.Hilos)H)")
    [void]$l.Add("GPU: $(($Ctx.Gpus | ForEach-Object { "$($_.Nombre)$(if ($_.VramGB) { " $($_.VramGB) GB" })" }) -join ' + ')")
    [void]$l.Add("RAM: $($Ctx.RamTexto) $($Ctx.RamTipo) - $($Ctx.RamModulos) módulo(s), canal $($Ctx.RamCanal.ToLower())")
    if ($Ctx.DiscoSistema) { [void]$l.Add("Disco del sistema: $($Ctx.DiscoSistema.Tipo) $($Ctx.DiscoSistema.TamanoGB) GB ($($Ctx.SysLetra) libre: $($Ctx.SysLibreGB) GB)") }
    [void]$l.Add("Windows: $($s.Windows) $($s.VersionWindows) (build $($s.Build))")
    [void]$l.Add('')
    [void]$l.Add('Problemas principales:')
    $i = 1
    foreach ($h in @($Hallazgos | Where-Object { $_.Severidad -ne 'info' } | Select-Object -First 6)) { [void]$l.Add("$i. [$($h.Severidad.ToUpper())] $($h.Titulo)"); $i++ }
    if ($i -eq 1) { [void]$l.Add('- Ninguno importante.') }
    if (@($Plan.Dentro).Count) {
        [void]$l.Add('')
        $pres = if ($Plan.Presupuesto -ge 0) { " (presupuesto US`$$($Plan.Presupuesto))" } else { '' }
        [void]$l.Add("Mejoras sugeridas$($pres):")
        foreach ($c in @($Plan.Dentro)) { [void]$l.Add("- $($c.Nombre): $(Format-Precio $c.Precio)") }
    }
    return ($l -join "`n")
}

function New-InformeHtml($D, $Ctx, $Hallazgos, $Juegos, $Plan, $Salud, [string]$Resumen) {
    $Enc = { param($x) ConvertTo-HtmlSeguro "$x" }
    $sb = New-Object System.Text.StringBuilder
    $s = $D.Sistema
    $etSev = @{ critico = 'Crítico'; alto = 'Alto'; medio = 'Medio'; bajo = 'Bajo'; info = 'Info' }

    $css = @'
:root{--bg:#f6f7f9;--card:#fff;--tx:#1d2330;--mut:#5d6778;--bd:#e3e6ec;--acc:#1f6feb;--crit:#c62828;--alto:#e0661b;--medio:#b98900;--bajo:#2f7bbf;--info:#6b7685;--ok:#2e8b57;--sh:0 1px 2px rgba(0,0,0,.05)}
@media (prefers-color-scheme:dark){:root{--bg:#12151b;--card:#1b1f27;--tx:#e6e9ef;--mut:#9aa3b2;--bd:#2b313c;--acc:#5b9dff;--crit:#ff6b6b;--alto:#ff9a52;--medio:#e7c04a;--bajo:#6cb2ff;--info:#a0a9b8;--ok:#5cc48b;--sh:none}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--tx);font:15px/1.55 "Segoe UI",system-ui,-apple-system,Roboto,Arial,sans-serif}
.wrap{max-width:1080px;margin:0 auto;padding:24px 16px 60px}
header.top{display:flex;flex-wrap:wrap;gap:16px;align-items:center;justify-content:space-between;margin-bottom:8px}
h1{font-size:26px;margin:0;letter-spacing:-.3px}h1 span{color:var(--acc)}
h2{font-size:19px;margin:34px 0 12px;padding-bottom:6px;border-bottom:1px solid var(--bd)}
h3{font-size:15px;margin:0 0 6px}
.mut{color:var(--mut)}.small{font-size:13px}
nav{display:flex;flex-wrap:wrap;gap:6px;margin:14px 0 4px}nav a{font-size:13px;text-decoration:none;color:var(--tx);background:var(--card);border:1px solid var(--bd);padding:4px 10px;border-radius:999px}
.card{background:var(--card);border:1px solid var(--bd);border-radius:12px;padding:16px;box-shadow:var(--sh)}
.grid{display:grid;gap:12px;grid-template-columns:repeat(auto-fit,minmax(230px,1fr))}
.hero{display:grid;grid-template-columns:170px 1fr;gap:18px;align-items:center}
@media (max-width:640px){.hero{grid-template-columns:1fr}}
.ring{position:relative;width:150px;height:150px;margin:auto}.ring svg{transform:rotate(-90deg)}.ring .n{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center}.ring .n b{font-size:38px;line-height:1}.ring .n small{color:var(--mut)}
.kv{display:grid;grid-template-columns:max-content 1fr;gap:4px 14px;font-size:14px}.kv dt{color:var(--mut)}.kv dd{margin:0}
.badge{display:inline-block;font-size:11.5px;font-weight:600;padding:2px 8px;border-radius:999px;color:#fff;vertical-align:middle;white-space:nowrap}
.b-critico{background:var(--crit)}.b-alto{background:var(--alto)}.b-medio{background:var(--medio)}.b-bajo{background:var(--bajo)}.b-info{background:var(--info)}.b-ok{background:var(--ok)}
.chip{display:inline-block;font-size:12px;border:1px solid var(--bd);border-radius:6px;padding:1px 7px;color:var(--mut);margin-left:4px}
.find{border-left:5px solid var(--info);margin-bottom:12px}.find.critico{border-left-color:var(--crit)}.find.alto{border-left-color:var(--alto)}.find.medio{border-left-color:var(--medio)}.find.bajo{border-left-color:var(--bajo)}
.find summary{cursor:pointer;list-style:none;display:flex;gap:8px;align-items:center;flex-wrap:wrap}.find summary::-webkit-details-marker{display:none}
.find summary .t{font-weight:600;flex:1;min-width:200px}
.steps{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:10px;margin-top:12px}
.step{background:var(--bg);border-radius:8px;padding:10px 12px;font-size:14px}.step h4{margin:0 0 4px;font-size:12px;text-transform:uppercase;letter-spacing:.5px;color:var(--mut)}
.step ul{margin:0;padding-left:18px}
table{width:100%;border-collapse:collapse;font-size:14px}th,td{text-align:left;padding:7px 8px;border-bottom:1px solid var(--bd);vertical-align:top}th{font-size:12px;text-transform:uppercase;letter-spacing:.4px;color:var(--mut);font-weight:600}
.tw{overflow-x:auto}
.spark{width:100%;height:56px;display:block}.spark polyline{fill:none;stroke-width:2;vector-effect:non-scaling-stroke}.l1{stroke:var(--acc)}.l2{stroke:var(--alto)}.l3{stroke:var(--ok)}.l4{stroke:var(--medio)}
.metric b{font-size:22px}.nodata{color:var(--mut);font-size:13px;padding:18px 0}
.plan-item{display:grid;grid-template-columns:1fr auto;gap:6px 14px;padding:12px 0;border-bottom:1px solid var(--bd)}.plan-item:last-child{border-bottom:0}
.price{font-weight:700;white-space:nowrap}.imp{font-size:12px;color:var(--mut)}
.bar{height:6px;border-radius:3px;background:var(--bd);overflow:hidden;margin-top:4px;width:120px}.bar i{display:block;height:100%;background:var(--acc)}
textarea{width:100%;min-height:220px;font:13px/1.45 Consolas,monospace;background:var(--bg);color:var(--tx);border:1px solid var(--bd);border-radius:8px;padding:10px}
button{font:inherit;background:var(--acc);color:#fff;border:0;border-radius:8px;padding:8px 14px;cursor:pointer}
.note{font-size:13px;color:var(--mut);margin-top:8px}
footer{margin-top:40px;font-size:13px;color:var(--mut)}
@media print{nav,button,.noprint{display:none}.find{break-inside:avoid}details{display:block}details>*{display:block}body{background:#fff}}
'@

    [void]$sb.Append("<!doctype html><html lang=`"es`"><head><meta charset=`"utf-8`"><meta name=`"viewport`" content=`"width=device-width,initial-scale=1`"><title>Doctor PC - $(& $Enc $D.Equipo)</title><style>$css</style></head><body><div class=`"wrap`">")

    # Cabecera
    [void]$sb.Append("<header class=`"top`"><div><h1>Doctor <span>PC</span></h1><div class=`"mut small`">Informe de <b>$(& $Enc $D.Equipo)</b> · $(& $Enc (Format-Fecha $D.Fecha -Hora)) · v$(& $Enc $D.Version)$(if (-not $D.Admin) { ' · ejecutado sin permisos de administrador (algunos datos faltan)' })</div></div></header>")
    [void]$sb.Append('<nav><a href="#resumen">Resumen</a><a href="#hallazgos">Diagnóstico</a><a href="#plan">Plan de mejora</a><a href="#juegos">Juegos</a><a href="#rendimiento">Rendimiento</a><a href="#equipo">Equipo</a><a href="#windows">Windows</a><a href="#compartir">Compartir</a></nav>')

    # Resumen
    $p = $Salud.Puntos
    $col = if ($p -ge 80) { 'var(--ok)' } elseif ($p -ge 60) { 'var(--medio)' } elseif ($p -ge 40) { 'var(--alto)' } else { 'var(--crit)' }
    $circ = [math]::Round(2 * [math]::PI * 64, 1)
    $dash = [math]::Round($circ * $p / 100, 1)
    $top = @($Hallazgos | Where-Object { $_.Severidad -in @('critico', 'alto', 'medio') } | Select-Object -First 3)
    [void]$sb.Append("<h2 id=`"resumen`">Resumen</h2><div class=`"card hero`"><div class=`"ring`"><svg width=`"150`" height=`"150`" viewBox=`"0 0 150 150`"><circle cx=`"75`" cy=`"75`" r=`"64`" fill=`"none`" stroke=`"var(--bd)`" stroke-width=`"12`"/><circle cx=`"75`" cy=`"75`" r=`"64`" fill=`"none`" stroke=`"$col`" stroke-width=`"12`" stroke-linecap=`"round`" stroke-dasharray=`"$($dash.ToString($script:Inv)) $($circ.ToString($script:Inv))`"/></svg><div class=`"n`"><b>$p</b><small>$(& $Enc $Salud.Etiqueta)</small></div></div><div>")
    [void]$sb.Append("<dl class=`"kv`"><dt>Equipo</dt><dd>$(& $Enc "$($s.Fabricante) $($s.Modelo)")$(if ($Ctx.EsPortatil) { ' · portátil' })</dd><dt>Procesador</dt><dd>$(& $Enc $D.Cpu.Nombre)</dd><dt>Gráficos</dt><dd>$(& $Enc (($Ctx.Gpus | ForEach-Object { $_.Nombre }) -join ' + '))</dd><dt>Memoria</dt><dd>$(& $Enc $Ctx.RamTexto) $(& $Enc $Ctx.RamTipo) · canal $(& $Enc $Ctx.RamCanal.ToLower())</dd>")
    if ($Ctx.DiscoSistema) { [void]$sb.Append("<dt>Disco del sistema</dt><dd>$(& $Enc $Ctx.DiscoSistema.Tipo) · $($Ctx.SysLibreGB) GB libres</dd>") }
    [void]$sb.Append('</dl>')
    if ($top.Count) {
        [void]$sb.Append('<h3 style="margin-top:14px">Lo primero que revisaría un técnico</h3><ol style="margin:0;padding-left:20px">')
        foreach ($h in $top) { [void]$sb.Append("<li><span class=`"badge b-$($h.Severidad)`">$($etSev[$h.Severidad])</span> $(& $Enc $h.Titulo)</li>") }
        [void]$sb.Append('</ol>')
    } else { [void]$sb.Append('<p>No se encontraron problemas importantes.</p>') }
    if (@($Plan.Dentro).Count) {
        $c = @($Plan.Dentro)[0]
        [void]$sb.Append("<p class=`"note`"><b>Mejor compra para tu presupuesto:</b> $(& $Enc $c.Nombre) · $(& $Enc (Format-Precio $c.Precio))</p>")
    }
    [void]$sb.Append('</div></div>')

    # Hallazgos
    [void]$sb.Append("<h2 id=`"hallazgos`">Diagnóstico <span class=`"mut small`">($(@($Hallazgos).Count) hallazgos)</span></h2>")
    if (@($Hallazgos).Count -eq 0) { [void]$sb.Append('<div class="card">Sin hallazgos.</div>') }
    $n = 0
    foreach ($h in $Hallazgos) {
        $n++
        $abierto = if ($h.Severidad -in @('critico', 'alto') -or $n -le 2) { ' open' } else { '' }
        $obs = (@($h.Observacion | Where-Object { $_ }) | ForEach-Object { "<li>$(& $Enc $_)</li>" }) -join ''
        $sol = (@($h.Solucion | Where-Object { $_ }) | ForEach-Object { "<li>$(& $Enc $_)</li>" }) -join ''
        $rep = if ($h.Reparacion) { "<div class=`"note`">Disponible en <b>Reparaciones guiadas</b> (ejecuta Doctor PC y elige esa opción al final).</div>" } else { '' }
        [void]$sb.Append("<details class=`"card find $($h.Severidad)`"$abierto><summary><span class=`"badge b-$($h.Severidad)`">$($etSev[$h.Severidad])</span><span class=`"t`">$(& $Enc $h.Titulo)</span><span class=`"chip`">$(& $Enc $h.Categoria)</span><span class=`"chip`">Confianza: $(& $Enc $h.Confianza)</span><span class=`"chip`">$(& $Enc $h.Coste)</span></summary>")
        [void]$sb.Append("<div class=`"steps`"><div class=`"step`"><h4>Observación</h4><ul>$obs</ul></div><div class=`"step`"><h4>Hipótesis</h4>$(& $Enc $h.Hipotesis)</div><div class=`"step`"><h4>Cómo confirmarlo</h4>$(& $Enc $h.Prueba)</div><div class=`"step`"><h4>Solución</h4><ul>$sol</ul></div></div>$rep</details>")
    }

    # Plan
    [void]$sb.Append("<h2 id=`"plan`">Plan de mejora</h2><div class=`"grid`" style=`"grid-template-columns:1fr`">")
    [void]$sb.Append('<div class="card"><h3>1. Gratis: hazlo antes de comprar nada</h3>')
    if (@($Plan.Gratis).Count) {
        [void]$sb.Append('<ul style="margin:6px 0 0;padding-left:20px">')
        foreach ($g in $Plan.Gratis) { [void]$sb.Append("<li><b>$(& $Enc $g.Titulo)</b> &mdash; $(& $Enc $g.Accion)</li>") }
        [void]$sb.Append('</ul>')
    } else { [void]$sb.Append('<p class="mut">Nada pendiente.</p>') }
    [void]$sb.Append('</div>')
    $pres = if ($Plan.Presupuesto -ge 0) { "dentro de US`$$($Plan.Presupuesto)" } else { 'ordenadas por beneficio/coste' }
    [void]$sb.Append("<div class=`"card`"><h3>2. Compras $pres</h3>")
    $pintar = {
        param($lista)
        foreach ($c in $lista) {
            $comp = (@($c.Compatibilidad) | ForEach-Object { "<li>$(& $Enc $_)</li>" }) -join ''
            [void]$sb.Append("<div class=`"plan-item`"><div><b>$(& $Enc $c.Nombre)</b> <span class=`"chip`">$(& $Enc $c.Categoria)</span><div class=`"small`">$(& $Enc $c.Motivo)</div><ul class=`"small mut`" style=`"margin:4px 0 0;padding-left:18px`">$comp</ul></div><div style=`"text-align:right`"><div class=`"price`">$(& $Enc (Format-Precio $c.Precio))</div><div class=`"imp`">$(& $Enc $c.Precio.Estado) · impacto $($c.Impacto)/10</div><div class=`"bar`" style=`"margin-left:auto`"><i style=`"width:$($c.Impacto * 10)%`"></i></div></div></div>")
        }
    }
    if (@($Plan.Dentro).Count) { & $pintar @($Plan.Dentro); [void]$sb.Append("<p class=`"note`">Total estimado: <b>$(& $Enc (Format-Precio ([pscustomobject]@{ Min = [math]::Round((@($Plan.Dentro | ForEach-Object { $_.Precio.Min }) | Measure-Object -Sum).Sum); Max = [math]::Round((@($Plan.Dentro | ForEach-Object { $_.Precio.Max }) | Measure-Object -Sum).Sum) })))</b></p>") }
    else { [void]$sb.Append('<p class="mut">No hay compras recomendadas dentro del presupuesto.</p>') }
    [void]$sb.Append('</div>')
    if (@($Plan.Fuera).Count) { [void]$sb.Append('<div class="card"><h3>3. Siguientes pasos (fuera del presupuesto actual)</h3>'); & $pintar @($Plan.Fuera); [void]$sb.Append('</div>') }
    if (@($Plan.Bloqueadas).Count) {
        [void]$sb.Append('<div class="card"><h3>Lo que NO conviene comprar en este equipo</h3><ul style="margin:0;padding-left:20px">')
        foreach ($b in $Plan.Bloqueadas) { [void]$sb.Append("<li><b>$(& $Enc $b.Nombre)</b>: $(& $Enc $b.Motivo)</li>") }
        [void]$sb.Append('</ul></div>')
    }
    [void]$sb.Append("<div class=`"note`">$((@($Plan.Notas) | ForEach-Object { & $Enc $_ }) -join '<br>')</div></div>")

    # Juegos
    [void]$sb.Append("<h2 id=`"juegos`">Juegos detectados <span class=`"mut small`">($(@($Juegos).Count))</span></h2>")
    if (@($Juegos).Count) {
        [void]$sb.Append('<div class="card tw"><table><thead><tr><th>Juego</th><th>Origen</th><th>Disco</th><th>Tamaño</th><th>Estado</th><th>Qué limita</th></tr></thead><tbody>')
        foreach ($j in $Juegos) {
            $cls = switch ($j.Nivel) { 'alto' { 'alto' } 'medio' { 'medio' } 'ok' { 'ok' } default { 'info' } }
            $lim = @($j.BajoMinimo | ForEach-Object { "$_ (bajo el mínimo)" }) + @($j.BajoRecomendado)
            $notaJ = if (@($j.Notas).Count) { "<div class=`"small mut`">$(& $Enc (@($j.Notas) -join ' '))</div>" } else { '' }
            [void]$sb.Append("<tr><td><b>$(& $Enc $j.Nombre)</b>$notaJ</td><td>$(& $Enc $j.Tienda)</td><td>$(& $Enc "$($j.Unidad) $($j.TipoDisco)")</td><td>$(if ($j.TamanoGB) { "$($j.TamanoGB) GB" })</td><td><span class=`"badge b-$cls`">$(& $Enc $j.Estado)</span></td><td class=`"small`">$(& $Enc ($lim -join ', '))</td></tr>")
        }
        [void]$sb.Append('</tbody></table><p class="note">Comparación aproximada con los requisitos publicados (índices de datos\catalogo_juegos.json). "Sin datos": el juego no está en el catálogo; puedes añadirlo.</p></div>')
    } else { [void]$sb.Append('<div class="card mut">No se detectaron juegos. Añade tus carpetas de juegos en <b>carpetas_juegos.txt</b> o usa -CarpetasJuegos.</div>') }

    # Rendimiento
    [void]$sb.Append('<h2 id="rendimiento">Rendimiento medido</h2>')
    if ($D.Muestreo -and @($D.Muestreo.Muestras).Count) {
        $ms = @($D.Muestreo.Muestras); $m = $Ctx.Muestreo
        $modo = if ($m.ModoJuego) { 'en modo juego (con el juego abierto)' } else { 'en reposo' }
        [void]$sb.Append("<p class=`"mut small`">Medición de $($D.Muestreo.Segundos) s $modo, una muestra cada 2 s.</p><div class=`"grid`">")
        $ramTotal = [math]::Max(1, $Ctx.RamGB * 1024)
        $usoRam = @($ms | ForEach-Object { 100 - (Get-Num $_.RamLibreMB) / $ramTotal * 100 })
        [void]$sb.Append("<div class=`"card metric`"><div class=`"mut small`">CPU · media / máx.</div><b>$($m.Cpu.Prom) %</b> <span class=`"mut`">/ $($m.Cpu.Max) %</span>$(New-Sparkline ($ms | ForEach-Object { $_.Cpu }) 100 'l1')</div>")
        [void]$sb.Append("<div class=`"card metric`"><div class=`"mut small`">RAM en uso · RAM libre mín.</div><b>$([math]::Round(($usoRam | Measure-Object -Average).Average)) %</b> <span class=`"mut`">· $($m.RamLibre.Min) MB</span>$(New-Sparkline $usoRam 100 'l2')</div>")
        if ($null -ne $m.Gpu.Prom) { [void]$sb.Append("<div class=`"card metric`"><div class=`"mut small`">GPU (3D) · media / máx.</div><b>$($m.Gpu.Prom) %</b> <span class=`"mut`">/ $($m.Gpu.Max) %</span>$(New-Sparkline ($ms | ForEach-Object { $_.Gpu }) 100 'l3')</div>") }
        foreach ($dk in @($m.Discos)) {
            $act = @($ms | ForEach-Object { $x = @($_.Discos | Where-Object { "$($_.Disco)" -eq $dk.Nombre }) | Select-Object -First 1; if ($x) { 100 - (Get-Num $x.Inactivo 100) } else { $null } })
            [void]$sb.Append("<div class=`"card metric`"><div class=`"mut small`">Disco $(& $Enc $dk.Nombre) $(& $Enc $dk.Tipo) · actividad media</div><b>$([math]::Round(100 - (Get-Num $dk.Inactivo.Prom 100))) %</b> <span class=`"mut`">· latencia p95 $(if ($null -ne $dk.LatMs.P95) { "$($dk.LatMs.P95) ms" } else { 'n/d' })</span>$(New-Sparkline $act 100 'l4')</div>")
        }
        [void]$sb.Append('</div><div class="grid" style="margin-top:12px"><div class="card tw"><h3>Procesos que más CPU usaron</h3><table><tbody>')
        foreach ($pr in @($D.Muestreo.TopCpu | Select-Object -First 6)) { [void]$sb.Append("<tr><td>$(& $Enc $pr.Nombre)</td><td>$($pr.Cpu) %</td></tr>") }
        [void]$sb.Append('</tbody></table></div><div class="card tw"><h3>Procesos que más RAM usan</h3><table><tbody>')
        foreach ($pr in @($D.Muestreo.TopRam | Select-Object -First 6)) { [void]$sb.Append("<tr><td>$(& $Enc $pr.Nombre)</td><td>$($pr.RamMB) MB</td></tr>") }
        [void]$sb.Append('</tbody></table></div></div>')
        if (-not $m.ModoJuego) { [void]$sb.Append('<p class="note">Para saber qué limita a un juego concreto, ejecuta Doctor PC en <b>modo juego</b> (opción del menú o -ModoJuego 120) y juega mientras mide.</p>') }
    } else { [void]$sb.Append('<div class="card mut">No se realizó medición de rendimiento.</div>') }

    # Equipo
    [void]$sb.Append('<h2 id="equipo">Ficha técnica</h2><div class="grid">')
    [void]$sb.Append("<div class=`"card`"><h3>Procesador</h3><dl class=`"kv`"><dt>Modelo</dt><dd>$(& $Enc $D.Cpu.Nombre)</dd><dt>Núcleos / hilos</dt><dd>$($D.Cpu.Nucleos) / $($D.Cpu.Hilos)</dd><dt>Frecuencia</dt><dd>$($D.Cpu.MHzMax) MHz</dd><dt>Socket</dt><dd>$(& $Enc $(if ($Ctx.CpuPlataforma) { $Ctx.CpuPlataforma } else { $D.Cpu.Socket }))</dd><dt>Índice aprox.</dt><dd>$($Ctx.CpuIndice) <span class=`"mut small`">(i5-8400 = 100)</span></dd></dl></div>")
    foreach ($g in @($Ctx.Gpus)) {
        $raw = @($D.Gpus | Where-Object { $_.Nombre -eq $g.Nombre }) | Select-Object -First 1
        [void]$sb.Append("<div class=`"card`"><h3>Gráficos</h3><dl class=`"kv`"><dt>Modelo</dt><dd>$(& $Enc $g.Nombre)</dd><dt>Tipo</dt><dd>$(if ($g.SinDriver) { 'Sin driver' } elseif ($g.Integrada) { 'Integrada' } else { 'Dedicada' })</dd><dt>VRAM</dt><dd>$(if ($g.VramGB) { "$($g.VramGB) GB" } else { 'n/d' })</dd><dt>Driver</dt><dd>$(& $Enc $raw.Driver) ($(& $Enc (Format-Fecha $raw.FechaDriver)))</dd><dt>Pantalla</dt><dd>$(& $Enc $raw.Resolucion) $(if ($raw.Hz) { "@ $($raw.Hz) Hz" })</dd><dt>Índice aprox.</dt><dd>$(if ($null -ne $g.Indice) { $g.Indice } else { 'no catalogada' }) <span class=`"mut small`">(GTX 1060 = 100)</span></dd></dl></div>")
    }
    [void]$sb.Append("<div class=`"card`"><h3>Placa y sistema</h3><dl class=`"kv`"><dt>Fabricante</dt><dd>$(& $Enc "$($s.Fabricante) $($s.Modelo)")</dd><dt>Placa</dt><dd>$(& $Enc $s.Placa)</dd><dt>BIOS</dt><dd>$(& $Enc $s.BIOS) ($(& $Enc (Format-Fecha $s.FechaBIOS)))</dd><dt>Windows</dt><dd>$(& $Enc "$($s.Windows) $($s.VersionWindows)") · build $($s.Build)</dd><dt>Instalado</dt><dd>$(& $Enc (Format-Fecha $s.Instalado))</dd><dt>Plan de energía</dt><dd>$(& $Enc $s.PlanEnergia)</dd>$(if ($s.Bateria) { "<dt>Batería</dt><dd>$($s.Bateria.Carga) %$(if ($s.Bateria.SaludPct) { " · salud $($s.Bateria.SaludPct) %" })</dd>" })</dl></div>")
    [void]$sb.Append('</div>')
    [void]$sb.Append("<div class=`"card tw`" style=`"margin-top:12px`"><h3>Memoria RAM · $(& $Enc $Ctx.RamTexto) ($($Ctx.RamGB) GB utilizables) · ranuras $(if ($Ctx.RamRanuras) { "$($Ctx.RamModulos)/$($Ctx.RamRanuras) ocupadas" } else { 'n/d' }) $(if ($Ctx.RamMaxGB) { "· máx. $($Ctx.RamMaxGB) GB" })</h3><table><thead><tr><th>Ranura</th><th>Capacidad</th><th>Tipo</th><th>Velocidad</th><th>Fabricante / modelo</th></tr></thead><tbody>")
    foreach ($md in @($D.Ram.Modulos)) { [void]$sb.Append("<tr><td>$(& $Enc $md.Ranura)</td><td>$($md.CapacidadGB) GB</td><td>$(& $Enc "$($md.Tipo) $($md.Formato)")</td><td>$($md.MHzActual) / $($md.MHz) MHz</td><td>$(& $Enc "$($md.Fabricante) $($md.Modelo)")</td></tr>") }
    [void]$sb.Append('</tbody></table></div>')
    [void]$sb.Append('<div class="card tw" style="margin-top:12px"><h3>Discos</h3><table><thead><tr><th>#</th><th>Modelo</th><th>Tipo</th><th>Tamaño</th><th>Salud</th><th>Temp.</th><th>Horas</th><th>Desgaste</th><th>Volúmenes</th></tr></thead><tbody>')
    foreach ($dk in @($D.Discos)) {
        $vols = (@($dk.Volumenes) | ForEach-Object { "$($_.Letra) $($_.LibreGB)/$($_.TamanoGB) GB libres" }) -join '<br>'
        [void]$sb.Append("<tr><td>$($dk.Numero)</td><td>$(& $Enc $dk.Modelo)</td><td>$(& $Enc $dk.Tipo)</td><td>$($dk.TamanoGB) GB</td><td>$(& $Enc $dk.Salud)</td><td>$(if ($null -ne $dk.TempC) { "$($dk.TempC) °C" })</td><td>$($dk.Horas)</td><td>$(if ($null -ne $dk.DesgastePct) { "$($dk.DesgastePct) %" })</td><td class=`"small`">$vols</td></tr>")
    }
    [void]$sb.Append('</tbody></table></div>')
    if (@($D.Temperaturas).Count) {
        [void]$sb.Append('<div class="card tw" style="margin-top:12px"><h3>Temperaturas</h3><table><thead><tr><th>Componente</th><th>Sensor</th><th>Actual</th><th>Máx.</th><th>Fuente</th></tr></thead><tbody>')
        foreach ($t in @($D.Temperaturas | Select-Object -First 20)) { [void]$sb.Append("<tr><td>$(& $Enc $t.Componente)</td><td>$(& $Enc $t.Sensor)</td><td>$($t.Valor) °C</td><td>$(if ($t.Max) { "$($t.Max) °C" })</td><td>$(& $Enc $t.Fuente)</td></tr>") }
        [void]$sb.Append('</tbody></table></div>')
    }

    # Windows
    $ev = $D.Eventos
    [void]$sb.Append("<h2 id=`"windows`">Windows · últimos $($ev.Dias) días</h2><div class=`"grid`">")
    $mini = {
        param($t, $v, $bad)
        $c = if ((Get-Num $v) -gt 0 -and $bad) { "style=`"color:var(--alto)`"" } else { '' }
        [void]$sb.Append("<div class=`"card metric`"><div class=`"mut small`">$t</div><b $c>$v</b></div>")
    }
    & $mini 'Apagados inesperados' (Get-Num $ev.ApagadosInesperados) $true
    & $mini 'Pantallazos azules' @($ev.Pantallazos).Count $true
    & $mini 'Errores de hardware (WHEA)' (Get-Num $ev.ErroresWhea) $true
    & $mini 'Reinicios del driver de vídeo' (Get-Num $ev.ReiniciosDriverVideo) $true
    & $mini 'Errores de disco' (Get-Num $ev.ErroresDisco) $true
    & $mini 'Programas de inicio activos' @($D.Inicio | Where-Object { $_.Activo }).Count $false
    [void]$sb.Append('</div>')
    if (@($ev.CierresApps).Count) {
        [void]$sb.Append('<div class="card tw" style="margin-top:12px"><h3>Programas que se cerraron con error</h3><table><thead><tr><th>Programa</th><th>Veces</th><th>Módulo</th><th>Último</th></tr></thead><tbody>')
        foreach ($c in @($ev.CierresApps | Select-Object -First 10)) { [void]$sb.Append("<tr><td>$(& $Enc $c.App)</td><td>$($c.Veces)</td><td>$(& $Enc $c.Modulo)</td><td>$(& $Enc $c.Ultima)</td></tr>") }
        [void]$sb.Append('</tbody></table></div>')
    }
    if (@($D.Dispositivos).Count) {
        [void]$sb.Append('<div class="card tw" style="margin-top:12px"><h3>Dispositivos con problemas</h3><table><thead><tr><th>Dispositivo</th><th>Código</th><th>Significado</th></tr></thead><tbody>')
        foreach ($dv in @($D.Dispositivos)) { $desc = if ($script:CodigosDispositivo.ContainsKey([int]$dv.Codigo)) { $script:CodigosDispositivo[[int]$dv.Codigo] } else { '' }; [void]$sb.Append("<tr><td>$(& $Enc $dv.Nombre)</td><td>$($dv.Codigo)</td><td>$(& $Enc $desc)</td></tr>") }
        [void]$sb.Append('</tbody></table></div>')
    }
    if (@($D.Inicio).Count) {
        [void]$sb.Append('<div class="card tw" style="margin-top:12px"><h3>Programas de inicio</h3><table><thead><tr><th>Nombre</th><th>Estado</th><th>Comando</th></tr></thead><tbody>')
        foreach ($i in @($D.Inicio)) { [void]$sb.Append("<tr><td>$(& $Enc $i.Nombre)</td><td>$(if ($i.Activo) { 'Activo' } else { '<span class="mut">Desactivado</span>' })</td><td class=`"small mut`" style=`"word-break:break-all`">$(& $Enc $i.Comando)</td></tr>") }
        [void]$sb.Append('</tbody></table></div>')
    }

    # Compartir
    [void]$sb.Append("<h2 id=`"compartir`">Compartir con un técnico</h2><div class=`"card`"><p class=`"small mut`" style=`"margin-top:0`">Resumen en texto plano para WhatsApp, correo o foros. No incluye tu nombre de usuario ni archivos personales.</p><textarea id=`"res`" readonly>$(& $Enc $Resumen)</textarea><div style=`"margin-top:8px`"><button onclick=`"copiar()`">Copiar resumen</button> <span id=`"ok`" class=`"small mut`"></span></div><p class=`"note`">Junto a este informe se guardó un archivo .json con todos los datos: un técnico puede regenerar el informe con <code>DoctorPC.ps1 -DesdeJson archivo.json</code>.</p></div>")

    if (@($D.Avisos).Count) { [void]$sb.Append("<p class=`"note`">Avisos de la recolección: $((@($D.Avisos) | ForEach-Object { & $Enc $_ }) -join ' · ')</p>") }
    [void]$sb.Append("<footer>Doctor PC $(& $Enc $D.Version) · Informe generado localmente: ningún dato salió de este equipo. Los índices de rendimiento y precios son aproximados y orientativos; las hipótesis indican causas probables, no certezas. Doctor PC no modifica el sistema salvo en las reparaciones guiadas que confirmes tú.</footer>")
    [void]$sb.Append('</div><script>function copiar(){var t=document.getElementById("res");t.select();try{navigator.clipboard.writeText(t.value).then(function(){document.getElementById("ok").textContent="Copiado"},function(){document.execCommand("copy");document.getElementById("ok").textContent="Copiado"})}catch(e){document.execCommand("copy");document.getElementById("ok").textContent="Copiado"}}</script></body></html>')
    return $sb.ToString()
}

# =====================================================================
#  REPARACIONES GUIADAS (nada se ejecuta sin confirmación)
# =====================================================================

function Write-Registro([string]$Texto) {
    try { Add-Content -LiteralPath $script:Registro -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Texto) -Encoding UTF8 } catch { }
}

function Show-Reparaciones($Hallazgos, $D) {
    $admin = Test-Admin
    $sugeridas = @($Hallazgos | ForEach-Object { $_.Reparacion } | Where-Object { $_ } | Select-Object -Unique)
    $ops = @(
        @{ Id = 'dism_sfc'; Nivel = 3; Admin = $true; Nombre = 'Comprobar y reparar archivos de Windows (DISM + SFC)'
           Desc = 'DISM repara la imagen de Windows (usa internet para descargar componentes oficiales) y SFC restaura archivos de sistema dañados. No borra tus archivos ni programas. Tarda entre 15 y 40 minutos; no apagues el equipo.' }
        @{ Id = 'chkdsk'; Nivel = 2; Admin = $true; Nombre = "Revisar el disco del sistema (chkdsk /scan, solo lectura)"
           Desc = 'Analiza el sistema de archivos sin desmontar el disco ni reparar nada. Si encuentra errores, te dirá cómo programar la reparación.' }
        @{ Id = 'memoria'; Nivel = 2; Admin = $true; Nombre = 'Programar el Diagnóstico de memoria de Windows'
           Desc = 'Abre la herramienta oficial. Te preguntará si quieres reiniciar ahora o en el próximo arranque. La prueba dura unos 15-20 minutos.' }
        @{ Id = 'liberador'; Nivel = 2; Admin = $false; Nombre = 'Abrir el Liberador de espacio en disco'
           Desc = 'Abre la herramienta oficial de Windows. Tú eliges qué borrar (temporales, caché de actualizaciones, papelera). Pulsa "Limpiar archivos del sistema" para más opciones.' }
        @{ Id = 'inicio'; Nivel = 2; Admin = $false; Nombre = 'Abrir el Administrador de tareas en "Aplicaciones de arranque"'
           Desc = 'Desde ahí puedes desactivar los programas que no necesitas al encender. Es reversible.' }
        @{ Id = 'energia'; Nivel = 3; Admin = $false; Nombre = 'Cambiar el plan de energía a Equilibrado'
           Desc = 'Cambia el plan activo. Se guarda el plan anterior en el registro de cambios para poder volver.' }
        @{ Id = 'graficos'; Nivel = 2; Admin = $false; Nombre = 'Abrir la configuración de gráficos (elegir GPU por juego)'
           Desc = 'Abre Configuración > Pantalla > Gráficos para asignar "Alto rendimiento" a tus juegos.' }
        @{ Id = 'actualizaciones'; Nivel = 2; Admin = $false; Nombre = 'Abrir Windows Update (actualizaciones opcionales de drivers)'
           Desc = 'Abre la sección donde Windows ofrece drivers adicionales. Tú decides qué instalar.' }
    )
    while ($true) {
        Write-Titulo 'REPARACIONES GUIADAS'
        Write-Host '    Cada opción explica qué hace y pide confirmación. Los cambios quedan en registro_cambios.log.' -ForegroundColor Gray
        for ($i = 0; $i -lt $ops.Count; $i++) {
            $o = $ops[$i]
            $marca = if ($sugeridas -contains $o.Id) { ' (sugerida)' } else { '' }
            $req = if ($o.Admin -and -not $admin) { ' [requiere administrador]' } else { '' }
            Write-Host ("    {0}. {1}{2}{3}" -f ($i + 1), $o.Nombre, $marca, $req) -ForegroundColor $(if ($marca) { 'Yellow' } else { 'White' })
        }
        Write-Host '    0. Salir'
        $sel = Read-Opcion 'Elige una opción' '0'
        $n = 0
        if (-not [int]::TryParse($sel, [ref]$n) -or $n -lt 1 -or $n -gt $ops.Count) { return }
        $o = $ops[$n - 1]
        Write-Host ''
        Write-Host "    $($o.Nombre)" -ForegroundColor Cyan
        Write-Host "    $($o.Desc)" -ForegroundColor Gray
        if ($o.Admin -and -not $admin) { Write-Alerta 'Esta opción necesita ejecutar Doctor PC como administrador.'; continue }
        if ($o.Nivel -ge 3) {
            $c = Read-Host '    Escribe SI (en mayúsculas) para continuar'
            if ($c -cne 'SI') { Write-Paso 'Cancelado.'; continue }
        } elseif (-not (Read-SiNo '¿Continuar?' $false)) { Write-Paso 'Cancelado.'; continue }

        Invoke-Reparacion $o.Id
    }
}

function Invoke-Reparacion([string]$Id) {
        switch ($Id) {
            'dism_sfc' {
                Write-Registro 'INICIO DISM /RestoreHealth'
                & dism.exe /Online /Cleanup-Image /RestoreHealth
                Write-Registro "FIN DISM (código $LASTEXITCODE)"
                Write-Registro 'INICIO sfc /scannow'
                & sfc.exe /scannow
                Write-Registro "FIN sfc (código $LASTEXITCODE)"
                Write-Ok 'Terminado. Reinicia el equipo para completar las reparaciones.'
            }
            'chkdsk' {
                Write-Registro "chkdsk $env:SystemDrive /scan"
                & chkdsk.exe $env:SystemDrive /scan
                Write-Registro "FIN chkdsk (código $LASTEXITCODE)"
            }
            'memoria'         { Write-Registro 'Abierto mdsched.exe'; Start-Process 'mdsched.exe' }
            'liberador'       { Write-Registro 'Abierto cleanmgr'; Start-Process 'cleanmgr.exe' -ArgumentList "/d $($env:SystemDrive.TrimEnd(':'))" }
            'inicio'          { Write-Registro 'Abierto Administrador de tareas (inicio)'; Start-Process 'taskmgr.exe' -ArgumentList '/0 /startup' }
            'graficos'        { Start-Process 'ms-settings:display-advancedgraphics' }
            'actualizaciones' { Start-Process 'ms-settings:windowsupdate-optionalupdates' }
            'energia' {
                $antes = ''
                if (((powercfg.exe /getactivescheme 2>$null) -join ' ') -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { $antes = $Matches[1] }
                & powercfg.exe /setactive 381b4222-f694-41f0-9685-ff5bb260df2e
                Write-Registro "Plan de energía cambiado a Equilibrado. Anterior: $antes. Para volver: powercfg /setactive $antes"
                Write-Ok "Hecho. Para volver al plan anterior: powercfg /setactive $antes"
            }
        }
}

# =====================================================================
#  PROGRAMA PRINCIPAL
# =====================================================================

$script:Indices  = Read-JsonArchivo (Join-Path $script:DirDatos 'indices_hardware.json')
$script:Catalogo = Read-JsonArchivo (Join-Path $script:DirDatos 'catalogo_juegos.json')
$script:Precios  = Read-JsonArchivo (Join-Path $script:DirDatos 'precios.json')
if (-not $script:Indices)  { Add-Aviso 'Falta datos\indices_hardware.json: no se calcularán índices de rendimiento.' }
if (-not $script:Catalogo) { Add-Aviso 'Falta datos\catalogo_juegos.json: no se compararán requisitos de juegos.' }
if (-not $script:Precios)  { Add-Aviso 'Falta datos\precios.json: no se estimarán precios.' }

if ($ModoApp) { $NoInteractivo = $true; $NoAbrir = $true }
trap { if ($ModoApp -or $ArchivoProgreso) { Send-Evento 'ERROR' @($_.Exception.Message); exit 1 } else { break } }
$interactivo = -not $NoInteractivo -and -not $DesdeJson -and -not $Accion -and [Environment]::UserInteractive
$cfgRuta = Join-Path $script:DirDatos 'config_usuario.json'
$cfg = Read-JsonArchivo $cfgRuta

Write-Host ''
Write-Host '  ==========================================================' -ForegroundColor DarkCyan
Write-Host "   DOCTOR PC $script:Version  -  Diagnóstico explicable de tu PC" -ForegroundColor Cyan
Write-Host '   Solo lectura. Nada sale de tu equipo.' -ForegroundColor DarkGray
Write-Host '  ==========================================================' -ForegroundColor DarkCyan

# Elevación opcional
$esAdmin = Test-Admin
if ($interactivo -and $script:EsWindows -and -not $esAdmin) {
    Write-Host ''
    Write-Alerta 'Sin permisos de administrador no se pueden leer la salud de los discos, algunas temperaturas ni ejecutar reparaciones.'
    if (Read-SiNo '¿Reabrir Doctor PC como administrador?' $true) {
        $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
        foreach ($kv in $PSBoundParameters.GetEnumerator()) {
            if ($kv.Value -is [switch]) { if ($kv.Value) { $args2 += "-$($kv.Key)" } }
            elseif ($kv.Value -is [array]) { $args2 += "-$($kv.Key)"; $args2 += (($kv.Value | ForEach-Object { "`"$_`"" }) -join ',') }
            else { $args2 += "-$($kv.Key)"; $args2 += "`"$($kv.Value)`"" }
        }
        try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList $args2 -Verb RunAs -ErrorAction Stop
            Write-Ok 'Doctor PC se abrió como administrador en otra ventana. Puedes cerrar esta.'
            exit
        } catch { Write-Alerta 'No se concedió el permiso. Continúo sin administrador.' }
    }
}

# Preguntas
if ($interactivo) {
    Write-Titulo 'TRES PREGUNTAS RÁPIDAS (Enter = valor entre corchetes)'
    $paises = @()
    if ($script:Precios) { $paises = @($script:Precios.paises.PSObject.Properties | ForEach-Object { $_.Name }) }
    if (-not $Pais) {
        if ($paises.Count) { Write-Host ("    Países: " + (($paises | ForEach-Object { $i = [array]::IndexOf($paises, $_) + 1; "$i) $_" }) -join '  ')) -ForegroundColor DarkGray }
        $def = if ($cfg -and $cfg.Pais) { "$($cfg.Pais)" } else { 'Otro' }
        $r = Read-Opcion '¿En qué país comprarías piezas? (número o nombre)' $def
        $num = 0
        if ([int]::TryParse($r, [ref]$num) -and $num -ge 1 -and $num -le $paises.Count) { $Pais = $paises[$num - 1] } else { $Pais = $r }
    }
    if ($Presupuesto -lt 0) {
        $def = if ($cfg -and $null -ne $cfg.Presupuesto -and $cfg.Presupuesto -ge 0) { "$($cfg.Presupuesto)" } else { 'sin límite' }
        $r = Read-Opcion '¿Presupuesto máximo en dólares (USD)? 0 = solo soluciones gratis' $def
        $x = 0.0
        if ([double]::TryParse(($r -replace '[^\d\.,]', '' -replace ',', '.'), [System.Globalization.NumberStyles]::Any, $script:Inv, [ref]$x)) { $Presupuesto = $x } else { $Presupuesto = -1 }
    }
    if (-not $IncluirUsados -and -not $SoloNuevos) {
        $def = if ($cfg -and $null -ne $cfg.Usados) { [bool]$cfg.Usados } else { $true }
        if (Read-SiNo '¿Aceptas piezas usadas (más baratas)?' $def) { $IncluirUsados = $true } else { $SoloNuevos = $true }
    }
    if ($ModoJuego -eq 0) {
        if (Read-SiNo '¿Quieres medir mientras juegas (modo juego, 2 minutos)?' $false) { $ModoJuego = 120 }
    }
    try { ([ordered]@{ Pais = $Pais; Presupuesto = $Presupuesto; Usados = [bool]$IncluirUsados } | ConvertTo-Json) | Set-Content -LiteralPath $cfgRuta -Encoding UTF8 } catch { }
}
$usados = -not $SoloNuevos -and ($IncluirUsados -or -not $interactivo)

# País y precios
if (-not $Pais) { $Pais = if ($cfg -and $cfg.Pais) { "$($cfg.Pais)" } else { 'Otro' } }
$script:PaisNombre = $Pais
$script:PaisInfo = $null
if ($script:Precios) {
    $prop = @($script:Precios.paises.PSObject.Properties | Where-Object { $_.Name -eq $Pais -or ($_.Name -replace '[^\w]', '') -eq ($Pais -replace '[^\w]', '') }) | Select-Object -First 1
    if ($prop) { $script:PaisInfo = $prop.Value; $script:PaisNombre = $prop.Name }
    else { $script:PaisInfo = $script:Precios.paises.Otro; $script:PaisNombre = "$Pais (precios genéricos)" }
}
if (-not $script:PaisInfo) { $script:PaisInfo = [pscustomobject]@{ moneda = 'USD'; tasa_usd = 1; factor = 1 } }
$script:FuenteW = $FuenteWatts

# Carpeta de salida
if (-not $Salida) {
    $docs = [Environment]::GetFolderPath('MyDocuments')
    if (-not $docs) { $docs = $script:Raiz }
    $Salida = Join-Path $docs 'DoctorPC'
}
if (-not (Test-Path -LiteralPath $Salida)) { New-Item -ItemType Directory -Path $Salida -Force | Out-Null }
$script:Registro = Join-Path $Salida 'registro_cambios.log'

if ($Accion) {
    Write-Titulo "REPARACIÓN GUIADA: $Accion"
    Invoke-Reparacion $Accion
    Send-Evento 'ACCION' @($Accion, $LASTEXITCODE)
    if (-not $ModoApp -and $Accion -in @('dism_sfc', 'chkdsk')) { Write-Host ''; Read-Host '  Pulsa Enter para cerrar esta ventana' | Out-Null }
    exit 0
}

# --------------------------------------------------- Recolección o carga
if ($DesdeJson) {
    Set-Paso 30 "Cargando datos desde $(Split-Path $DesdeJson -Leaf)"
    $j = Read-JsonArchivo $DesdeJson
    if (-not $j) { Write-Alerta 'No se pudo leer el JSON.'; Send-Evento 'ERROR' @('No se pudo leer el archivo JSON.'); exit 1 }
    $D = if ($j.Datos) { $j.Datos } else { $j }
}
else {
    if (-not $script:EsWindows) { Write-Alerta 'Doctor PC analiza equipos Windows. En otros sistemas solo funciona -DesdeJson.'; exit 1 }
    Write-Titulo 'ANALIZANDO EL EQUIPO'
    $D = [ordered]@{ Version = $script:Version; Fecha = (Get-Date).ToString('s'); Equipo = $env:COMPUTERNAME; Admin = $esAdmin }
    Set-Paso 3  'Sistema, placa y energía';  $D.Sistema = Get-InfoSistema; $D.Sistema.UnidadSistema = $env:SystemDrive
    Set-Paso 7  'Procesador';                $D.Cpu = Get-InfoCpu
    Set-Paso 10 'Tarjeta(s) gráfica(s)';     $D.Gpus = @(Get-InfoGpu)
    Set-Paso 13 'Memoria RAM';               $D.Ram = Get-InfoRam
    Set-Paso 16 'Discos y salud';            $D.Discos = @(Get-InfoDiscos); $D.Volumenes = @(Get-InfoVolumenes); $D.FalloPredicho = @(Get-FalloPredicho)
    Set-Paso 22 'Temperaturas';              $D.Temperaturas = @(Get-Temperaturas)
    Set-Paso 25 'Registros de Windows (30 días)'; $D.Eventos = Get-EventosWindows 30
    Set-Paso 33 'Dispositivos y drivers';    $D.Dispositivos = @(Get-DispositivosConError)
    Set-Paso 36 'Programas de inicio';       $D.Inicio = @(Get-ProgramasInicio)
    if ($SinJuegos) { $D.Juegos = @() }
    else { Set-Paso 39 'Buscando juegos (Steam, Epic, GOG, Ubisoft, EA, Riot, Xbox y tus carpetas)'; $D.Juegos = @(Get-Juegos $CarpetasJuegos) }
    if (-not $ModoApp) { Write-Ok "$(@($D.Juegos).Count) juego(s) encontrados." }
    if ($ModoJuego -gt 0) {
        Write-Titulo 'MODO JUEGO'
        if ($ModoApp) { Send-Evento 'AVISO' @('Abre tu juego ahora y juega con normalidad. La medición empieza en 20 segundos.') }
        else { Write-Host '    Abre tu juego ahora y juega con normalidad. La medición empieza en 20 segundos.' -ForegroundColor Yellow }
        if ($interactivo) { Write-Host '    (Pulsa Enter cuando estés en partida para empezar antes.)' -ForegroundColor DarkGray }
        $limite = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $limite) {
            if ($interactivo) { try { if ([Console]::KeyAvailable) { $k = [Console]::ReadKey($true); if ($k.Key -eq 'Enter') { break } } } catch { } }
            if ($ModoApp) {
                if ($ArchivoCancelar -and (Test-Path -LiteralPath "$ArchivoCancelar.empezar")) { break }
                Set-Paso 45 ("Abre tu juego: la medición empieza en {0} s" -f [math]::Ceiling(($limite - (Get-Date)).TotalSeconds))
            }
            Start-Sleep -Milliseconds 500
        }
        if ($ModoApp) { Send-Evento 'AVISO' @('Midiendo tu partida. Sigue jugando con normalidad.') }
        $D.Muestreo = Invoke-Muestreo $ModoJuego $true
    } else {
        Set-Paso 48 "Midiendo el rendimiento en reposo ($Muestreo s). No uses el PC mientras tanto."
        $D.Muestreo = Invoke-Muestreo $Muestreo $false
    }
    if ($Anonimo) {
        $D.Equipo = 'PC'; $D.Sistema.Equipo = 'PC'
        foreach ($jg in @($D.Juegos)) { $jg.Ruta = Format-RutaPrivada $jg.Ruta }
    } else {
        foreach ($jg in @($D.Juegos)) { $jg.Ruta = Format-RutaPrivada $jg.Ruta }
    }
    $D.Avisos = @($script:Avisos)
}

# --------------------------------------------------- Análisis
Write-Titulo 'DIAGNOSTICANDO'
Set-Paso 92 'Diagnosticando'
$Ctx = Get-Contexto $D
$Juegos = Get-AnalisisJuegos $D $Ctx
$Hallazgos = Invoke-Reglas $D $Ctx $Juegos
$Salud = Get-PuntuacionSalud $Hallazgos
$Plan = New-PlanMejora $D $Ctx $Juegos $Hallazgos $Presupuesto $usados
$Resumen = Get-TextoResumen $D $Ctx $Hallazgos $Plan $Salud

# --------------------------------------------------- Salida
Set-Paso 97 'Generando el informe'
$base = 'DoctorPC_{0}_{1}' -f (($D.Equipo -replace '[^\w\-]', '')), ((Get-Date).ToString('yyyyMMdd_HHmmss'))
$rutaHtml = Join-Path $Salida "$base.html"
$rutaJson = Join-Path $Salida "$base.json"
$html = New-InformeHtml $D $Ctx $Hallazgos $Juegos $Plan $Salud $Resumen
[System.IO.File]::WriteAllText($rutaHtml, $html, (New-Object System.Text.UTF8Encoding($false)))
$export = [ordered]@{ DoctorPC = $script:Version; Datos = $D; Diagnostico = [ordered]@{ Salud = $Salud; Hallazgos = $Hallazgos; Juegos = $Juegos; Plan = $Plan; Pais = $script:PaisNombre } }
[System.IO.File]::WriteAllText($rutaJson, ($export | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($false)))

Send-Evento 'RESULTADO' @($rutaHtml, $rutaJson, $Salud.Puntos, $Salud.Etiqueta)
if ($ModoApp) { exit 0 }

# Resumen en consola
Write-Host ''
$colSalud = if ($Salud.Puntos -ge 80) { 'Green' } elseif ($Salud.Puntos -ge 60) { 'Yellow' } else { 'Red' }
Write-Host ("  SALUD DEL EQUIPO: {0}/100 - {1}" -f $Salud.Puntos, $Salud.Etiqueta) -ForegroundColor $colSalud
$colores = @{ critico = 'Red'; alto = 'DarkYellow'; medio = 'Yellow'; bajo = 'Cyan'; info = 'Gray' }
foreach ($h in @($Hallazgos | Where-Object { $_.Severidad -ne 'info' } | Select-Object -First 6)) {
    Write-Host ("    [{0}] {1}" -f $h.Severidad.ToUpper(), $h.Titulo) -ForegroundColor $colores[$h.Severidad]
}
if (@($Plan.Dentro).Count) {
    Write-Host ''
    Write-Host '  MEJORAS SUGERIDAS' -ForegroundColor Cyan
    foreach ($c in @($Plan.Dentro)) { Write-Host ("    - {0}: {1}" -f $c.Nombre, (Format-Precio $c.Precio)) }
}
Write-Host ''
Write-Ok "Informe: $rutaHtml"
Write-Ok "Datos:   $rutaJson"
if (-not $NoAbrir -and $script:EsWindows) { try { Start-Process $rutaHtml } catch { } }

if ($script:EsWindows -and -not $DesdeJson -and ($Reparar -or ($interactivo -and @($Hallazgos | Where-Object { $_.Reparacion }).Count -gt 0))) {
    Write-Host ''
    if ($Reparar -or (Read-SiNo '¿Quieres ver las reparaciones guiadas disponibles?' $false)) { Show-Reparaciones $Hallazgos $D }
}
if ($interactivo) { Write-Host ''; Read-Host '  Pulsa Enter para salir' | Out-Null }
