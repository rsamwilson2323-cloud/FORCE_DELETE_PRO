@echo off
setlocal EnableExtensions
title FORCE DELETE PRO

rem ---------------------------------------------------------------
rem FORCE DELETE PRO - launcher
rem Starts ForceDelete.ps1 from the folder this file lives in.
rem Works from folders whose path contains spaces or parentheses.
rem Administrator elevation is requested by ForceDelete.ps1 itself.
rem Optional: drag a file/folder onto this .bat, or pass a quoted path.
rem ---------------------------------------------------------------

set "FD_DIR=%~dp0"
set "FD_PS1=%FD_DIR%ForceDelete.ps1"

if not exist "%FD_PS1%" goto :missing

set "FD_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%FD_POWERSHELL%" set "FD_POWERSHELL=powershell.exe"

"%FD_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%FD_PS1%" %*
set "FD_RC=%ERRORLEVEL%"

if not "%FD_RC%"=="0" pause
endlocal & exit /b %FD_RC%

:missing
echo.
echo ERROR: Cannot find "%FD_PS1%".
echo Keep FORCE_DELETE.bat and ForceDelete.ps1 in the same folder.
echo.
pause
endlocal & exit /b 2
