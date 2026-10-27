# Doctor PC — prueba de velocidad del disco.
# Mide escritura secuencial, lectura secuencial y lectura aleatoria de 4 KB leyendo y escribiendo
# directamente en el disco (sin la caché de Windows), con un archivo temporal que se borra al terminar.
# No necesita permisos de administrador.
param(
    [string]$Unidad = 'C',
    [string]$Salida = '',
    [string]$ArchivoProgreso = '',
    [int]$TamanoMB = 512
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Unidad = ("$Unidad" -replace '[^A-Za-z]', '').Substring(0, 1).ToUpper()

function Send-Evento([string]$Tipo, [object[]]$Partes = @()) {
    $l = '##' + $Tipo + '|' + ((@($Partes) | ForEach-Object { "$_" -replace '[\r\n|]', ' ' }) -join '|')
    if ($ArchivoProgreso) { try { [System.IO.File]::AppendAllText($ArchivoProgreso, $l + "`n", (New-Object System.Text.UTF8Encoding($false))) } catch { } }
    else { Write-Host $l }
}
function Save-Resultado($o) {
    $j = $o | ConvertTo-Json -Depth 4
    if ($Salida) { [System.IO.File]::WriteAllText($Salida, $j, (New-Object System.Text.UTF8Encoding($false))) } else { $j }
}

$codigo = @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class DoctorPcDisco {
    const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000;
    const uint CREATE_ALWAYS = 2, OPEN_EXISTING = 3;
    const uint NO_BUFFERING = 0x20000000, WRITE_THROUGH = 0x80000000, RANDOM_ACCESS = 0x10000000, SEQUENTIAL_SCAN = 0x08000000;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFileW(string nombre, uint acceso, uint compartir, IntPtr seg, uint disp, uint flags, IntPtr plantilla);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(SafeFileHandle h, IntPtr buf, uint n, out uint hecho, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(SafeFileHandle h, IntPtr buf, uint n, out uint hecho, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFilePointerEx(SafeFileHandle h, long distancia, out long nueva, uint metodo);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr VirtualAlloc(IntPtr dir, UIntPtr tam, uint tipo, uint proteccion);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool VirtualFree(IntPtr dir, UIntPtr tam, uint tipo);

    // Memoria alineada a página (requisito de la E/S sin caché)
    static IntPtr Reservar(int bytes) {
        IntPtr p = VirtualAlloc(IntPtr.Zero, (UIntPtr)(uint)bytes, 0x3000, 0x04);
        if (p == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        byte[] datos = new byte[bytes];
        new Random(7).NextBytes(datos);
        Marshal.Copy(datos, 0, p, bytes);
        return p;
    }
    static void Liberar(IntPtr p) { VirtualFree(p, UIntPtr.Zero, 0x8000); }
    static SafeFileHandle Abrir(string ruta, bool escribir, uint extra) {
        SafeFileHandle h = CreateFileW(ruta, escribir ? GENERIC_WRITE : GENERIC_READ, 0, IntPtr.Zero, escribir ? CREATE_ALWAYS : OPEN_EXISTING, NO_BUFFERING | extra, IntPtr.Zero);
        if (h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        return h;
    }

    public static double EscrituraSecuencial(string ruta, long total, int bloque) {
        IntPtr buf = Reservar(bloque);
        try {
            using (SafeFileHandle h = Abrir(ruta, true, WRITE_THROUGH)) {
                Stopwatch sw = Stopwatch.StartNew();
                long hecho = 0; uint n;
                while (hecho < total) {
                    if (!WriteFile(h, buf, (uint)bloque, out n, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
                    hecho += n;
                }
                sw.Stop();
                return hecho / 1048576.0 / sw.Elapsed.TotalSeconds;
            }
        } finally { Liberar(buf); }
    }

    public static double LecturaSecuencial(string ruta, long total, int bloque, double minSegundos) {
        IntPtr buf = Reservar(bloque);
        try {
            using (SafeFileHandle h = Abrir(ruta, false, SEQUENTIAL_SCAN)) {
                Stopwatch sw = Stopwatch.StartNew();
                long hecho = 0, pos; uint n;
                do {
                    SetFilePointerEx(h, 0, out pos, 0);
                    long vuelta = 0;
                    while (vuelta < total) {
                        if (!ReadFile(h, buf, (uint)bloque, out n, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
                        if (n == 0) break;
                        vuelta += n;
                    }
                    hecho += vuelta;
                } while (sw.Elapsed.TotalSeconds < minSegundos);
                sw.Stop();
                return hecho / 1048576.0 / sw.Elapsed.TotalSeconds;
            }
        } finally { Liberar(buf); }
    }

    public static double[] LecturaAleatoria(string ruta, long total, int bloque, double segundos) {
        IntPtr buf = Reservar(bloque);
        try {
            using (SafeFileHandle h = Abrir(ruta, false, RANDOM_ACCESS)) {
                Random rnd = new Random(11);
                long bloques = total / bloque, ops = 0, pos; uint n;
                Stopwatch sw = Stopwatch.StartNew();
                while (sw.Elapsed.TotalSeconds < segundos) {
                    long b = (long)(rnd.NextDouble() * bloques);
                    if (!SetFilePointerEx(h, b * bloque, out pos, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
                    if (!ReadFile(h, buf, (uint)bloque, out n, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
                    ops++;
                }
                sw.Stop();
                double seg = sw.Elapsed.TotalSeconds;
                return new double[] { ops * (double)bloque / 1048576.0 / seg, ops / seg };
            }
        } finally { Liberar(buf); }
    }
}
'@

$r = [ordered]@{ Ok = $true; Unidad = "$($Unidad):"; Fecha = (Get-Date).ToString('s'); Metodo = 'Lectura y escritura directas (sin caché)' }
$archivo = $null
try {
    if (-not ('DoctorPcDisco' -as [type])) { Add-Type -TypeDefinition $codigo -Language CSharp }

    $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($Unidad):'"
    if (-not $vol) { throw "No existe la unidad $($Unidad):" }
    $libreMB = [math]::Floor([double]$vol.FreeSpace / 1MB)
    if ($libreMB -lt 600) { throw "La unidad $($Unidad): tiene muy poco espacio libre para la prueba (se necesitan 600 MB)." }
    if ($libreMB -lt ($TamanoMB * 3)) { $TamanoMB = 256 }

    $sistema = ("$env:SystemDrive".Substring(0, 1).ToUpper() -eq $Unidad)
    $carpeta = if ($sistema) { $env:TEMP } else { "$($Unidad):\" }
    $archivo = Join-Path $carpeta ('DoctorPC-prueba-disco-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp')
    $total = [long]$TamanoMB * 1MB
    $bloque = 4MB

    Send-Evento 'PROGRESO' @(8, 'Escritura secuencial (copiar e instalar)…')
    $r.EscrituraSecuencial = [math]::Round([DoctorPcDisco]::EscrituraSecuencial($archivo, $total, $bloque), 1)
    Send-Evento 'PROGRESO' @(40, 'Lectura secuencial (cargas de juegos, archivos grandes)…')
    $r.LecturaSecuencial = [math]::Round([DoctorPcDisco]::LecturaSecuencial($archivo, $total, $bloque, 3.0), 1)
    Send-Evento 'PROGRESO' @(70, 'Lectura aleatoria de 4 KB (arranque de Windows y programas)…')
    $ale = [DoctorPcDisco]::LecturaAleatoria($archivo, $total, 4096, 5.0)
    $r.LecturaAleatoria = [math]::Round($ale[0], 2)
    $r.Iops = [math]::Round($ale[1])
    $r.TamanoPruebaMB = $TamanoMB
}
catch {
    $r.Ok = $false
    $r.Error = "No se pudo completar la prueba: $($_.Exception.Message)"
}
finally {
    if ($archivo -and (Test-Path -LiteralPath $archivo)) { Remove-Item -LiteralPath $archivo -Force -ErrorAction SilentlyContinue }
}

if ($r.Ok) {
    Send-Evento 'PROGRESO' @(97, 'Interpretando resultados')
    $sec = [double]$r.LecturaSecuencial; $alea = [double]$r.LecturaAleatoria
    if ($sec -lt 250 -and $alea -lt 8) {
        $r.Nivel = 'lento'; $r.Tipo = 'Disco mecánico (HDD) o SSD muy degradado'
        $r.Texto = 'Este disco es el cuello de botella típico de un PC lento: arranque, programas y actualizaciones tardan mucho. Pasar Windows a un SSD es la mejora más notable por su precio.'
    }
    elseif ($sec -lt 700) {
        $r.Nivel = 'bien'; $r.Tipo = 'SSD SATA (o disco rápido)'
        $r.Texto = 'Velocidad de SSD SATA: suficiente para Windows y juegos. Un NVMe solo acortaría algo las cargas.'
    }
    else {
        $r.Nivel = 'excelente'; $r.Tipo = 'SSD NVMe'
        $r.Texto = 'Velocidad de SSD NVMe: el disco no limita tu equipo.'
    }
    if ($r.Nivel -ne 'lento' -and $alea -lt 10) {
        $r.Texto += ' La lectura aleatoria es más baja de lo normal para un SSD: revisa su salud, que no esté casi lleno y que el modo AHCI esté activo en la BIOS.'
    }
    Save-Resultado $r
    Send-Evento 'RESULTADO' @($r.LecturaSecuencial, $r.LecturaAleatoria)
}
else {
    Save-Resultado $r
    Send-Evento 'ERROR' @($r.Error)
    exit 1
}
