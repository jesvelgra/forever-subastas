# Forever Subastas: descarga los datos y el codigo mas recientes del addon.
# Se ejecuta cada hora (tarea programada) y al iniciar sesion en Windows (acceso directo en Inicio).
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$addon = Split-Path -Parent $PSScriptRoot
$log = Join-Path $PSScriptRoot 'actualizar.log'
$base = 'https://github.com/jesvelgra/forever-subastas/releases/download/datos/'

function Anotar($texto) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm') $texto" | Out-File -FilePath $log -Append -Encoding utf8
}

# Solo una copia a la vez (al encender el PC pueden coincidir el inicio y la tarea de cada hora).
$mutex = New-Object System.Threading.Mutex($false, 'ForeverSubastasActualizar')
try { $tengo = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $tengo = $true }
if (-not $tengo) { exit }

try {
    # Arrancar tambien al iniciar sesion: acceso directo en la carpeta Inicio (no necesita permisos de administrador).
    try {
        $inicio = [Environment]::GetFolderPath('Startup')
        $atajo = Join-Path $inicio 'Forever Subastas.lnk'
        $lanzador = Join-Path $PSScriptRoot 'lanzar.vbs'
        if ($inicio -and -not (Test-Path $atajo)) {
            $shell = New-Object -ComObject WScript.Shell
            $lnk = $shell.CreateShortcut($atajo)
            $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
            $lnk.Arguments = '"' + $lanzador + '"'
            $lnk.WorkingDirectory = $PSScriptRoot
            $lnk.Description = 'Forever Subastas: actualiza los datos del addon al iniciar sesion'
            $lnk.Save()
            Anotar 'OK acceso directo en Inicio'
        }
    } catch {
        Anotar "ERROR acceso directo en Inicio: $($_.Exception.Message)"
    }

    # Fichero, como debe empezar para darlo por bueno y donde va.
    $ficheros = @(
        @{ Nombre = 'Datos.lua';      Inicio = '-- Generado*';         Destino = $addon },
        @{ Nombre = 'Nucleo.lua';     Inicio = '-- Forever Subastas*'; Destino = $addon },
        @{ Nombre = 'actualizar.ps1'; Inicio = '# Forever Subastas*';  Destino = $PSScriptRoot }
    )
    foreach ($f in $ficheros) {
        $temporal = Join-Path $env:TEMP ('ForeverSubastas_' + $f.Nombre)
        # Al iniciar sesion la red puede tardar un poco: hasta 6 intentos, 20 s entre uno y otro.
        for ($intento = 1; $intento -le 6; $intento++) {
            try {
                Invoke-WebRequest -Uri ($base + $f.Nombre) -OutFile $temporal -UseBasicParsing -TimeoutSec 180
                $primera = Get-Content -Path $temporal -TotalCount 1 -Encoding UTF8
                if ($primera -notlike $f.Inicio) { throw 'El fichero descargado no parece valido' }
                Copy-Item -Path $temporal -Destination (Join-Path $f.Destino $f.Nombre) -Force
                Anotar "OK $($f.Nombre)"
                break
            } catch {
                if ($intento -ge 6) {
                    Anotar "ERROR $($f.Nombre): $($_.Exception.Message)"
                } else {
                    Start-Sleep -Seconds 20
                }
            } finally {
                Remove-Item $temporal -ErrorAction SilentlyContinue
            }
        }
    }
    if ((Test-Path $log) -and ((Get-Item $log).Length -gt 50KB)) {
        Get-Content $log -Tail 200 | Set-Content $log -Encoding utf8
    }
} finally {
    $mutex.ReleaseMutex()
}
