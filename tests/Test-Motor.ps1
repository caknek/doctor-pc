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
}

Remove-Item $salida -Recurse -Force -ErrorAction SilentlyContinue
if ($fallos) { Write-Host "$fallos prueba(s) fallaron." -ForegroundColor Red; exit 1 }
Write-Host 'Todas las pruebas del motor pasaron.' -ForegroundColor Green
