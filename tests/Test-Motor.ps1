# Pruebas del motor de Doctor PC.
#  - Sintaxis y codificación (BOM necesario para Windows PowerShell 5.1)
#  - Diagnóstico de los equipos de prueba (tests/equipos/*.json) en modo app
#  - En Windows: un análisis real y completo del equipo donde se ejecuta
$ErrorActionPreference = 'Stop'
$raiz = Split-Path $PSScriptRoot -Parent
$motor = Join-Path (Join-Path $raiz 'engine') 'DoctorPC.ps1'
$salida = Join-Path ([IO.Path]::GetTempPath()) ('doctorpc-pruebas-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $salida -Force | Out-Null
$host_exe = (Get-Process -Id $PID).Path
$fallos = 0

function Test-Paso([string]$Nombre, [scriptblock]$Prueba) {
    try { & $Prueba; Write-Host "  OK    $Nombre" -ForegroundColor Green }
    catch { Write-Host "  FALLO $Nombre -> $($_.Exception.Message)" -ForegroundColor Red; $script:fallos++ }
}

function Invoke-Motor([string[]]$Argumentos) {
    $prog = Join-Path $salida ('progreso-' + [guid]::NewGuid().ToString('N') + '.txt')
    $todos = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $motor) + $Argumentos + @('-ModoApp', '-ArchivoProgreso', $prog, '-Salida', $salida)
    & $host_exe @todos | Out-Null
    $codigo = $LASTEXITCODE
    $lineas = if (Test-Path $prog) { @(Get-Content $prog -Encoding UTF8) } else { @() }
    $res = @($lineas | Where-Object { $_ -like '##RESULTADO|*' }) | Select-Object -First 1
    $err = @($lineas | Where-Object { $_ -like '##ERROR|*' }) | Select-Object -First 1
    if ($codigo -ne 0 -or -not $res) { throw "código $codigo; $err" }
    $p = $res.Split('|')
    if (-not (Test-Path $p[1]) -or -not (Test-Path $p[2])) { throw 'faltan los archivos del informe' }
    $j = Get-Content $p[2] -Raw -Encoding UTF8 | ConvertFrom-Json
    return [pscustomobject]@{ Html = $p[1]; Json = $j; Salud = [int]$p[3]; Lineas = $lineas }
}

Write-Host "Motor: $motor"
Write-Host "PowerShell $($PSVersionTable.PSVersion) en $([Environment]::OSVersion.VersionString)"

Test-Paso 'El archivo tiene BOM UTF-8 (necesario en PowerShell 5.1)' {
    $b = [IO.File]::ReadAllBytes($motor)
    if (-not ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) { throw 'sin BOM' }
}
Test-Paso 'Sintaxis del motor' {
    $t = $null; $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile($motor, [ref]$t, [ref]$e) | Out-Null
    if ($e) { throw (($e | ForEach-Object { "línea $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ') }
}
Test-Paso 'Los catálogos JSON son válidos' {
    Get-ChildItem (Join-Path (Join-Path $raiz 'engine') 'datos') -Filter *.json | ForEach-Object { $null = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
}

$esperado = @{
    'oficina-hdd'      = @('DISCO-SISTEMA-HDD', 'RAM-CANAL-SIMPLE', 'WIN-PANTALLAZOS')
    'portatil-igpu'    = @('TEMP-ALTA', 'JUEGO-LIMITE-GPU', 'RAM-CANAL-SIMPLE')
    'gamer-limite-cpu' = @('JUEGO-LIMITE-CPU', 'JUEGO-LIMITE-DISCO', 'RAM-XMP')
}
foreach ($f in Get-ChildItem (Join-Path $PSScriptRoot 'equipos') -Filter *.json) {
    Test-Paso "Diagnóstico del equipo de prueba '$($f.BaseName)'" {
        $r = Invoke-Motor @('-DesdeJson', $f.FullName, '-Pais', 'Venezuela', '-Presupuesto', '100', '-IncluirUsados')
        $ids = @($r.Json.Diagnostico.Hallazgos | ForEach-Object { $_.Id })
        foreach ($id in @($esperado[$f.BaseName])) { if ($id -and $ids -notcontains $id) { throw "falta el hallazgo $id" } }
        if (-not ($r.Lineas -like '##PROGRESO|*')) { throw 'no hubo eventos de progreso' }
    }
}

if ($env:OS -eq 'Windows_NT') {
    Test-Paso 'Análisis real de este equipo Windows' {
        $r = Invoke-Motor @('-Muestreo', '6', '-Pais', 'Chile', '-Presupuesto', '80', '-IncluirUsados')
        $d = $r.Json.Datos
        if (-not $d.Cpu.Nombre) { throw 'no se leyó el procesador' }
        if (-not $d.Ram.TotalGB) { throw 'no se leyó la RAM' }
        if (@($d.Discos).Count -eq 0) { throw 'no se leyeron los discos' }
        if (@($d.Muestreo.Muestras).Count -lt 2) { throw 'no hubo muestras de rendimiento' }
        Write-Host ("        CPU: {0} | RAM: {1} GB | discos: {2} | juegos: {3} | hallazgos: {4} | salud: {5}" -f $d.Cpu.Nombre, $d.Ram.TotalGB, @($d.Discos).Count, @($d.Juegos).Count, @($r.Json.Diagnostico.Hallazgos).Count, $r.Salud)
    }
    Test-Paso 'Cancelación del análisis' {
        $prog = Join-Path $salida 'cancel-progreso.txt'; $flag = Join-Path $salida 'cancelar.flag'
        Set-Content $flag '1'
        & $host_exe -NoProfile -ExecutionPolicy Bypass -File $motor -ModoApp -ArchivoProgreso $prog -ArchivoCancelar $flag -Salida $salida | Out-Null
        if ($LASTEXITCODE -ne 2) { throw "se esperaba código 2 y fue $LASTEXITCODE" }
    }
    Test-Paso 'Ficha del técnico en el informe y en el resumen' {
        $f = Join-Path (Join-Path $PSScriptRoot 'equipos') 'oficina-hdd.json'
        $r = Invoke-Motor @('-DesdeJson', $f, '-Tecnico', 'Técnico de prueba|WhatsApp 000')
        if (-not ((Get-Content $r.Html -Raw -Encoding UTF8) -match 'class="tec"')) { throw 'no aparece en el HTML' }
        if ($r.Json.Diagnostico.Resumen -notmatch 'Técnico de prueba') { throw 'no aparece en el resumen' }
    }
    $dirMotor = Split-Path $motor -Parent
    Test-Paso 'Monitor en vivo (3 lecturas)' {
        $lineas = @(& $host_exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dirMotor 'monitor.ps1') -Muestras 3 -IntervaloMs 500)
        $datos = @($lineas | Where-Object { $_ -like '{*' } | ForEach-Object { $_ | ConvertFrom-Json })
        if ($datos.Count -lt 3) { throw "solo $($datos.Count) lecturas" }
        if (-not ($datos[-1].ramTotal -gt 0)) { throw 'sin RAM total' }
        if ($null -eq $datos[-1].cpu) { throw 'sin CPU' }
        if (@($datos[0].procs).Count -eq 0) { throw 'sin procesos' }
        Write-Host ("        CPU {0} % | RAM {1}/{2} MB | GPU {3} | discos {4}" -f $datos[-1].cpu, $datos[-1].ramUsada, $datos[-1].ramTotal, $datos[-1].gpu, @($datos[-1].discos).Count)
    }
    Test-Paso 'Limpieza: medir y borrar solo temporales antiguos' {
        $viejo = Join-Path $env:TEMP ('doctorpc-viejo-' + [guid]::NewGuid().ToString('N') + '.tmp')
        $nuevo = Join-Path $env:TEMP ('doctorpc-nuevo-' + [guid]::NewGuid().ToString('N') + '.tmp')
        Set-Content $viejo ('x' * 5000); Set-Content $nuevo 'reciente'
        (Get-Item $viejo).LastWriteTime = (Get-Date).AddDays(-3)
        $out = Join-Path $salida 'limpieza.json'; $log = Join-Path $salida 'registro.log'
        & $host_exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dirMotor 'limpieza.ps1') -Modo analizar -Salida $out | Out-Null
        $a = Get-Content $out -Raw -Encoding UTF8 | ConvertFrom-Json
        if (@($a.Categorias).Count -lt 6) { throw 'faltan categorías' }
        if (-not (@($a.Categorias | Where-Object Id -eq 'temp_usuario')[0].Tamano -gt 0)) { throw 'no midió TEMP' }
        if (-not (Test-Path $viejo)) { throw 'analizar borró archivos' }
        & $host_exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dirMotor 'limpieza.ps1') -Modo limpiar -Elementos temp_usuario -Salida $out -Registro $log | Out-Null
        $l = Get-Content $out -Raw -Encoding UTF8 | ConvertFrom-Json
        if (Test-Path $viejo) { throw 'no borró el archivo antiguo' }
        if (-not (Test-Path $nuevo)) { throw 'borró un archivo reciente' }
        if (-not (Test-Path $log)) { throw 'no escribió el registro' }
        Write-Host ("        Liberado: {0:N1} MB en {1} archivos" -f ($l.Liberado / 1MB), $l.Borrados)
        Remove-Item $nuevo -Force
    }
    if (Test-Path (Join-Path $env:SystemRoot 'System32\winsat.exe')) {
        Test-Paso 'Prueba de velocidad del disco (WinSAT)' {
            $out = Join-Path $salida 'disco.json'
            & $host_exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dirMotor 'prueba-disco.ps1') -Unidad C -Salida $out | Out-Null
            $d = Get-Content $out -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $d.Ok) { throw $d.Error }
            Write-Host ("        Lectura sec. {0} MB/s | escritura sec. {1} MB/s | aleatoria {2} MB/s -> {3}" -f $d.LecturaSecuencial, $d.EscrituraSecuencial, $d.LecturaAleatoria, $d.Tipo)
        }
    } else { Write-Host '  --    WinSAT no está en esta edición de Windows (normal en Windows Server): se omite la prueba de disco' }
}

Remove-Item $salida -Recurse -Force -ErrorAction SilentlyContinue
if ($fallos) { Write-Host "$fallos prueba(s) fallaron." -ForegroundColor Red; exit 1 }
Write-Host 'Todas las pruebas del motor pasaron.' -ForegroundColor Green
exit 0
