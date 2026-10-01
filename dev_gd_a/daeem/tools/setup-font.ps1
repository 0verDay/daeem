<#
.SYNOPSIS
    Copy a CJK font from the system into assets/fonts/ so the HUD is readable.

.DESCRIPTION
    Godot's built-in font has no CJK glyphs, so every Chinese character in the HUD
    and the event log would render as a tofu box. This script copies one font from
    C:\Windows\Fonts into assets/fonts/ (which is git-ignored: fonts are large
    binaries and their licences do not belong in a public repo).

    Run it once per machine. view/font_loader.gd then picks the file up from
    data/config.json -> font.asset_path.

    * The copy alone is NOT enough, so this script also runs `--headless --import`.
      font_loader.gd looks in `res://assets/fonts/...` FIRST, and that path only
      resolves after Godot has imported the file (a `.import` next to it).
      Without the import the loader falls through to C:\Windows\Fonts and loads a
      DIFFERENT font than the one just copied -- the game still shows Chinese, but
      with other metrics, and 4 layout assertions in tests/test_ui.gd fail for a
      reason that has nothing to do with the code (verified on a fresh machine).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools/setup-font.ps1
    powershell -ExecutionPolicy Bypass -File tools/setup-font.ps1 -Force
#>
[CmdletBinding()]
param(
    # Overwrite an existing copy.
    [switch]$Force,
    # Preferred source file names, in order. First one that exists wins.
    [string[]]$Candidates = @('simhei.ttf', 'msyh.ttc', 'Deng.ttf', 'simsun.ttc'),
    # Path to the Godot *console* executable. Defaults to $env:GODOT_EXE.
    [string]$Godot = ""
)

# NOTE: keep this file pure ASCII. Chinese Windows PowerShell 5.1 decodes a
# BOM-less .ps1 as GBK, so non-ASCII literals here break parsing.
# Chinese notes live in tools/README-tools.md.
$ErrorActionPreference = 'Stop'

$projectDir = Split-Path -Parent $PSScriptRoot
$fontDir = Join-Path $projectDir 'assets\fonts'
$fontSource = Join-Path $env:WINDIR 'Fonts'

if (-not (Test-Path $fontSource)) {
    Write-Host "System font directory not found: $fontSource" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $fontDir)) {
    New-Item -ItemType Directory -Path $fontDir -Force | Out-Null
    Write-Host "created $fontDir"
}

# Skip the copy when a font is already in place (but still import below: an
# earlier run of this script may have copied the file without importing it).
$existing = @(Get-ChildItem -Path $fontDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike '*.import' })
if ($existing.Count -gt 0 -and -not $Force) {
    Write-Host "Font already present, skipping the copy (use -Force to re-copy):"
    $existing | ForEach-Object { Write-Host ("  {0}  ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB)) }
} else {
    $copied = $false
    foreach ($name in $Candidates) {
        $src = Join-Path $fontSource $name
        if (-not (Test-Path $src)) { continue }
        $dst = Join-Path $fontDir $name
        Copy-Item -Path $src -Destination $dst -Force
        $size = (Get-Item $dst).Length / 1MB
        Write-Host ("copied {0} -> assets/fonts/{0}  ({1:N1} MB)" -f $name, $size) -ForegroundColor Green
        $copied = $true
        break
    }

    if (-not $copied) {
        Write-Host "No usable CJK font found. Looked for:" -ForegroundColor Red
        $Candidates | ForEach-Object { Write-Host "  $fontSource\$_" }
        Write-Host "The game still runs, but Chinese text falls back to tofu boxes." -ForegroundColor Yellow
        exit 1
    }
}

# ---- import (this is what makes res://assets/fonts/ actually loadable) --------
#
# Godot writes noise to stderr (it cannot save editor_settings under a sandboxed
# %APPDATA%), and with $ErrorActionPreference = 'Stop' PowerShell 5.1 turns
# native stderr into a terminating error -- so relax it for this call only.
$ErrorActionPreference = 'Continue'

if (-not $Godot) {
    if ($env:GODOT_EXE) {
        $Godot = $env:GODOT_EXE
    } else {
        # Same convention as tools/run-tests.ps1: mono build, _console.exe.
        $Godot = 'C:\D\GodotEngine\gd4.7.2mono\Godot_v4.7.2-stable_mono_win64_console.exe'
    }
}

if (-not (Test-Path $Godot)) {
    Write-Host ""
    Write-Host "Godot not found: $Godot" -ForegroundColor Yellow
    Write-Host "assets/fonts/ is not imported yet, so font_loader.gd will still fall" -ForegroundColor Yellow
    Write-Host "back to a system font (and tests/test_ui.gd can go red on font metrics)." -ForegroundColor Yellow
    Write-Host "Fix it by either:" -ForegroundColor Yellow
    Write-Host "  - setting GODOT_EXE (or -Godot) and re-running this script, or" -ForegroundColor Yellow
    Write-Host "  - opening the project in the Godot editor once." -ForegroundColor Yellow
    exit 0
}
if ($Godot -notmatch '_console\.exe$') {
    Write-Host "Warning: $Godot is not a _console.exe build; the exit code may be unreliable." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "importing assets/fonts/ ..." -ForegroundColor Cyan
$importOut = & $Godot --headless --path $projectDir --import 2>&1
$importCode = $LASTEXITCODE

if ($null -eq $importCode) {
    # A GUI build detaches, so there is no exit code to trust.
    Write-Host "no exit code from the engine (GUI build?): use the _console.exe" -ForegroundColor Red
    exit 1
}
if ($importCode -ne 0) {
    Write-Host "import failed (exit $importCode), last lines:" -ForegroundColor Red
    $importOut | Select-Object -Last 20 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }
    exit 1
}

# Don't trust "exit 0" alone: check that the .import file font_loader.gd needs exists.
$imported = @(Get-ChildItem -Path $fontDir -File -Filter '*.import' -ErrorAction SilentlyContinue)
if ($imported.Count -eq 0) {
    Write-Host "import ran but produced no .import file in assets/fonts/ -- font_loader.gd" -ForegroundColor Red
    Write-Host "would still fall back to a system font. Try opening the project in the editor." -ForegroundColor Red
    exit 1
}
$imported | ForEach-Object { Write-Host ("imported {0}" -f $_.Name) -ForegroundColor Green }

Write-Host ""
Write-Host "Done. assets/fonts/ is git-ignored on purpose (see .gitignore)."
exit 0
