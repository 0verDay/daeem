<#
.SYNOPSIS
    Parse/compile every .gd file in the project with the Godot CLI.

.DESCRIPTION
    Runs `--check-only --script` for each .gd file (skipping .godot/). This catches
    GDScript parse and compile errors much earlier and with exact line numbers,
    without executing anything.

    Two GDScript facts this tool exists to enforce (both measured on 4.7.2):
      * global `class_name` is NOT resolvable in --script mode, so cross-file types
        must come from a per-file `const X = preload(...)`;
      * a script that fails to compile can make the Godot CLI HANG, so every
        invocation here has a timeout and is killed if it overruns.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools/check-syntax.ps1
    powershell -ExecutionPolicy Bypass -File tools/check-syntax.ps1 -Godot "C:\...\Godot_..._console.exe"
#>
[CmdletBinding()]
param(
    [string]$Godot = "",
    # Which subdirectories to scan, relative to the project root.
    [string[]]$Dirs = @('logic', 'view', 'tests'),
    [int]$TimeoutSec = 45
)

# NOTE: keep this file pure ASCII (PowerShell 5.1 decodes BOM-less .ps1 as GBK).
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$projectDir = Split-Path -Parent $PSScriptRoot

if (-not $Godot) {
    if ($env:GODOT_EXE) { $Godot = $env:GODOT_EXE }
    else { $Godot = 'C:\D\GodotEngine\Godot_v4.7.2-stable_win64_console.exe' }
}
if (-not (Test-Path $Godot)) {
    Write-Host "Godot executable not found: $Godot" -ForegroundColor Red
    exit 2
}

$files = @()
foreach ($d in $Dirs) {
    $full = Join-Path $projectDir $d
    if (-not (Test-Path $full)) { continue }
    $files += @(Get-ChildItem -Path $full -Recurse -Filter '*.gd' -File)
}
# The shared scaffold deliberately fails when executed; skip it here too.
$files = @($files | Where-Object { $_.Name -ne 'test_case.gd' } | Sort-Object FullName)

if ($files.Count -eq 0) {
    Write-Host "No .gd files found under: $($Dirs -join ', ')" -ForegroundColor Red
    exit 2
}

Write-Host "Syntax check: $($files.Count) file(s)"
Write-Host ""

$bad = @()
foreach ($f in $files) {
    $rel = 'res://' + ($f.FullName.Substring($projectDir.Length + 1) -replace '\\', '/')
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $p = Start-Process -FilePath $Godot `
        -ArgumentList '--headless', '--path', $projectDir, '--check-only', '--script', $rel `
        -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $finished = $p.WaitForExit($TimeoutSec * 1000)
    if (-not $finished) {
        # A non-compiling script can hang the CLI; that itself is a failure.
        try { $p.Kill() } catch { }
        Write-Host ("  [HANG] {0}  (killed after {1}s)" -f $rel, $TimeoutSec) -ForegroundColor Red
        $bad += $rel
    } else {
        $text = (Get-Content -Raw -ErrorAction SilentlyContinue $outFile) + (Get-Content -Raw -ErrorAction SilentlyContinue $errFile)
        $issues = @()
        if ($text) {
            $issues = @($text -split "`r?`n" | Where-Object {
                $_ -match 'SCRIPT ERROR|Parse Error|Compile Error'
            })
        }
        if ($issues.Count -gt 0) {
            Write-Host ("  [FAIL] {0}" -f $rel) -ForegroundColor Red
            $issues | Select-Object -First 8 | ForEach-Object { Write-Host "         $($_.Trim())" -ForegroundColor DarkYellow }
            $bad += $rel
        } else {
            Write-Host ("  [OK]   {0}" -f $rel) -ForegroundColor Green
        }
    }
    Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
}

Write-Host ""
if ($bad.Count -gt 0) {
    Write-Host ("FAILED: {0} of {1} file(s) have parse/compile errors" -f $bad.Count, $files.Count) -ForegroundColor Red
    exit 1
}
Write-Host ("ALL OK: {0} file(s) parse and compile" -f $files.Count) -ForegroundColor Green
exit 0
