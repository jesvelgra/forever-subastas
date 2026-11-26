# Forever Subastas: descarga los datos mas recientes del addon (se ejecuta cada hora).
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$addon = Split-Path -Parent $PSScriptRoot
$destino = Join-Path $addon 'Datos.lua'
$temporal = Join-Path $env:TEMP 'ForeverSubastas_Datos.lua'
$log = Join-Path $PSScriptRoot 'actualizar.log'
$url = 'https://github.com/jesvelgra/forever-subastas/releases/download/datos/Datos.lua'
try {
    Invoke-WebRequest -Uri $url -OutFile $temporal -UseBasicParsing -TimeoutSec 180
    $inicio = Get-Content -Path $temporal -TotalCount 1 -Encoding UTF8
    if ($inicio -notlike '-- Generado*') { throw 'El fichero descargado no parece valido' }
    Copy-Item -Path $temporal -Destination $destino -Force
    Remove-Item $temporal -ErrorAction SilentlyContinue
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm') OK" | Out-File -FilePath $log -Append -Encoding utf8
} catch {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm') ERROR $($_.Exception.Message)" | Out-File -FilePath $log -Append -Encoding utf8
}
if ((Test-Path $log) -and ((Get-Item $log).Length -gt 50KB)) {
    Get-Content $log -Tail 200 | Set-Content $log -Encoding utf8
}
