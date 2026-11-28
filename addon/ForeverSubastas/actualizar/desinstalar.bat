@echo off
rem Forever Subastas: quita la actualizacion automatica (tarea de cada hora y arranque al iniciar sesion).
schtasks /Delete /F /TN "ForeverSubastas"
del "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Forever Subastas.lnk" 2>nul
pause
