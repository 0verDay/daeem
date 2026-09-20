<#
.SYNOPSIS
    DAEEM (Godot) one-command test runner. See README-tools.md (Chinese notes).

.DESCRIPTION
    Runs every tests/test_*.gd with `--headless --script` and decides pass/fail by
    EXIT CODE (not by parsing text). Any failing file makes the whole runner exit 1.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1
    powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_path
    powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -List
#>
[CmdletBinding()]
param(
    # Only run test files whose name contains this fragment.
    [string]$Filter = "",
    # Only list the files that would run.
    [switch]$List,
    # Path to the Godot *console* executable. Defaults to $env:GODOT_EXE.
    [string]$Godot = ""
)

$ErrorActionPreference = 'Continue'

# NOTE: keep this file pure ASCII.
# Chinese Windows PowerShell 5.1 reads a BOM-less .ps1 as GBK, so any non-ASCII
# literal here turns into mojibake and breaks parsing. Chinese notes live in
# tools/README-tools.md instead. (-Encoding UTF8 when reading is NOT enough:
# the engine decodes the file before the script can set anything.)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# tools/ sits directly under the Godot project root (dev_gd_a/daeem/tools/)
$projectDir = Split-Path -Parent $PSScriptRoot
$testsDir = Join-Path $projectDir 'tests'

if (-not $Godot) {
    if ($env:GODOT_EXE) {
        # Environment variable wins so that another machine needs no edit.
        $Godot = $env:GODOT_EXE
    } else {
        # MUST be the .NET (mono) build: the project has a C# assembly (daeem.csproj)
        # that the plain build cannot load, so tests would fail for the wrong reason.
        $Godot = 'C:\D\GodotEngine\gd4.7.2mono\Godot_v4.7.2-stable_mono_win64_console.exe'
    }
}

# MUST be the _console.exe build: the GUI build detaches, so stdout cannot be
# captured and $LASTEXITCODE stays empty.
if (-not (Test-Path $Godot)) {
    Write-Host "Godot executable not found: $Godot" -ForegroundColor Red
    Write-Host "Set env GODOT_EXE to the ..._console.exe path, or pass -Godot." -ForegroundColor Yellow
    exit 2
}
if ($Godot -notmatch '_console\.exe$') {
    Write-Host "Warning: $Godot is not a _console.exe build; output/exit code may be unreliable." -ForegroundColor Yellow
}
if (-not (Test-Path $projectDir)) {
    Write-Host "Godot project directory not found: $projectDir" -ForegroundColor Red
    exit 2
}

$files = @(Get-ChildItem -Path $testsDir -Filter 'test_*.gd' -File | Sort-Object Name)
# test_case.gd is the shared scaffold (it deliberately fails when run directly),
# not a test case.
$files = @($files | Where-Object { $_.Name -ne 'test_case.gd' })
if ($Filter) { $files = @($files | Where-Object { $_.Name -like "*$Filter*" }) }

if ($files.Count -eq 0) {
    Write-Host "No test files found ($testsDir\test_*.gd)" -ForegroundColor Red
    exit 2
}

if ($List) {
    Write-Host "Would run $($files.Count) test file(s):"
    $files | ForEach-Object { Write-Host "  $($_.Name)" }
    exit 0
}

Write-Host ""
Write-Host "DAEEM Godot tests" -ForegroundColor Cyan
Write-Host "  engine : $Godot"
Write-Host "  project: $projectDir"
Write-Host "  files  : $($files.Count)"
Write-Host ""

$results = @()
$totalPass = 0
$totalFail = 0
$failedFiles = @()

foreach ($f in $files) {
    $rel = "res://tests/$($f.Name)"
    $raw = & $Godot --headless --path $projectDir --script $rel 2>&1
    $code = $LASTEXITCODE
    $text = ($raw | Out-String)

    # Only trust our own [CASE] summary lines; engine noise (certificate store,
    # unwritable user:// log) must not be counted.
    # Numbers are pulled out by \D* so that the Chinese words inside the summary
    # can never affect parsing (and so this file stays ASCII-only).
    $summary = [regex]::Match($text, '\[CASE\]\s+\S+\s+->\s*\D*(\d+)\D+(\d+)')
    $pass = 0
    $fail = 0
    if ($summary.Success) {
        $pass = [int]$summary.Groups[1].Value
        $fail = [int]$summary.Groups[2].Value
    }

    $totalPass += $pass
    $totalFail += $fail

    # A crash / parse error prints no summary line; that MUST count as failure,
    # otherwise a broken test file would look like a green light.
    $ok = ($code -eq 0) -and $summary.Success -and ($fail -eq 0)
    if (-not $ok) { $failedFiles += $f.Name }

    if ($ok) {
        Write-Host ("  [OK]   {0,-26} pass {1,4} / fail {2}" -f $f.Name, $pass, $fail) -ForegroundColor Green
    } else {
        Write-Host ("  [FAIL] {0,-26} pass {1,4} / fail {2} / exit {3}" -f $f.Name, $pass, $fail, $code) -ForegroundColor Red
        ($raw | Select-String -Pattern '\[FAIL\]|SCRIPT ERROR|Parse Error|Compile Error' | Select-Object -First 12) |
            ForEach-Object { Write-Host "         $($_.Line.Trim())" -ForegroundColor DarkYellow }
    }

    $results += [pscustomobject]@{
        File = $f.Name
        Pass = $pass
        Fail = $fail
        Exit = $code
        Ok   = $ok
    }
}

Write-Host ""
Write-Host "Summary:" -ForegroundColor Cyan
$results | Format-Table -AutoSize File, Pass, Fail, Exit, Ok | Out-String | Write-Host
Write-Host ("files {0} / assertions {1} / pass {2} / fail {3}" -f `
    $files.Count, ($totalPass + $totalFail), $totalPass, $totalFail)

if ($failedFiles.Count -gt 0) {
    Write-Host ("failed files: {0}" -f ($failedFiles -join ', ')) -ForegroundColor Red
    exit 1
}
Write-Host "ALL PASS" -ForegroundColor Green
exit 0
