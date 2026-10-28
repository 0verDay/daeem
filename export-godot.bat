@echo off
rem ==================================================================
rem  Double-click this file to export every Godot project found under
rem  this folder to Windows desktop and Android.
rem
rem  The export logic lives in export-godot.ps1 (Chinese messages there).
rem  Keep this .bat ASCII-only: cmd.exe reads batch files with the
rem  console code page and mangles non-ASCII text.
rem
rem  With arguments they are passed through to export-godot.ps1 and the
rem  window closes by itself. Example:
rem      export-godot.bat -Platforms Windows
rem ==================================================================
setlocal EnableExtensions
chcp 65001 >nul 2>nul
cd /d "%~dp0"

set "SCRIPT=%~dp0export-godot.ps1"
if not exist "%SCRIPT%" (
    echo.
    echo [ERROR] export-godot.ps1 not found next to this .bat
    echo.
    pause
    exit /b 1
)

set "PSEXE=powershell.exe"
where pwsh.exe >nul 2>nul && set "PSEXE=pwsh.exe"

title Godot Export - Windows / Android
"%PSEXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"

echo.
if "%~1"=="" pause
exit /b %RC%
