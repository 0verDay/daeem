@echo off
rem =====================================================================
rem  see_ai_10.bat  --  run N rounds of see_ai (AI vs AI) headless.
rem
rem  Double-click  = 10 rounds, 20-minute (sim time) cap per round.
rem  Command line  = see_ai_10.bat [rounds] [cap_seconds]
rem                  e.g.  see_ai_10.bat 3 600
rem
rem  It only READS data\config.json (no file is written except the log).
rem  Same rounds+cap always reproduce the same matches (fixed seeds 1..N).
rem  Expect roughly 7 minutes for 10 rounds.
rem =====================================================================
chcp 65001 >nul
setlocal
cd /d "%~dp0"

rem --- where your Godot console build lives (edit if it moves) ---
set "GODOT=C:\D\GodotEngine\gd4.7.2mono\Godot_v4.7.2-stable_mono_win64_console.exe"
set "PROJ=%~dp0.."

if not exist "%GODOT%" (
    echo [error] Godot not found:
    echo         %GODOT%
    echo         edit the GODOT= line in this .bat to point at your console build.
    goto :done
)
if not exist "%PROJ%\data\config.json" (
    echo [error] config not found: %PROJ%\data\config.json
    goto :done
)
if not exist "%~dp0bench_see_ai.gd" (
    echo [error] bench_see_ai.gd not found next to this .bat.
    goto :done
)

set "ROUNDS=%~1"
if "%ROUNDS%"=="" set "ROUNDS=10"
set "CAP=%~2"
if "%CAP%"=="" set "CAP=1200"

set "SEE_AI_ROUNDS=%ROUNDS%"
set "SEE_AI_CAP=%CAP%"
set "SEE_AI_LOG=%~dp0see_ai_%ROUNDS%r.log"
if exist "%SEE_AI_LOG%" del "%SEE_AI_LOG%" >nul 2>&1

echo.
echo   see_ai  ^|  rounds = %ROUNDS%   cap = %CAP% s (sim time)
echo   project : %PROJ%
echo   log     : %SEE_AI_LOG%
echo   (Ctrl+C stops it; the log keeps whatever finished so far)
echo.

rem  Live console output AND a UTF-8 log. Godot prints UTF-8, so the
rem  PowerShell shim decodes it with the console encoding set by chcp 65001.
"%GODOT%" --headless --path "%PROJ%" --script tests/bench_see_ai.gd 2>&1 ^
    | powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Continue'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; $input | ForEach-Object { Write-Host $_; Add-Content -LiteralPath $env:SEE_AI_LOG -Value $_ -Encoding UTF8 }"

echo.
echo   ---- aggregate ----
if exist "%SEE_AI_LOG%" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Content -LiteralPath $env:SEE_AI_LOG -Encoding UTF8 | Select-String -SimpleMatch '[agg]' | ForEach-Object { $_.Line }"
) else (
    echo   (no log written)
)
echo.
echo   full log: %SEE_AI_LOG%
echo.

:done
pause
endlocal
