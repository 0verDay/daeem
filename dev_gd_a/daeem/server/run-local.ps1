<#
.SYNOPSIS
    One-command local M12.3 smoke test: relay + host probe + guest probe.

.DESCRIPTION
    Starts the Python relay on 127.0.0.1:8770, waits for /health, then starts
    two independent probe processes. The host creates room CAMP23, the guest
    joins, both ready, host starts, guest sends one command, host sends one
    snapshot, host says bye. Exit 0 only when both probes exit 0.

    This file is ASCII-only on purpose (Windows PowerShell 5.1 reads BOM-less
    .ps1 as GBK).
#>
param(
    [string]$Python = "",
    [int]$Port = 8770
)

$ErrorActionPreference = "Continue"
$serverDir = $PSScriptRoot
$logDir = Join-Path $serverDir "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

if (-not $Python) {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { $Python = $cmd.Source }
}
if (-not $Python -or -not (Test-Path $Python)) {
    Write-Host "python not found; pass -Python C:\path\python.exe" -ForegroundColor Red
    exit 2
}

$relayOut = Join-Path $logDir "relay.out.log"
$relayErr = Join-Path $logDir "relay.err.log"
$hostOut = Join-Path $logDir "host.out.log"
$hostErr = Join-Path $logDir "host.err.log"
$guestOut = Join-Path $logDir "guest.out.log"
$guestErr = Join-Path $logDir "guest.err.log"

$relay = $null
$hostP = $null
$guestP = $null
$failed = $false

function Show-Log([string]$label, [string]$path) {
    Write-Host "--- $label"
    if (Test-Path $path) { Get-Content $path -ErrorAction SilentlyContinue }
}

try {
    $relay = Start-Process -FilePath $Python `
        -ArgumentList @((Join-Path $serverDir "daeem_relay.py"), "--host", "127.0.0.1", "--port", "$Port") `
        -WorkingDirectory $serverDir `
        -RedirectStandardOutput $relayOut -RedirectStandardError $relayErr `
        -PassThru

    $healthy = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 200
        try {
            $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 1
            if ($health.ok) { $healthy = $true; break }
        } catch { }
        if ($relay.HasExited) { break }
    }
    if (-not $healthy) {
        throw "relay did not become healthy on port $Port"
    }

    $url = "ws://127.0.0.1:$Port/ws"
    $room = "CAMP23"
    $hostP = Start-Process -FilePath $Python `
        -ArgumentList @((Join-Path $serverDir "probe_relay.py"), "--role", "host", "--url", $url, "--room", $room) `
        -WorkingDirectory $serverDir `
        -RedirectStandardOutput $hostOut -RedirectStandardError $hostErr `
        -PassThru
    Start-Sleep -Milliseconds 600
    $guestP = Start-Process -FilePath $Python `
        -ArgumentList @((Join-Path $serverDir "probe_relay.py"), "--role", "guest", "--url", $url, "--room", $room) `
        -WorkingDirectory $serverDir `
        -RedirectStandardOutput $guestOut -RedirectStandardError $guestErr `
        -PassThru

    if (-not $guestP.WaitForExit(20000)) { $failed = $true }
    if (-not $hostP.WaitForExit(20000)) { $failed = $true }
    $guestP.Refresh()
    $hostP.Refresh()
    # Windows PowerShell 5.1 can leave Start-Process.ExitCode null for a
    # redirected child; use the probes' explicit OK lines instead.
    if (-not (Select-String -Path $guestOut -Pattern "PROBE guest OK" -Quiet -ErrorAction SilentlyContinue)) {
        $failed = $true
    }
    if (-not (Select-String -Path $hostOut -Pattern "PROBE host OK" -Quiet -ErrorAction SilentlyContinue)) {
        $failed = $true
    }
} catch {
    Write-Host "run-local failed: $_" -ForegroundColor Red
    $failed = $true
} finally {
    if ($guestP -and -not $guestP.HasExited) { Stop-Process -Id $guestP.Id -Force -ErrorAction SilentlyContinue }
    if ($hostP -and -not $hostP.HasExited) { Stop-Process -Id $hostP.Id -Force -ErrorAction SilentlyContinue }
    if ($relay -and -not $relay.HasExited) { Stop-Process -Id $relay.Id -Force -ErrorAction SilentlyContinue }
}

Show-Log "host" $hostOut
if (Test-Path $hostErr) { Get-Content $hostErr -ErrorAction SilentlyContinue }
Show-Log "guest" $guestOut
if (Test-Path $guestErr) { Get-Content $guestErr -ErrorAction SilentlyContinue }
Show-Log "relay" $relayOut

if ($failed) {
    Write-Host "RUN LOCAL FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "RUN LOCAL OK" -ForegroundColor Green
exit 0
