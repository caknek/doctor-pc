# Compila el lector de sensores (sensores/) y lo deja en engine/sensores con la licencia de LibreHardwareMonitor.
# Requiere el SDK de .NET (incluido en los equipos windows-latest de GitHub Actions).
$ErrorActionPreference = 'Stop'
$raiz = Split-Path $PSScriptRoot -Parent
$destino = Join-Path $raiz 'engine/sensores'
if (Test-Path $destino) { Remove-Item $destino -Recurse -Force }
dotnet publish (Join-Path $raiz 'sensores/DoctorPC.Sensores.csproj') -c Release -o $destino --nologo
if ($LASTEXITCODE -ne 0) { throw "La compilación del lector de sensores falló ($LASTEXITCODE)" }
Get-ChildItem $destino -Filter *.pdb | Remove-Item -Force
@"
Doctor PC usa LibreHardwareMonitorLib para leer los sensores de temperatura.
LibreHardwareMonitor se distribuye bajo la Mozilla Public License 2.0 (MPL-2.0).
Código fuente: https://github.com/LibreHardwareMonitor/LibreHardwareMonitor
Texto de la licencia: https://www.mozilla.org/MPL/2.0/

Dependencias incluidas: HidSharp (Apache-2.0) y otras bibliotecas de .NET con sus respectivas licencias.
"@ | Set-Content (Join-Path $destino 'LICENCIAS-TERCEROS.txt') -Encoding utf8
$exe = Join-Path $destino 'DoctorPC.Sensores.exe'
if (-not (Test-Path $exe)) { throw 'No se generó DoctorPC.Sensores.exe' }
Write-Host "Lector de sensores listo: $exe"
Get-ChildItem $destino | Format-Table Name, Length -AutoSize
