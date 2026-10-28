# Doctor PC — monitor en vivo.
# Escribe una línea JSON por segundo: CPU, RAM, GPU, discos, red, temperatura y procesos.
# Termina cuando se cierra el proceso que lo lanzó (-PadrePid) o tras -Muestras lecturas.
param(
    [int]$PadrePid = 0,
    [int]$IntervaloMs = 1000,
    [int]$Muestras = 0,
    [string]$ArchivoControl = ''
)
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Get-Num($v) { if ($null -eq $v -or "$v" -eq '') { return 0.0 } try { return [double]$v } catch { return 0.0 } }

$cs = Get-CimInstance Win32_ComputerSystem
$totalMB = [math]::Round((Get-Num $cs.TotalPhysicalMemory) / 1MB)
$logicos = [Environment]::ProcessorCount
$nombreCpu = (@(Get-CimInstance Win32_Processor)[0].Name -replace '\s+', ' ').Trim()

# Ventana en primer plano: proceso, si ocupa toda la pantalla y el rectángulo del monitor (para el overlay en juegos)
try {
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DpcVentana {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
    public static int[] Info() {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero) return null;
        uint pid; GetWindowThreadProcessId(h, out pid);
        RECT r; if (!GetWindowRect(h, out r)) return null;
        MONITORINFO mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
        if (!GetMonitorInfo(MonitorFromWindow(h, 2), ref mi)) return null;
        int fs = (r.Left <= mi.rcMonitor.Left && r.Top <= mi.rcMonitor.Top && r.Right >= mi.rcMonitor.Right && r.Bottom >= mi.rcMonitor.Bottom) ? 1 : 0;
        return new int[] { (int)pid, fs, mi.rcMonitor.Left, mi.rcMonitor.Top, mi.rcMonitor.Right, mi.rcMonitor.Bottom };
    }
}
'@
    $hayVentana = $true
} catch { $hayVentana = $false }
$cacheProc = @{}

# Las clases "Formatted" devuelven 0 en la primera lectura: calentamiento
$null = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor
$null = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk
$null = Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface
$null = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process
Start-Sleep -Milliseconds 400

$hayGpu = $true
$tick = 0
while ($true) {
    if ($PadrePid -gt 0 -and -not (Get-Process -Id $PadrePid -ErrorAction SilentlyContinue)) { break }
    if ($Muestras -gt 0 -and $tick -ge $Muestras) { break }
    if ($ArchivoControl -and (Test-Path -LiteralPath $ArchivoControl)) {
        $ctl = "$(Get-Content -LiteralPath $ArchivoControl -Raw -ErrorAction SilentlyContinue)".Trim()
        if ($ctl -eq 'salir') { break }
        $v = 0; if ([int]::TryParse($ctl, [ref]$v) -and $v -ge 250 -and $v -le 10000) { $IntervaloMs = $v }
    }
    $t0 = Get-Date

    # Primer plano
    $fg = $null
    if ($hayVentana) {
        $inf = $null
        try { $inf = [DpcVentana]::Info() } catch { }
        if ($inf) {
            $fpid = $inf[0]
            if (-not $cacheProc.ContainsKey($fpid)) {
                $pr = Get-Process -Id $fpid -ErrorAction SilentlyContinue
                $ruta = ''; try { $ruta = $pr.Path } catch { }
                if ($cacheProc.Count -gt 200) { $cacheProc.Clear() }
                $cacheProc[$fpid] = @{ n = "$($pr.ProcessName)"; ruta = "$ruta" }
            }
            $fg = [ordered]@{ pid = $fpid; n = $cacheProc[$fpid].n; ruta = $cacheProc[$fpid].ruta; fs = [bool]$inf[1]; gpu = 0.0; mon = @($inf[2], $inf[3], $inf[4], $inf[5]) }
        }
    }

    $cpu = Get-Num (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
    $perf = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'"
    $mem = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $libreMB = Get-Num $mem.AvailableMBytes

    $discos = @(Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk | Where-Object { $_.Name -ne '_Total' } | ForEach-Object {
        [ordered]@{
            n   = "$($_.Name)"
            act = [math]::Round([math]::Min(100, [math]::Max(0, 100 - (Get-Num $_.PercentIdleTime))), 1)
            r   = [math]::Round((Get-Num $_.DiskReadBytesPersec) / 1MB, 2)
            w   = [math]::Round((Get-Num $_.DiskWriteBytesPersec) / 1MB, 2)
        }
    })

    $gpu = $null
    if ($hayGpu) {
        $motores = @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine | Where-Object { $_.Name -like '*engtype_3D*' })
        if ($motores.Count) {
            $porLuid = @{}
            $prefijo = if ($fg) { "pid_$($fg.pid)_" } else { '#' }
            foreach ($g in $motores) {
                if ($g.Name -match 'luid_(0x[0-9A-Fa-f]+_0x[0-9A-Fa-f]+)') { $porLuid[$Matches[1]] = (Get-Num $porLuid[$Matches[1]]) + (Get-Num $g.UtilizationPercentage) }
                if ($fg -and $g.Name.StartsWith($prefijo)) { $fg.gpu += (Get-Num $g.UtilizationPercentage) }
            }
            if ($fg) { $fg.gpu = [math]::Round([math]::Min(100, $fg.gpu), 1) }
            if ($porLuid.Count) { $gpu = [math]::Round([math]::Min(100, (($porLuid.Values | Measure-Object -Maximum).Maximum)), 1) }
        } elseif ($tick -gt 2) { $hayGpu = $false }
    }

    $red = @(Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface)
    $bajada = Get-Num (($red | Measure-Object -Property BytesReceivedPersec -Sum).Sum)
    $subida = Get-Num (($red | Measure-Object -Property BytesSentPersec -Sum).Sum)

    $temp = $null
    foreach ($ns in @('root\LibreHardwareMonitor', 'root\OpenHardwareMonitor')) {
        $s = @(Get-CimInstance -Namespace $ns -ClassName Sensor -Filter "SensorType='Temperature'" | Where-Object { "$($_.Parent)" -match 'cpu' })
        if ($s.Count) { $temp = [math]::Round((($s | Measure-Object -Property Value -Maximum).Maximum), 1); break }
    }
    # Respaldo aproximado sin controladores: zonas térmicas ACPI (se ignoran los valores fijos de relleno)
    $tempAcpi = $null
    if ($null -eq $temp -and $tick % 2 -eq 0) {
        foreach ($z in @(Get-CimInstance Win32_PerfFormattedData_Counters_ThermalZoneInformation)) {
            $k = Get-Num $z.HighPrecisionTemperature
            $c = if ($k -gt 0) { $k / 10 - 273.15 } else { (Get-Num $z.Temperature) - 273.15 }
            if ($c -ge 30 -and $c -lt 125 -and ($null -eq $tempAcpi -or $c -gt $tempAcpi)) { $tempAcpi = [math]::Round($c, 1) }
        }
    }

    $procs = $null
    if ($tick % 3 -eq 0) {
        $agg = @{}
        foreach ($p in @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process)) {
            if ($p.Name -in @('_Total', 'Idle')) { continue }
            $n = "$($p.Name)" -replace '#\d+$', ''
            if (-not $agg.ContainsKey($n)) { $agg[$n] = @{ n = $n; cpu = 0.0; ram = 0.0 } }
            $agg[$n].cpu += (Get-Num $p.PercentProcessorTime) / $logicos
            $agg[$n].ram += (Get-Num $p.WorkingSetPrivate) / 1MB
        }
        $procs = @($agg.Values | Sort-Object { $_.cpu }, { $_.ram } -Descending | Select-Object -First 6 | ForEach-Object {
            [ordered]@{ n = $_.n; cpu = [math]::Round($_.cpu, 1); ram = [math]::Round($_.ram) }
        })
    }

    $o = [ordered]@{
        t        = $tick
        cpuNom   = $nombreCpu
        cpu      = [math]::Round([math]::Min(100, $cpu), 1)
        cpuPerf  = if ($perf) { [math]::Round((Get-Num $perf.PercentProcessorPerformance)) } else { $null }
        ramTotal = $totalMB
        ramUsada = [math]::Max(0, [math]::Round($totalMB - $libreMB))
        gpu      = $gpu
        discos   = $discos
        bajadaKB = [math]::Round($bajada / 1KB, 1)
        subidaKB = [math]::Round($subida / 1KB, 1)
        temp     = $temp
        tempAcpi = $tempAcpi
        fg       = $fg
        procs    = $procs
    }
    [Console]::Out.WriteLine(($o | ConvertTo-Json -Compress -Depth 4))
    [Console]::Out.Flush()
    $tick++
    $resto = $IntervaloMs - ((Get-Date) - $t0).TotalMilliseconds
    if ($resto -gt 20) { Start-Sleep -Milliseconds ([int]$resto) }
}
