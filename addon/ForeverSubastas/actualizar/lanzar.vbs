' Forever Subastas: ejecuta actualizar.ps1 sin abrir ninguna ventana.
Set fso = CreateObject("Scripting.FileSystemObject")
carpeta = fso.GetParentFolderName(WScript.ScriptFullName)
comando = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & carpeta & "\actualizar.ps1"""
CreateObject("WScript.Shell").Run comando, 0, False
