@echo off
rem Forever Subastas: programa la actualizacion automatica de los datos (cada hora).
schtasks /Create /F /TN "ForeverSubastas" /SC HOURLY /MO 1 /TR "wscript.exe \"%~dp0lanzar.vbs\""
if errorlevel 1 goto error
schtasks /Run /TN "ForeverSubastas"
echo.
echo Listo: los datos del addon se actualizaran solos al encender el PC y luego cada hora.
echo Ya puedes cerrar esta ventana.
pause
exit /b 0
:error
echo.
echo No se pudo crear la tarea programada.
pause
exit /b 1
