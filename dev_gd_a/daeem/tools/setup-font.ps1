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

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools/setup-font.ps1
    powershell -ExecutionPolicy Bypass -File tools/setup-font.ps1 -Force
#>
[CmdletBinding()]
param(
    # Overwrite an existing copy.
    [switch]$Force,
    # Preferred source file names, in order. First one that exists wins.
    [string[]]$Candidates = @('simhei.ttf', 'msyh.ttc', 'Deng.ttf', 'simsun.ttc')
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

# Skip work when a font is already in place.
$existing = @(Get-ChildItem -Path $fontDir -File -ErrorAction SilentlyContinue)
if ($existing.Count -gt 0 -and -not $Force) {
    Write-Host "Font already present, nothing to do (use -Force to re-copy):"
    $existing | ForEach-Object { Write-Host ("  {0}  ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB)) }
    exit 0
}

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

Write-Host ""
Write-Host "Done. assets/fonts/ is git-ignored on purpose (see .gitignore)."
exit 0
