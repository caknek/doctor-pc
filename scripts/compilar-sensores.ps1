# Compila el lector de sensores (sensores/) y lo deja en engine/sensores con la licencia de LibreHardwareMonitor.
# Requiere el SDK de .NET (incluido en los equipos windows-latest de GitHub Actions).
$ErrorActionPreference = 'Stop'
$raiz = Split-Path $PSScriptRoot -Parent
$destino = Join-Path $raiz 'engine/sensores'
if (Test-Path $destino) { Remove-Item $destino -Recurse -Force }
dotnet publish (Join-Path $raiz 'sensores/DoctorPC.Sensores.csproj') -c Release -o $destino --nologo
if ($LASTEXITCODE -ne 0) { throw "La compilación del lector de sensores falló ($LASTEXITCODE)" }
Get-ChildItem $destino -Filter *.pdb | Remove-Item -Force

# PresentMon (Intel, MIT) para medir los FPS del overlay. Versión fija y comprobada con SHA-256.
$pmVersion = '2.4.1'
$pmSha256 = 'D74183E7AE630F72CD3690BE0373ECBFDC6CBB86578148AAB8FA2A7166068F34'
$pmUrl = "https://github.com/GameTechDev/PresentMon/releases/download/v$pmVersion/PresentMon-$pmVersion-x64.exe"
$pmExe = Join-Path $destino 'PresentMon.exe'
$intentos = 0
while ($true) {
    try { Invoke-WebRequest -Uri $pmUrl -OutFile $pmExe -UseBasicParsing; break }
    catch { $intentos++; if ($intentos -ge 3) { throw "No se pudo descargar PresentMon: $($_.Exception.Message)" }; Start-Sleep -Seconds 5 }
}
$hash = (Get-FileHash $pmExe -Algorithm SHA256).Hash
if ($hash -ne $pmSha256) { Remove-Item $pmExe -Force; throw "PresentMon con SHA-256 inesperado: $hash" }
Write-Host "PresentMon $pmVersion descargado y verificado"
@"
Doctor PC usa LibreHardwareMonitorLib para leer los sensores de temperatura.
LibreHardwareMonitor se distribuye bajo la Mozilla Public License 2.0 (MPL-2.0).
Código fuente: https://github.com/LibreHardwareMonitor/LibreHardwareMonitor
Texto de la licencia: https://www.mozilla.org/MPL/2.0/

Dependencias incluidas: HidSharp (Apache-2.0) y otras bibliotecas de .NET con sus respectivas licencias.

PresentMon.exe (versión $pmVersion) mide los FPS del overlay.
PresentMon es de Intel Corporation y se distribuye bajo la licencia MIT.
Código fuente: https://github.com/GameTechDev/PresentMon

Copyright (C) 2017-2024 Intel Corporation
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
to permit persons to whom the Software is furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all copies or substantial portions
of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
"@ | Set-Content (Join-Path $destino 'LICENCIAS-TERCEROS.txt') -Encoding utf8
$exe = Join-Path $destino 'DoctorPC.Sensores.exe'
if (-not (Test-Path $exe)) { throw 'No se generó DoctorPC.Sensores.exe' }
Write-Host "Lector de sensores listo: $exe"
Get-ChildItem $destino | Format-Table Name, Length -AutoSize
