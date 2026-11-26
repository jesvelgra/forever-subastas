# Forever Subastas: descarga los datos y el codigo mas recientes del addon (se ejecuta cada hora).
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$addon = Split-Path -Parent $PSScriptRoot
$log = Join-Path $PSScriptRoot 'actualizar.log'
$base = 'https://github.com/jesvelgra/forever-subastas/releases/download/datos/'
# Fichero y como debe empezar para darlo por bueno.
$ficheros = @(
    @{ Nombre = 'Datos.lua';  Inicio = '-- Generado*' },
    @{ Nombre = 'Nucleo.lua'; Inicio = '-- Forever Subastas*' }
)
foreach ($f in $ficheros) {
    $temporal = Join-Path $env:TEMP ('ForeverSubastas_' + $f.Nombre)
    try {
        Invoke-WebRequest -Uri ($base + $f.Nombre) -OutFile $temporal -UseBasicParsing -TimeoutSec 180
        $primera = Get-Content -Path $temporal -TotalCount 1 -Encoding UTF8
        if ($primera -notlike $f.Inicio) { throw 'El fichero descargado no parece valido' }
        Copy-Item -Path $temporal -Destination (Join-Path $addon $f.Nombre) -Force
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm') OK $($f.Nombre)" | Out-File -FilePath $log -Append -Encoding utf8
    } catch {
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm') ERROR $($f.Nombre): $($_.Exception.Message)" | Out-File -FilePath $log -Append -Encoding utf8
    } finally {
        Remove-Item $temporal -ErrorAction SilentlyContinue
    }
}
if ((Test-Path $log) -and ((Get-Item $log).Length -gt 50KB)) {
    Get-Content $log -Tail 200 | Set-Content $log -Encoding utf8
}
