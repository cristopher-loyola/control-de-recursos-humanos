# Genera el certificado HTTPS del servidor de la oficina (10 años, EC P-256).
# Las tablets fijan su huella al vincularse: reemplazarlo obliga a volver a
# vincular cada tablet.
#
# Uso (desde la raíz del repositorio):
#   ./deploy/generar-certificado.ps1 -Servidor 192.168.1.50
#   ./deploy/generar-certificado.ps1 -Servidor 192.168.1.50,rh-servidor.local
param(
    [Parameter(Mandatory = $true)]
    [string[]] $Servidor,
    [switch] $Reemplazar
)

$ErrorActionPreference = 'Stop'
$dir = Join-Path $PSScriptRoot 'certs'
$crt = Join-Path $dir 'servidor.crt'
$key = Join-Path $dir 'servidor.key'

if ((Test-Path $crt) -and -not $Reemplazar) {
    throw "Ya existe $crt. Usa -Reemplazar solo si vas a volver a vincular todas las tablets."
}

$openssl = Get-Command openssl -ErrorAction SilentlyContinue
if (-not $openssl) {
    $git = Join-Path ${env:ProgramFiles} 'Git\usr\bin\openssl.exe'
    if (Test-Path $git) { $openssl = $git } else { throw 'No encontré openssl (viene con Git para Windows).' }
}

$san = ($Servidor | ForEach-Object {
    if ($_ -match '^\d{1,3}(\.\d{1,3}){3}$') { "IP:$_" } else { "DNS:$_" }
}) -join ','

New-Item -ItemType Directory -Force $dir | Out-Null
& $openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes `
    -keyout $key -out $crt -days 3650 -subj "/CN=$($Servidor[0])" `
    -addext "subjectAltName=$san" -addext 'basicConstraints=critical,CA:FALSE' `
    -addext 'keyUsage=critical,digitalSignature' -addext 'extendedKeyUsage=serverAuth'
if ($LASTEXITCODE -ne 0) { throw 'openssl no pudo generar el certificado.' }

$fingerprint = (& $openssl x509 -in $crt -noout -fingerprint -sha256) -replace '^.*=', '' -replace ':', ''
$short = ($fingerprint.Substring(0, 16) -split '(.{4})' | Where-Object { $_ }) -join ' '
Write-Host ''
Write-Host "Certificado: $crt"
Write-Host "Huella del servidor: $short"
Write-Host 'Compárala con la que muestra cada tablet al vincularse.'
Write-Host 'No subas deploy/certs al repositorio: la llave privada debe quedarse en el servidor.'
