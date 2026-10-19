<#
.SYNOPSIS
    Deploy the DAEEM co-op relay to a Windows host with nssm.

.DESCRIPTION
    Idempotent deployment for server/daeem_relay.py:
      1. preflight: admin, Python, nssm, source file, TCP port
      2. back up the current install, then stop the existing service (if any)
      3. copy only the runtime files (daeem_relay.py + README.md)
      4. install or update the nssm service and start it
      5. wait for /health; on failure restore the backup and report clearly

    The script never touches IIS, port 443, or the deployed logs directory.

    This file is ASCII-only on purpose (Windows PowerShell 5.1 reads BOM-less
    .ps1 as GBK).

.PARAMETER ServerRoot
    Root used on the server. The relay lives in <ServerRoot>\server and logs
    in <ServerRoot>\logs. Default: C:\daeem

.PARAMETER Python
    Full path to python.exe. Empty = find on PATH or in common install paths.

.PARAMETER Nssm
    Full path to nssm.exe. Empty = find on PATH or in common install paths.

.PARAMETER Port
    Relay TCP port. Default: 8770

.PARAMETER ServiceName
    Windows service name. Default: DAEEMRelay

.PARAMETER MaxRooms
    Relay room cap. Default: 64

.PARAMETER Build
    Protocol build string. Empty = read data/config.json net.build, else
    coop-m12.2.

.PARAMETER PublicIp
    Optional public IPv4 used in the final DEPLOY OK line.

.PARAMETER OpenFirewall
    Add an inbound Windows Firewall rule for the relay port. The cloud
    security group is still configured outside this script.

.PARAMETER DryRun
    Print every planned action and validate the inputs without changing
    the service, files, firewall, or running processes.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File server\deploy.ps1 -DryRun

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File server\deploy.ps1 `
        -Python C:\Python312\python.exe -Nssm C:\tools\nssm.exe `
        -PublicIp 203.0.113.10
#>
#Requires -Version 5.1
param(
    [string]$ServerRoot = "C:\daeem",
    [string]$Python = "",
    [string]$Nssm = "",
    [int]$Port = 8770,
    [string]$ServiceName = "DAEEMRelay",
    [int]$MaxRooms = 64,
    [string]$Build = "",
    [string]$PublicIp = "",
    [switch]$OpenFirewall,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$Here = $PSScriptRoot
$SourceRelay = Join-Path $Here "daeem_relay.py"
$SourceReadme = Join-Path $Here "README.md"
$TargetDir = Join-Path $ServerRoot "server"
$TargetRelay = Join-Path $TargetDir "daeem_relay.py"
$TargetReadme = Join-Path $TargetDir "README.md"
$LogDir = Join-Path $ServerRoot "logs"
$OutLog = Join-Path $LogDir "relay.out.log"
$ErrLog = Join-Path $LogDir "relay.err.log"
$BackupRoot = Join-Path $ServerRoot "backup"
$FirewallRule = "$ServiceName TCP $Port"

function Write-Plan {
    param([string]$Message)
    Write-Host "DRYRUN: $Message"
}

function Resolve-ExistingFile {
    param([string]$Explicit, [string]$Name, [string[]]$Candidates)
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit -PathType Leaf)) {
            throw "$Name not found: $Explicit"
        }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        return $cmd.Source
    }
    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }
    return ""
}

function Resolve-Python {
    $candidates = @(
        "C:\Python314\python.exe",
        "C:\Python313\python.exe",
        "C:\Python312\python.exe",
        "C:\Python311\python.exe",
        "C:\Python310\python.exe",
        "C:\Program Files\Python314\python.exe",
        "C:\Program Files\Python313\python.exe",
        "C:\Program Files\Python312\python.exe",
        "C:\Program Files\Python311\python.exe",
        "C:\Program Files\Python310\python.exe"
    )
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA "Programs\Python\Python314\python.exe")
        $candidates += (Join-Path $env:LOCALAPPDATA "Programs\Python\Python313\python.exe")
        $candidates += (Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\python.exe")
        $candidates += (Join-Path $env:LOCALAPPDATA "Programs\Python\Python311\python.exe")
    }
    return Resolve-ExistingFile -Explicit $Python -Name "python" -Candidates $candidates
}

function Resolve-Nssm {
    $candidates = @(
        "C:\tools\nssm.exe",
        "C:\nssm\nssm.exe",
        "C:\Program Files\nssm\nssm.exe"
    )
    if ($env:ProgramData) {
        $candidates += (Join-Path $env:ProgramData "chocolatey\bin\nssm.exe")
    }
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles "nssm\nssm.exe")
    }
    return Resolve-ExistingFile -Explicit $Nssm -Name "nssm" -Candidates $candidates
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object -TypeName Security.Principal.WindowsPrincipal -ArgumentList $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ServiceInfo {
    return Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $ServiceName) -ErrorAction SilentlyContinue
}

function Get-DescendantPids {
    param([int]$ParentPid)
    $result = @()
    try {
        $all = Get-CimInstance Win32_Process -ErrorAction Stop | Select-Object ProcessId, ParentProcessId
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue($ParentPid)
        while ($queue.Count -gt 0) {
            $current = [int]$queue.Dequeue()
            foreach ($child in ($all | Where-Object { $_.ParentProcessId -eq $current })) {
                $childPid = [int]$child.ProcessId
                $result += $childPid
                $queue.Enqueue($childPid)
            }
        }
    } catch {
    }
    return $result
}

function Get-PortOwnerPid {
    param([int]$PortNumber)
    $cmd = Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue
    if ($cmd) {
        $conn = Get-NetTCPConnection -LocalPort $PortNumber -State Listen -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($conn) {
            return [int]$conn.OwningProcess
        }
        return 0
    }
    foreach ($line in (netstat -ano)) {
        if ($line -match "LISTENING" -and $line -match (":{0}\s" -f $PortNumber)) {
            $parts = ($line.Trim() -split "\s+")
            if ($parts.Count -ge 5) {
                return [int]$parts[$parts.Count - 1]
            }
        }
    }
    return 0
}

function Invoke-Nssm {
    param([string[]]$Arguments)
    Write-Host "nssm $($Arguments -join ' ')"
    & $Nssm @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw ("nssm failed with exit code {0}: nssm {1}" -f $LASTEXITCODE, ($Arguments -join " "))
    }
}

function Stop-RelayService {
    $info = Get-ServiceInfo
    if (-not $info) {
        return
    }
    if ($info.State -ne "Stopped") {
        Write-Host "stopping service $ServiceName (pid $($info.ProcessId))"
        Stop-Service -Name $ServiceName -Force -ErrorAction Stop
        $service = Get-Service -Name $ServiceName -ErrorAction Stop
        $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(20))
    }
}

function Start-RelayService {
    Write-Host "starting service $ServiceName"
    Start-Service -Name $ServiceName -ErrorAction Stop
    $service = Get-Service -Name $ServiceName -ErrorAction Stop
    $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(20))
}

function New-Backup {
    if (-not (Test-Path -LiteralPath $TargetDir -PathType Container)) {
        Write-Host "first deploy: no existing $TargetDir to back up"
        return ""
    }
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $backupDir = Join-Path $BackupRoot ("server-" + $stamp)
    $suffix = 1
    while (Test-Path -LiteralPath $backupDir) {
        $backupDir = Join-Path $BackupRoot ("server-" + $stamp + "-" + $suffix)
        $suffix += 1
    }
    New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
    Copy-Item -LiteralPath $TargetDir -Destination $backupDir -Recurse -Force
    if (-not (Test-Path -LiteralPath $backupDir -PathType Container)) {
        throw "backup failed: $backupDir"
    }
    $backupRelay = Join-Path $backupDir "daeem_relay.py"
    if (Test-Path -LiteralPath $TargetRelay -PathType Leaf) {
        if (-not (Test-Path -LiteralPath $backupRelay -PathType Leaf)) {
            throw "backup verification failed: missing daeem_relay.py in $backupDir"
        }
        $liveHash = (Get-FileHash -LiteralPath $TargetRelay -Algorithm SHA256).Hash
        $backupHash = (Get-FileHash -LiteralPath $backupRelay -Algorithm SHA256).Hash
        if ($liveHash -ne $backupHash) {
            throw "backup verification failed: relay hash mismatch in $backupDir"
        }
    }
    Write-Host "backup: $backupDir"
    return $backupDir
}

function Copy-Runtime {
    Write-Host "copying runtime to $TargetDir"
    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null

    $sourceRelayFull = (Resolve-Path -LiteralPath $SourceRelay).Path
    $targetRelayFull = [System.IO.Path]::GetFullPath($TargetRelay)
    if ($sourceRelayFull -ne $targetRelayFull) {
        Copy-Item -LiteralPath $SourceRelay -Destination $TargetRelay -Force
    } else {
        Write-Host "source is already the target; skipping relay copy"
    }

    $sourceReadmeFull = (Resolve-Path -LiteralPath $SourceReadme).Path
    $targetReadmeFull = [System.IO.Path]::GetFullPath($TargetReadme)
    if ($sourceReadmeFull -ne $targetReadmeFull) {
        Copy-Item -LiteralPath $SourceReadme -Destination $TargetReadme -Force
    } else {
        Write-Host "source is already the target; skipping README copy"
    }

    if (-not (Test-Path -LiteralPath $TargetRelay -PathType Leaf)) {
        throw "runtime verification failed: missing $TargetRelay"
    }
    $sourceHash = (Get-FileHash -LiteralPath $SourceRelay -Algorithm SHA256).Hash
    $targetHash = (Get-FileHash -LiteralPath $TargetRelay -Algorithm SHA256).Hash
    if ($sourceHash -ne $targetHash) {
        throw "copy verification failed for $TargetRelay"
    }
}

function Install-Or-Update-Service {
    $parameters = @(
        $TargetRelay,
        "--host", "0.0.0.0",
        "--port", "$Port",
        "--max-rooms", "$MaxRooms",
        "--build", $Build
    )
    $appParameters = ($parameters | ForEach-Object {
        if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    }) -join " "

    $info = Get-ServiceInfo
    if ($info) {
        Write-Host "updating existing service $ServiceName"
        Invoke-Nssm @("set", $ServiceName, "Application", $Python)
    } else {
        Write-Host "installing service $ServiceName"
        Invoke-Nssm @("install", $ServiceName, $Python)
    }
    Invoke-Nssm @("set", $ServiceName, "AppParameters", $appParameters)
    Invoke-Nssm @("set", $ServiceName, "AppDirectory", $TargetDir)
    Invoke-Nssm @("set", $ServiceName, "AppStdout", $OutLog)
    Invoke-Nssm @("set", $ServiceName, "AppStderr", $ErrLog)
    Invoke-Nssm @("set", $ServiceName, "AppRotateFiles", "1")
    Invoke-Nssm @("set", $ServiceName, "AppExit", "Default", "Restart")
    Invoke-Nssm @("set", $ServiceName, "AppRestartDelay", "5000")
    Invoke-Nssm @("set", $ServiceName, "Start", "SERVICE_AUTO_START")
    Invoke-Nssm @("set", $ServiceName, "Description", "DAEEM co-op relay")
}

function Enable-FirewallRule {
    $existing = Get-NetFirewallRule -DisplayName $FirewallRule -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "firewall rule already exists: $FirewallRule"
        return
    }
    Write-Host "adding firewall rule: $FirewallRule"
    New-NetFirewallRule -DisplayName $FirewallRule -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort $Port -Profile Any | Out-Null
}

function Test-Health {
    param([int]$Attempts = 30, [int]$DelayMs = 500)
    $uri = "http://127.0.0.1:{0}/health" -f $Port
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            $health = Invoke-RestMethod -Uri $uri -TimeoutSec 2
            if ($health.ok) {
                return $health
            }
        } catch {
        }
        Start-Sleep -Milliseconds $DelayMs
    }
    return $null
}

function Show-FailureContext {
    Write-Host "--- service status"
    Get-Service -Name $ServiceName -ErrorAction SilentlyContinue | Format-List Name, Status, StartType
    Write-Host "--- $ErrLog (last 50 lines)"
    if (Test-Path -LiteralPath $ErrLog) {
        Get-Content -LiteralPath $ErrLog -Tail 50 -ErrorAction SilentlyContinue
    } else {
        Write-Host "(missing)"
    }
}

function Restore-Backup {
    param([string]$BackupDir)
    if (-not $BackupDir -or -not (Test-Path -LiteralPath $BackupDir -PathType Container)) {
        return $false
    }
    Write-Host "restoring backup: $BackupDir"
    Stop-RelayService
    if (Test-Path -LiteralPath $TargetDir) {
        Remove-Item -LiteralPath $TargetDir -Recurse -Force
    }
    Copy-Item -LiteralPath $BackupDir -Destination $TargetDir -Recurse -Force
    $info = Get-ServiceInfo
    if (-not $info) {
        Write-Host "no service to restart; restored files only"
        return $true
    }
    Start-RelayService
    $health = Test-Health -Attempts 10 -DelayMs 500
    return [bool]$health
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

Write-Host "DAEEM relay deploy"
Write-Host "source: $Here"
Write-Host "target: $TargetDir"
Write-Host "service: $ServiceName  port: $Port  max rooms: $MaxRooms"

if (-not (Test-Path -LiteralPath $SourceRelay -PathType Leaf)) {
    Write-Host "ERROR: missing $SourceRelay" -ForegroundColor Red
    exit 2
}

$resolvedPython = Resolve-Python
$resolvedNssm = Resolve-Nssm

if (-not $Build) {
    $configPath = Join-Path (Split-Path -Path $Here -Parent) "data\config.json"
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($config.net -and $config.net.build) {
                $Build = [string]$config.net.build
            }
        } catch {
            Write-Host "WARNING: could not read net.build from $configPath"
        }
    }
}
if (-not $Build) {
    $Build = "coop-m12.2"
}

$isAdmin = Test-Administrator
$serviceInfo = Get-ServiceInfo
$servicePid = 0
$serviceTree = @()
if ($serviceInfo -and [int]$serviceInfo.ProcessId -gt 0) {
    $servicePid = [int]$serviceInfo.ProcessId
    $serviceTree = @($servicePid) + @(Get-DescendantPids -ParentPid $servicePid)
}
$portOwner = Get-PortOwnerPid -PortNumber $Port

Write-Host "python: $resolvedPython"
Write-Host "nssm: $resolvedNssm"
Write-Host "build: $Build"
Write-Host "admin: $isAdmin"
if ($serviceInfo) {
    Write-Host "existing service: state=$($serviceInfo.State) pid=$servicePid"
} else {
    Write-Host "existing service: none"
}
if ($portOwner -eq 0) {
    Write-Host "port ${Port}: free"
} else {
    Write-Host "port ${Port}: pid $portOwner"
}

if ($DryRun) {
    if (-not $resolvedPython) {
        Write-Plan "python not found; pass -Python before a real deploy"
    }
    if (-not $resolvedNssm) {
        Write-Plan "nssm not found; pass -Nssm before a real deploy"
    }
    if (-not $isAdmin) {
        Write-Plan "not running as administrator; a real deploy will require it"
    }
    if ($portOwner -ne 0 -and -not ($serviceTree -contains $portOwner)) {
        Write-Plan "port $Port is owned by pid $portOwner outside the service tree; a real deploy will refuse"
    }
    Write-Plan "stop service $ServiceName if running"
    Write-Plan "back up $TargetDir with timestamp under $BackupRoot"
    Write-Plan "copy $SourceRelay and $SourceReadme to $TargetDir"
    Write-Plan "install or update service $ServiceName with python $resolvedPython"
    if ($OpenFirewall) {
        Write-Plan "add inbound firewall rule: $FirewallRule"
    } else {
        Write-Plan "leave Windows Firewall unchanged (use -OpenFirewall to add a rule)"
    }
    Write-Plan "start service and require $('http://127.0.0.1:{0}/health' -f $Port) to answer ok"
    Write-Plan "on failure restore the backup and fail with a non-zero exit"
    Write-Host "DEPLOY DRYRUN OK" -ForegroundColor Green
    exit 0
}

if (-not $isAdmin) {
    Write-Host "ERROR: administrator rights are required (run as Administrator)" -ForegroundColor Red
    exit 2
}
if (-not $resolvedPython) {
    Write-Host "ERROR: python not found; pass -Python C:\path\python.exe" -ForegroundColor Red
    exit 2
}
if (-not $resolvedNssm) {
    Write-Host "ERROR: nssm not found; pass -Nssm C:\path\nssm.exe" -ForegroundColor Red
    exit 2
}
& $resolvedPython --version 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: python could not run: $resolvedPython" -ForegroundColor Red
    exit 2
}
if ($serviceInfo -and $serviceInfo.State -eq "Paused") {
    Write-Host "ERROR: service $ServiceName is paused; resume or delete it first" -ForegroundColor Red
    exit 2
}
if ($portOwner -ne 0 -and -not ($serviceTree -contains $portOwner)) {
    Write-Host "ERROR: port $Port is already used by pid $portOwner; stop it or choose another port" -ForegroundColor Red
    exit 2
}

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------

$backupDir = ""
$deployed = $false
$serviceStopped = $false

try {
    # Back up before stopping: a backup failure must leave a running relay alone.
    $backupDir = New-Backup

    if ($serviceInfo) {
        Stop-RelayService
        $serviceStopped = $true
    }

    Copy-Runtime

    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

    Install-Or-Update-Service

    if ($OpenFirewall) {
        Enable-FirewallRule
    }

    Start-RelayService

    $health = Test-Health
    if (-not $health) {
        throw "health check did not become ready"
    }
    $deployed = $true
} catch {
    $failure = $_.Exception.Message
    Write-Host "DEPLOY FAILED: $failure" -ForegroundColor Red
    Show-FailureContext

    $rolledBack = $false
    if ($backupDir) {
        try {
            $rolledBack = Restore-Backup -BackupDir $backupDir
        } catch {
            Write-Host "ROLLBACK FAILED: $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "no previous install to restore"
        if ($serviceStopped) {
            Write-Host "service $ServiceName remains stopped"
        }
    }

    if ($rolledBack) {
        Write-Host "ROLLBACK OK; previous install restored" -ForegroundColor Yellow
    } elseif ($backupDir) {
        Write-Host "ROLLBACK FAILED; service is not healthy" -ForegroundColor Red
    }
    exit 1
}

if ($deployed) {
    if ($PublicIp) {
        $healthUrl = "http://{0}:{1}/health" -f $PublicIp, $Port
    } else {
        $healthUrl = "http://127.0.0.1:{0}/health" -f $Port
    }
    Write-Host "build: $Build"
    Write-Host "health: $healthUrl"
    Write-Host "DEPLOY OK $healthUrl" -ForegroundColor Green
    exit 0
}

Write-Host "DEPLOY FAILED: unknown state" -ForegroundColor Red
exit 1
