# Doctor PC — prueba de velocidad del disco con la herramienta oficial de Windows (WinSAT).
# Necesita permisos de administrador. Mide lectura secuencial, escritura secuencial y lectura aleatoria.
param(
    [string]$Unidad = 'C',
    [string]$Salida = '',
    [string]$ArchivoProgreso = ''
)
$ErrorActionPreference = 'Continue'
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

$winsat = Join-Path $env:SystemRoot 'System32\winsat.exe'
if (-not (Test-Path -LiteralPath $winsat)) {
    Send-Evento 'ERROR' @('Esta edición de Windows no incluye la herramienta de evaluación de discos (WinSAT).')
    Save-Resultado ([ordered]@{ Ok = $false; Error = 'WinSAT no disponible' }); exit 1
}

function Invoke-Prueba([string[]]$Argumentos) {
    $txt = (& $winsat @Argumentos 2>&1 | Out-String)
    $m = [regex]::Matches($txt, '([\d]+[\.,]?[\d]*)\s*MB/s')
    if ($m.Count -eq 0) { return $null }
    return [math]::Round([double]($m[$m.Count - 1].Groups[1].Value -replace ',', '.'), 1)
}

$pruebas = @(
    @{ Id = 'LecturaSecuencial';  Texto = 'Lectura secuencial (archivos grandes, cargas de juegos)'; Args = @('disk', '-seq', '-read', '-drive', $Unidad) },
    @{ Id = 'EscrituraSecuencial'; Texto = 'Escritura secuencial (copiar e instalar)'; Args = @('disk', '-seq', '-write', '-drive', $Unidad) },
    @{ Id = 'LecturaAleatoria';   Texto = 'Lectura aleatoria (arranque de Windows y programas)'; Args = @('disk', '-ran', '-read', '-drive', $Unidad) }
)
$r = [ordered]@{ Ok = $true; Unidad = "$($Unidad):"; Fecha = (Get-Date).ToString('s') }
$i = 0
foreach ($p in $pruebas) {
    Send-Evento 'PROGRESO' @([int](5 + 30 * $i), "$($p.Texto)…")
    $v = $null
    try { $v = Invoke-Prueba $p.Args } catch { $v = $null }
    $r[$p.Id] = $v
    $i++
}
Send-Evento 'PROGRESO' @(98, 'Interpretando resultados')

$sec = [double]("$($r.LecturaSecuencial)" -replace '^$', '0')
$ale = [double]("$($r.LecturaAleatoria)" -replace '^$', '0')
if ($sec -le 0) {
    $r.Ok = $false; $r.Error = 'La prueba no devolvió resultados. Cierra programas pesados y vuelve a intentarlo.'
}
elseif ($sec -lt 250 -and $ale -lt 20) {
    $r.Nivel = 'lento'; $r.Tipo = 'Disco mecánico (HDD) o SSD muy degradado'
    $r.Texto = 'Este disco es el cuello de botella típico de un PC lento: arranque, programas y actualizaciones tardan mucho. Pasar Windows a un SSD es la mejora más notable por su precio.'
}
elseif ($sec -lt 650) {
    $r.Nivel = 'bien'; $r.Tipo = 'SSD SATA'
    $r.Texto = 'Velocidad de SSD SATA: suficiente para Windows y juegos. Un NVMe solo acortaría algo las cargas.'
}
else {
    $r.Nivel = 'excelente'; $r.Tipo = 'SSD NVMe'
    $r.Texto = 'Velocidad de SSD NVMe: el disco no limita tu equipo.'
}
if ($r.Ok -and $r.Nivel -ne 'lento' -and $ale -gt 0 -and $ale -lt 15) {
    $r.Texto += ' La lectura aleatoria es más baja de lo normal para un SSD: revisa su salud, que no esté casi lleno y que el modo AHCI esté activo en la BIOS.'
}
Save-Resultado $r
Send-Evento 'RESULTADO' @($sec, $ale)
