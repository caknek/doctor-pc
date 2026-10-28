# Doctor PC — permite medir FPS sin ejecutar como administrador.
# Añade al usuario indicado al grupo integrado "Usuarios del registro de rendimiento" (SID S-1-5-32-559),
# que Windows exige para leer los eventos de fotogramas (ETW) que usa PresentMon.
# Se ejecuta con permiso de administrador (UAC). Códigos de salida: 0 añadido, 2 ya era miembro, 1 error.
param([Parameter(Mandatory = $true)][string]$Sid)
$ErrorActionPreference = 'Stop'
$log = if ($Registro) { $Registro } else { Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'DoctorPC\Informes\registro_cambios.log' }
function Anotar([string]$t) { try { Add-Content -Path $log -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $t) -Encoding UTF8 } catch { } }
try {
    if ($Sid -notmatch '^S-1-5-[\d-]+$') { throw "SID no válido: $Sid" }
    $grupoSid = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-559'
    $usuarioSid = New-Object Security.Principal.SecurityIdentifier $Sid
    $grupo = $grupoSid.Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
    $cuenta = $usuarioSid.Translate([Security.Principal.NTAccount]).Value
    # ¿ya es miembro?
    $miembros = @()
    try { $miembros = @(Get-LocalGroupMember -SID 'S-1-5-32-559' -ErrorAction Stop | ForEach-Object { $_.SID.Value }) } catch { }
    if ($miembros -contains $Sid) { Anotar "FPS: $cuenta ya estaba en '$grupo'"; exit 2 }
    $hecho = $false
    try { Add-LocalGroupMember -SID 'S-1-5-32-559' -Member $usuarioSid -ErrorAction Stop; $hecho = $true }
    catch {
        if ("$($_.FullyQualifiedErrorId)" -like '*MemberExists*') { Anotar "FPS: $cuenta ya estaba en '$grupo'"; exit 2 }
    }
    if (-not $hecho) {
        $salida = & net.exe localgroup "$grupo" "$cuenta" /add 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            if ($salida -match '1378') { Anotar "FPS: $cuenta ya estaba en '$grupo'"; exit 2 }
            throw "net localgroup: $salida"
        }
    }
    Anotar "FPS: $cuenta añadido a '$grupo' (para medir FPS sin administrador)"
    exit 0
}
catch {
    Anotar "FPS: no se pudo dar el permiso: $($_.Exception.Message)"
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
