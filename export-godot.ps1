#requires -version 5.1
<#
.SYNOPSIS
    一键把目录下的 Godot 项目导出成 Windows 桌面端和 Android 移动端。

.DESCRIPTION
    双击同目录下的 export-godot.bat 即可使用（不带任何参数时，导出脚本所在目录下的全部项目）。

    脚本会：
      1. 递归查找目录下的 project.godot（默认最多 6 层，跳过 .git / .godot / node_modules 等）；
      2. 自动寻找本机的 Godot 可执行文件（C# 项目会自动挑 mono/.NET 版本）；
      3. 从每个项目的 export_presets.cfg 里读出「Windows Desktop」「Android」两个预设及各自的
         export_path，逐个调用
             godot --headless --path <项目> --export-release "<预设>" "<输出文件>"
         （导出流程会自己先扫描并导入有变化的资源，不用另外跑 --import）
      4. 校验产物确实生成并被更新；C# 项目的 APK 还会检查里面有没有 .NET 运行时/程序集，缺了直接判失败；
      5. 最后打印汇总表，并把完整日志写到 .export-logs\。

.PARAMETER Root
    要扫描的根目录，默认是本脚本所在目录。

.PARAMETER Godot
    手动指定 Godot 可执行文件路径（留空则自动查找）。
    也可以在环境变量 GODOT_BIN 里配置。

.PARAMETER OutRoot
    统一输出根目录。指定后产物会放到 <OutRoot>\<项目名>\ 下，
    不再使用各项目 export_presets.cfg 里的 export_path。

.PARAMETER Mode
    Release（默认）或 Debug。

.PARAMETER Platforms
    要导出的平台，默认 Windows 和 Android 都导；只导一个就写 -Platforms Windows。

.PARAMETER MaxDepth
    递归查找项目的最大层数，默认 6。

.PARAMETER TimeoutMinutes
    单次导出的超时时间（分钟），默认 20。超时会被强制结束并按失败处理。

.PARAMETER NoPause
    兼容保留。脚本本身不会暂停，暂停由 export-godot.bat 负责。

.EXAMPLE
    .\export-godot.ps1
    导出脚本所在目录下的全部项目（Windows + Android）。

.EXAMPLE
    .\export-godot.ps1 -Platforms Windows
    只导 Windows。

.EXAMPLE
    .\export-godot.ps1 -Root D:\my_games -OutRoot D:\build
    扫描 D:\my_games，产物统一放到 D:\build\<项目名>\。
#>
[CmdletBinding()]
param(
    [string] $Root,
    [string] $Godot,
    [string] $OutRoot,
    [ValidateSet('Release', 'Debug')]
    [string] $Mode = 'Release',
    [ValidateSet('Windows', 'Android')]
    [string[]] $Platforms = @('Windows', 'Android'),
    [int] $MaxDepth = 6,
    [int] $TimeoutMinutes = 20,
    [switch] $NoPause
)

$ErrorActionPreference = 'Continue'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
}
catch { }

$script:LogLines = New-Object System.Collections.Generic.List[string]
$script:Results = New-Object System.Collections.Generic.List[object]

# ------------------------------------------------------------------ 输出工具

function Write-Log {
    param(
        [string] $Text = '',
        [ConsoleColor] $Color = [ConsoleColor]::Gray
    )
    $script:LogLines.Add($Text)
    Write-Host $Text -ForegroundColor $Color
}

function Format-Size {
    <#
        按十进制换算（1 MB = 1,000,000 字节），跟资源管理器 / Godot 导出对话框的口径一致。
        用 1024² 会把 113 MB 的包显示成 107.9 MB，看起来像"导出的包变小了"，很坑。
    #>
    param([long] $Bytes)
    if ($Bytes -ge 1000000000) { return ('{0:N2} GB' -f ($Bytes / 1e9)) }
    if ($Bytes -ge 1000000) { return ('{0:N1} MB' -f ($Bytes / 1e6)) }
    if ($Bytes -ge 1000) { return ('{0:N0} KB' -f ($Bytes / 1e3)) }
    return "$Bytes B"
}

function Format-Duration {
    param([double] $Seconds)
    if ($Seconds -ge 60) { return ('{0}m{1:00}s' -f [int][math]::Floor($Seconds / 60), [int]($Seconds % 60)) }
    return ('{0:0.0}s' -f $Seconds)
}

function Add-Result {
    param(
        [string] $Project,
        [string] $Platform,
        [string] $Status,   # OK / SKIP / FAIL
        [string] $File = '',
        [long] $Bytes = 0,
        [double] $Seconds = 0,
        [string] $Message = ''
    )
    $script:Results.Add([pscustomobject]@{
            Project  = $Project
            Platform = $Platform
            Status   = $Status
            File     = $File
            Bytes    = $Bytes
            Seconds  = $Seconds
            Message  = $Message
        })
}

# ------------------------------------------------------------------ 环境探测

function Find-GodotProjects {
    <# 递归找 project.godot；进入一个项目后不再往下钻，避免把 addons 里的子工程也算进来 #>
    param(
        [string] $Base,
        [int] $MaxDepth
    )

    $skipNames = @(
        '.git', '.godot', '.vs', '.idea', '.export-logs', '.nuget-packages',
        'node_modules', 'bin', 'obj', 'export_templates'
    )

    $found = New-Object System.Collections.Generic.List[string]
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue(@($Base, 0))

    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $dir = [string]$item[0]
        $depth = [int]$item[1]

        if (Test-Path -LiteralPath (Join-Path $dir 'project.godot')) {
            $found.Add($dir)
            continue
        }
        if ($depth -ge $MaxDepth) { continue }

        $subs = @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue)
        foreach ($sub in $subs) {
            if ($skipNames -contains $sub.Name) { continue }
            if ($sub.Name.StartsWith('.')) { continue }
            $queue.Enqueue(@($sub.FullName, $depth + 1))
        }
    }

    return @($found | Sort-Object)
}

function Test-ProjectUsesCSharp {
    param([string] $ProjectDir)
    if (Get-ChildItem -LiteralPath $ProjectDir -Filter '*.csproj' -ErrorAction SilentlyContinue) { return $true }
    if (Get-ChildItem -LiteralPath $ProjectDir -Filter '*.sln' -ErrorAction SilentlyContinue) { return $true }
    $cfg = Join-Path $ProjectDir 'project.godot'
    if (Test-Path -LiteralPath $cfg) {
        $raw = [System.IO.File]::ReadAllText($cfg)
        if ($raw -match 'config/features\s*=\s*PackedStringArray\([^)]*"C#"') { return $true }
    }
    return $false
}

function Get-GodotSearchHints {
    <# 从 Godot 编辑器设置里捞出引擎/模板所在的目录 #>
    $dirs = New-Object System.Collections.Generic.List[string]
    $settingsDir = Join-Path $env:APPDATA 'Godot'
    if (Test-Path -LiteralPath $settingsDir) {
        $files = @(Get-ChildItem -LiteralPath $settingsDir -Filter 'editor_settings-*.tres' -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending)
        foreach ($f in $files) {
            $hit = Select-String -LiteralPath $f.FullName -Pattern '^_export_template_download_directory\s*=\s*"(.+)"' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($hit) {
                $d = $hit.Matches[0].Groups[1].Value -replace '/', '\'
                if (Test-Path -LiteralPath $d) {
                    $dirs.Add($d)
                    $parent = Split-Path -Parent $d
                    if ($parent -and (Test-Path -LiteralPath $parent)) { $dirs.Add($parent) }
                }
            }
        }
    }
    return $dirs
}

function Test-IsMonoBuild {
    param([string] $ExePath)
    if ($ExePath -match '(?i)mono') { return $true }
    $dir = Split-Path -Parent $ExePath
    if (Test-Path -LiteralPath (Join-Path $dir 'GodotSharp')) { return $true }
    return $false
}

function Resolve-GodotExe {
    param(
        [bool] $NeedMono,
        [string] $Explicit
    )

    $candidates = New-Object System.Collections.Generic.List[string]

    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit)) { throw "指定的 Godot 路径不存在：$Explicit" }
        $candidates.Add((Resolve-Path -LiteralPath $Explicit).Path)
    }
    foreach ($envName in @('GODOT_BIN', 'GODOT4_BIN', 'GODOT_PATH')) {
        $v = [Environment]::GetEnvironmentVariable($envName)
        if ($v -and (Test-Path -LiteralPath $v)) { $candidates.Add($v) }
    }

    $scanDirs = New-Object System.Collections.Generic.List[string]
    foreach ($d in (Get-GodotSearchHints)) { $scanDirs.Add($d) }

    $genericDirs = @(
        'C:\D\GodotEngine', 'D:\GodotEngine', 'C:\Godot', 'D:\Godot', 'E:\Godot',
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        $env:ProgramFiles,
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'Desktop'),
        $PSScriptRoot
    )
    foreach ($d in $genericDirs) {
        if ($d -and (Test-Path -LiteralPath $d)) { $scanDirs.Add($d) }
    }

    foreach ($dir in ($scanDirs | Select-Object -Unique)) {
        $exes = @(Get-ChildItem -LiteralPath $dir -Filter 'Godot*.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer })
        foreach ($e in $exes) { $candidates.Add($e.FullName) }
    }

    foreach ($name in @('godot', 'godot4', 'Godot')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { $candidates.Add($cmd.Source) }
    }

    $existing = @($candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
    if ($existing.Count -eq 0) {
        throw @"
没有找到 Godot 可执行文件。

请任选一种方式告诉我它在哪里：
  1. 命令行加参数： .\export-godot.ps1 -Godot "D:\Godot\Godot_v4.7.2-stable_mono_win64.exe"
  2. 设环境变量：   setx GODOT_BIN "D:\Godot\Godot_v4.7.2-stable_mono_win64.exe"
注意：C# 项目必须用 **mono / .NET 版** 的 Godot，标准版导不出 .NET 程序集。
"@
    }

    $scored = foreach ($c in $existing) {
        $isMono = Test-IsMonoBuild -ExePath $c
        [pscustomobject]@{
            Path    = $c
            Mono    = $isMono
            Console = ($c -match '(?i)_console\.exe$')
        }
    }

    $usable = @($scored | Where-Object { (-not $NeedMono) -or $_.Mono })
    if ($usable.Count -eq 0) {
        throw @"
项目是 C#（.NET）工程，但只找到了标准版 Godot，导出会失败。

已找到：
$($existing -join "`n")
请改装 Godot 的 **.NET / mono** 版本，并用 -Godot 参数或 GODOT_BIN 指定它。
"@
    }

    # 优先：满足 mono 需求 > 控制台版（能抓到完整输出）
    $picked = $usable |
        Sort-Object @{ Expression = { if ($_.Mono -eq $NeedMono) { 0 } else { 1 } } },
                    @{ Expression = { if ($_.Console) { 0 } else { 1 } } } |
        Select-Object -First 1

    return $picked.Path
}

function Get-AndroidPrereqs {
    <# 从编辑器设置里读 Android SDK / JDK 路径，只用于提前给出友好提示 #>
    $info = [pscustomobject]@{ SdkPath = ''; JdkPath = ''; Keystore = '' }
    $settingsDir = Join-Path $env:APPDATA 'Godot'
    if (-not (Test-Path -LiteralPath $settingsDir)) { return $info }

    $file = Get-ChildItem -LiteralPath $settingsDir -Filter 'editor_settings-*.tres' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $file) { return $info }

    $patterns = @{
        SdkPath  = '^export/android/android_sdk_path\s*=\s*"(.+)"'
        JdkPath  = '^export/android/java_sdk_path\s*=\s*"(.+)"'
        Keystore = '^export/android/debug_keystore\s*=\s*"(.+)"'
    }
    foreach ($key in $patterns.Keys) {
        $hit = Select-String -LiteralPath $file.FullName -Pattern $patterns[$key] -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) {
            $v = $hit.Matches[0].Groups[1].Value -replace '/', '\'
            $info.$key = $v
        }
    }
    return $info
}

# ------------------------------------------------------------------ 预设解析

function Read-ExportPresets {
    <# 从 export_presets.cfg 解析出每个 [preset.N] 的 name / platform / export_path #>
    param([string] $PresetFile)

    $presets = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $PresetFile)) { return $presets }

    $current = $null
    $section = ''

    foreach ($rawLine in [System.IO.File]::ReadAllLines($PresetFile)) {
        $line = $rawLine.Trim()
        if ($line -match '^\[(.+)\]$') {
            $section = $Matches[1]
            if ($section -match '^preset\.\d+$') {
                $current = [pscustomobject]@{ Name = ''; Platform = ''; ExportPath = '' }
                $presets.Add($current)
            }
            else {
                # 进入 [preset.N.options] 等其它段落后不再收集，避免 options 里的键污染预设
                $current = $null
            }
            continue
        }
        if ($null -eq $current) { continue }

        # 注意：-notmatch 不会刷新 $Matches，所以要取分组必须先用 -match
        if (-not ($line -match '^([A-Za-z0-9_/]+)=(.*)$')) { continue }

        $key = $Matches[1]
        $val = ([string]$Matches[2]).Trim()
        if ($val.Length -ge 2 -and $val.StartsWith('"') -and $val.EndsWith('"')) {
            $val = $val.Substring(1, $val.Length - 2)
        }

        switch ($key) {
            'name' { $current.Name = $val }
            'platform' { $current.Platform = $val }
            'export_path' { $current.ExportPath = $val }
        }
    }

    return $presets
}

function Get-PlatformSpec {
    param([string] $Platform)
    if ($Platform -eq 'Windows') {
        return [pscustomobject]@{ GodotPlatform = 'Windows Desktop'; Extension = '.exe'; Label = 'Windows 桌面端' }
    }
    return [pscustomobject]@{ GodotPlatform = 'Android'; Extension = '.apk'; Label = 'Android 移动端' }
}

function Resolve-ExportTarget {
    param(
        [string] $ProjectDir,
        [string] $ProjectName,
        [string] $PresetExportPath,
        [string] $Extension,
        [string] $OutRoot
    )

    $fileName = ''
    if ($PresetExportPath) { $fileName = Split-Path -Leaf ($PresetExportPath -replace '/', '\') }
    if (-not $fileName) { $fileName = "$ProjectName$Extension" }

    if ($OutRoot) {
        return (Join-Path (Join-Path $OutRoot $ProjectName) $fileName)
    }
    if ($PresetExportPath) {
        if ([System.IO.Path]::IsPathRooted($PresetExportPath)) {
            return [System.IO.Path]::GetFullPath($PresetExportPath)
        }
        return [System.IO.Path]::GetFullPath((Join-Path $ProjectDir ($PresetExportPath -replace '/', '\')))
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Join-Path $ProjectDir 'exports') $fileName))
}

function Test-AndroidApkHasDotnet {
    <#
        C# 项目的 Android 包必须带上 .NET 运行时（libmono*.so）或程序集（*.dll）。
        少了它们，包能装上但一跑起来就崩 —— 常见原因是没启用 Gradle 构建、
        或 dotnet publish 之后的注入步骤失败。
    #>
    param([string] $ApkPath)

    if (-not (Test-Path -LiteralPath $ApkPath)) { return $true }

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ApkPath)
        try {
            $hasRuntime = @($zip.Entries | Where-Object { $_.FullName -match '(?i)^lib/[^/]+/libmono[^/]*\.so$' }).Count -gt 0
            $hasAssemblies = @($zip.Entries | Where-Object { $_.FullName -match '(?i)\.dll$' }).Count -gt 0
            return ($hasRuntime -or $hasAssemblies)
        }
        finally { $zip.Dispose() }
    }
    catch { return $true }   # 读不了就不下结论，避免误报
}

function Test-ArtifactIntegrity {
    <#
        产物结构检查：判断导出是不是真的写完整了。
        Windows：exe 不应异常小（模板本身就有几十 MB）；
        Android：APK 必须能当 zip 打开，且含 AndroidManifest.xml + classes.dex。
    #>
    param(
        [string] $Path,
        [string] $Platform
    )

    $fail = { param($d) [pscustomobject]@{ Ok = $false; Detail = $d } }

    if (-not (Test-Path -LiteralPath $Path)) { return (& $fail '文件不存在') }

    $item = Get-Item -LiteralPath $Path
    if ($item.Length -le 0) { return (& $fail '文件为空') }

    if ($Platform -eq 'Android') {
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
            try {
                $names = @($zip.Entries | ForEach-Object { $_.FullName })
            }
            finally { $zip.Dispose() }

            if ($names -notcontains 'AndroidManifest.xml') { return (& $fail 'APK 里没有 AndroidManifest.xml') }
            if ($names -notcontains 'classes.dex') { return (& $fail 'APK 里没有 classes.dex') }
        }
        catch { return (& $fail 'APK 打不开，可能没写完') }
    }
    elseif ($Platform -eq 'Windows') {
        if ($item.Length -lt 1MB) {
            return (& $fail ('可执行文件异常小（' + (Format-Size $item.Length) + '），可能没写完'))
        }
    }

    return [pscustomobject]@{ Ok = $true; Detail = '' }
}

function Get-WriteBlocker {
    <#
        判断输出文件能不能写。
        返回：'' = 可写；'locked' = 被别的进程占用；'permission' = 只读/权限不足。
        注意「权限不足」不等于「被占用」，否则会把 ACL 问题误报成"游戏还在运行"。
    #>
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return '' }

    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
        $fs.Close()
        return ''
    }
    catch {
        $ex = $_.Exception
        if ($ex.InnerException) { $ex = $ex.InnerException }
        switch ($ex.GetType().Name) {
            'UnauthorizedAccessException' { return 'permission' }
            'IOException' { return 'locked' }
            'SecurityException' { return 'permission' }
            default { return 'unknown' }
        }
    }
}

# ------------------------------------------------------------------ 导出执行

function ConvertTo-ArgumentString {
    <# 把参数数组拼成 Windows 命令行字符串（按 Windows 规则补引号、转义尾部反斜杠） #>
    param([string[]] $Items)

    $sb = New-Object System.Text.StringBuilder
    foreach ($item in $Items) {
        if ($null -eq $item) { continue }
        $a = [string]$item
        if ($sb.Length -gt 0) { [void]$sb.Append(' ') }

        if ($a.Length -gt 0 -and $a -notmatch '[\s"]') {
            [void]$sb.Append($a)
            continue
        }

        [void]$sb.Append('"')
        $backslashes = 0
        foreach ($ch in $a.ToCharArray()) {
            if ($ch -eq '\') { $backslashes++; continue }
            if ($ch -eq '"') {
                [void]$sb.Append(('\' * ($backslashes * 2 + 1)) + '"')
                $backslashes = 0
                continue
            }
            if ($backslashes -gt 0) { [void]$sb.Append('\' * $backslashes); $backslashes = 0 }
            [void]$sb.Append($ch)
        }
        if ($backslashes -gt 0) { [void]$sb.Append('\' * ($backslashes * 2)) }
        [void]$sb.Append('"')
    }
    return $sb.ToString()
}

function Read-NewText {
    <# 增量读取一个正被别的进程写着的文件 #>
    param([string] $Path, [long] $Position)

    $result = [pscustomobject]@{ Text = ''; Position = $Position }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }

    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($fs.Length -gt $Position) {
            [void]$fs.Seek($Position, [System.IO.SeekOrigin]::Begin)
            $buffer = New-Object byte[] ([int]($fs.Length - $Position))
            $read = $fs.Read($buffer, 0, $buffer.Length)
            $result.Text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
            $result.Position = $Position + $read
        }
    }
    catch { }
    finally { if ($fs) { $fs.Dispose() } }
    return $result
}

function Stop-ProcessTree {
    <# 结束 godot 及其派生的引擎子进程（只针对我们刚启动的那棵树） #>
    param([int] $TargetId)
    try { & taskkill.exe /PID $TargetId /T /F 2>&1 | Out-Null } catch { }
    Start-Sleep -Milliseconds 400
}

function Invoke-Godot {
    <#
        跑一次 godot，实时回显输出。

        为什么要自己管进程：Windows 版 Godot 的 *_console.exe 只是个壳，真正的引擎是它派生的
        子进程；引擎导出完就退出，壳却经常一直挂着不返回。所以这里在「检测到导出完成」或
        「超时」时主动结束整棵进程树，避免双击后窗口卡住。
    #>
    param(
        [string] $Exe,
        [string[]] $ArgumentList,
        [int] $TimeoutSeconds = 1200,
        [string] $SuccessFile = '',
        [int] $GraceSeconds = 15
    )

    $argString = ConvertTo-ArgumentString -Items $ArgumentList
    $outPath = [System.IO.Path]::GetTempFileName()
    $errPath = [System.IO.Path]::GetTempFileName()
    $startUtc = [datetime]::UtcNow

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = $null
    try {
        $proc = Start-Process -FilePath $Exe -ArgumentList $argString -NoNewWindow -PassThru `
            -RedirectStandardOutput $outPath -RedirectStandardError $errPath -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{
            ExitCode   = -1
            Output     = @('无法启动 Godot：' + $_.Exception.Message)
            Seconds    = 0
            SawSuccess = $false
            Killed     = $false
            TimedOut   = $false
        }
    }

    $captured = New-Object System.Collections.Generic.List[string]
    $buffer = New-Object System.Text.StringBuilder
    $posOut = [long]0
    $posErr = [long]0
    $successAt = $null
    $timedOut = $false
    $killed = $false

    # 屏幕回显做过滤：savepack 会逐个文件打印上千行，全部写日志、屏幕只留关键行。
    # 用 hashtable 是因为脚本块里改不了父作用域的普通变量。
    $echoState = @{ Count = 0; Limit = 200 }
    $consumeChunk = {
        param([string] $Chunk)

        if (-not $Chunk) { return }
        [void]$buffer.Append($Chunk)

        foreach ($line in ($Chunk -split "`r?`n")) {
            if ($line -eq '') { continue }
            $captured.Add($line)
            $script:LogLines.Add('      ' + $line)

            if ($line -match '正在保存文件：|Saving file:|^ADDING: |^\d+ param: ') { continue }

            if ($echoState.Count -lt $echoState.Limit) {
                Write-Host ('      ' + $line) -ForegroundColor DarkGray
                $echoState.Count++
            }
            elseif ($echoState.Count -eq $echoState.Limit) {
                Write-Host '      ...（输出太多，后面的内容只写进日志文件）' -ForegroundColor DarkGray
                $echoState.Count++
            }
        }
    }

    while ($true) {
        Start-Sleep -Milliseconds 300

        $o = Read-NewText -Path $outPath -Position $posOut
        $posOut = [long]$o.Position
        $e = Read-NewText -Path $errPath -Position $posErr
        $posErr = [long]$e.Position

        & $consumeChunk -Chunk $o.Text
        & $consumeChunk -Chunk $e.Text

        # 「导出阶段结束」信号：只用来决定「进程挂住时可以收尾」，最终成败由产物判定。
        # 桌面端最后阶段是 savepack，Android 是 export，两种都要认。
        if ($null -eq $successAt -and $SuccessFile -and (Test-Path -LiteralPath $SuccessFile)) {
            $stateText = $buffer.ToString()
            $doneMarker = ($stateText -match '\[ DONE \][^\r\n]*(savepack|export)\b') -or ($stateText -match 'Project export for preset .* completed')
            $fileFresh = ((Get-Item -LiteralPath $SuccessFile).LastWriteTimeUtc -gt $startUtc)
            if ($doneMarker -and $fileFresh) { $successAt = $sw.Elapsed }
        }

        if ($proc.HasExited) { break }

        if ($null -ne $successAt -and ($sw.Elapsed - $successAt).TotalSeconds -ge $GraceSeconds) {
            Write-Host '      （导出已完成，但 Godot 进程没有自行退出，正在回收）' -ForegroundColor DarkYellow
            Stop-ProcessTree -TargetId $proc.Id
            $killed = $true
            break
        }
        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            Write-Host ('      （超过 ' + [int]($TimeoutSeconds / 60) + ' 分钟仍未完成，强制结束）') -ForegroundColor DarkYellow
            Stop-ProcessTree -TargetId $proc.Id
            $timedOut = $true
            break
        }
    }

    # 收尾：把剩余输出读干净
    Start-Sleep -Milliseconds 200
    $o = Read-NewText -Path $outPath -Position $posOut
    $e = Read-NewText -Path $errPath -Position $posErr
    & $consumeChunk -Chunk $o.Text
    & $consumeChunk -Chunk $e.Text

    $sw.Stop()
    # 注意：Start-Process 返回的对象在部分环境下 $proc.ExitCode 恒为 $null，
    # 千万别直接赋值（会把 -1 覆盖成空值）。只在确实拿到整数时才采用。
    $exitCode = -1
    try {
        if ($proc.HasExited) {
            $raw = $proc.ExitCode
            if ($null -ne $raw -and "$raw" -match '^-?\d+$') { $exitCode = [int]$raw }
        }
    }
    catch { }

    foreach ($p in @($outPath, $errPath)) {
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        ExitCode   = $exitCode
        Output     = $captured
        Seconds    = $sw.Elapsed.TotalSeconds
        SawSuccess = ($null -ne $successAt)
        Killed     = $killed
        TimedOut   = $timedOut
    }
}

function Export-OneTarget {
    param(
        [string] $GodotExe,
        [string] $ProjectDir,
        [string] $ProjectLabel,
        [string] $Platform,
        [object] $Preset,
        [string] $OutFile,
        [int] $TimeoutSeconds = 1200,
        [bool] $IsCSharp = $false
    )

    $spec = Get-PlatformSpec -Platform $Platform
    $outDir = Split-Path -Parent $OutFile
    if (-not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }

    $blocker = Get-WriteBlocker -Path $OutFile
    if ($blocker -eq 'locked') {
        Write-Log ("      跳过：输出文件正被占用，请先关闭正在运行的游戏 -> " + $OutFile) Yellow
        Add-Result -Project $ProjectLabel -Platform $spec.Label -Status 'FAIL' -File $OutFile -Message '输出文件被占用（游戏可能正在运行）'
        return
    }
    if ($blocker -eq 'permission') {
        Write-Log ("      提示：目标文件当前不可写（只读/权限不足），仍让 Godot 尝试覆盖 -> " + $OutFile) Yellow
    }

    $beforeTime = [datetime]::MinValue
    $beforeLen = 0
    if (Test-Path -LiteralPath $OutFile) {
        $item = Get-Item -LiteralPath $OutFile
        $beforeTime = $item.LastWriteTimeUtc
        $beforeLen = $item.Length
    }

    # 正式导出（Godot 的导出流程自己会先扫描并导入有变化的资源，不需要另外跑 --import）
    $exportFlag = if ($Mode -eq 'Debug') { '--export-debug' } else { '--export-release' }
    Write-Log ("      导出中：" + $Preset.Name + " -> " + $OutFile) Cyan

    $run = Invoke-Godot -Exe $GodotExe -ArgumentList @(
        '--headless', '--path', $ProjectDir, $exportFlag, $Preset.Name, $OutFile
    ) -TimeoutSeconds $TimeoutSeconds -SuccessFile $OutFile

    # 3) 校验：以产物为准（存在 + 已更新 + 结构完整）
    #    不依赖 Godot 的退出码：Windows 版启动壳经常拿不到真实退出码（可能是 $null），
    #    而导出其实已经成功。退出码只用于失败时的附加信息。
    $exists = Test-Path -LiteralPath $OutFile
    $fresh = $false
    $bytes = 0
    if ($exists) {
        $item = Get-Item -LiteralPath $OutFile
        $bytes = $item.Length
        $fresh = ($item.LastWriteTimeUtc -gt $beforeTime) -or ($item.Length -ne $beforeLen)
    }
    $integrity = Test-ArtifactIntegrity -Path $OutFile -Platform $Platform

    if ((-not $run.TimedOut) -and $exists -and $fresh -and $bytes -gt 0 -and $integrity.Ok) {
        # 产物体检：C# 项目的 APK 必须带 .NET 运行时（libmono*.so）和程序集，否则装上就崩
        if ($Platform -eq 'Android' -and $IsCSharp -and -not (Test-AndroidApkHasDotnet -ApkPath $OutFile)) {
            Write-Log ("      失败：" + (Format-Size $bytes) + " 的 APK 生成了，但里面没有 .NET 运行时/程序集，手机上跑不起来") Red
            Write-Log '            常见原因：dotnet publish 之后的注入步骤没跑完（看上面有没有 UnauthorizedAccess/error），' Yellow
            Write-Log '            或 C# 项目没启用 Gradle 构建。' Yellow
            Write-Log '            处理：项目 -> 导出 -> Android 勾选 Use Gradle Build，并先执行 项目 -> 安装 Android 构建模板。' Yellow
            Add-Result -Project $ProjectLabel -Platform $spec.Label -Status 'FAIL' -File $OutFile -Bytes $bytes -Seconds $run.Seconds `
                -Message 'APK 缺少 .NET 运行时/程序集，手机上跑不起来（详见上方说明）'
            return
        }

        $note = if ($run.Killed) { '（Godot 进程未自行退出，已自动回收）' } else { '' }
        Write-Log ("      成功：" + (Format-Size $bytes) + "，用时 " + (Format-Duration $run.Seconds) + $note) Green
        Add-Result -Project $ProjectLabel -Platform $spec.Label -Status 'OK' -File $OutFile -Bytes $bytes -Seconds $run.Seconds
        return
    }

    $reason = ''
    if ($run.TimedOut) { $reason = '导出超时，已强制结束' }
    elseif (-not $exists) { $reason = '没有生成输出文件' }
    elseif (-not $fresh) { $reason = '输出文件没有被更新' }
    elseif ($bytes -le 0) { $reason = '输出文件为空' }
    elseif (-not $integrity.Ok) { $reason = '产物不完整：' + $integrity.Detail }
    else { $reason = '导出没有完成（原因见下方日志）' }

    if ("$($run.ExitCode)" -match '^-?\d+$') { $reason += "（Godot 退出码 $($run.ExitCode)）" }

    # 过滤掉无害的收尾噪音，避免把 "EditorSettings not instantiated" 这类当成失败原因展示
    $benign = '(?i)EditorSettings not instantiated|shutdown_adb_on_exit|Cannot save file .*editor_settings|Error saving editor settings|root certificate store|msbuild_issues\.csv'
    $hints = @($run.Output |
            Where-Object { $_ -match '(?i)error|exception|失败|missing|not found|unable|cannot' -and $_ -notmatch $benign } |
            Select-Object -Last 6)

    Write-Log ("      失败：" + $reason) Red
    foreach ($h in $hints) { Write-Log ('        ' + $h) DarkRed }

    $msg = $reason
    if ($hints.Count -gt 0) { $msg = $reason + ' | ' + ($hints -join ' ; ') }
    Add-Result -Project $ProjectLabel -Platform $spec.Label -Status 'FAIL' -File $OutFile -Message $msg
}

# ------------------------------------------------------------------ 主流程

function Invoke-Main {
    $scriptRoot = $PSScriptRoot
    if (-not $scriptRoot) { $scriptRoot = (Get-Location).Path }

    $scanRoot = $scriptRoot
    if ($Root) {
        if (-not (Test-Path -LiteralPath $Root)) { throw "扫描目录不存在：$Root" }
        $scanRoot = (Resolve-Path -LiteralPath $Root).Path
    }

    $outRootFull = ''
    if ($OutRoot) { $outRootFull = [System.IO.Path]::GetFullPath($OutRoot) }

    Write-Log ''
    Write-Log '==================================================' Cyan
    Write-Log '   Godot 一键导出：Windows 桌面端 + Android 移动端' Cyan
    Write-Log '==================================================' Cyan
    Write-Log ('   扫描目录 ：' + $scanRoot)
    Write-Log ('   导出模式 ：' + $Mode)
    Write-Log ('   目标平台 ：' + ($Platforms -join ', '))
    if ($outRootFull) { Write-Log ('   输出根目录：' + $outRootFull) }
    Write-Log ''

    Write-Log '>> 查找 Godot 项目 ...' White
    $projects = @(Find-GodotProjects -Base $scanRoot -MaxDepth $MaxDepth)
    if ($projects.Count -eq 0) {
        Write-Log ('[失败] 在 ' + $scanRoot + ' 下没有找到 project.godot（Godot 项目文件）。') Red
        Write-Log '       把本脚本放到项目目录（或项目的上级目录）再双击即可。' Yellow
        return 1
    }
    foreach ($p in $projects) {
        $rel = $p
        if ($rel.StartsWith($scanRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $rel.Substring($scanRoot.Length).TrimStart('\', '/')
        }
        if (-not $rel) { $rel = Split-Path -Leaf $p }
        Write-Log ('   * ' + $rel) Green
    }
    Write-Log ''

    Write-Log '>> 定位 Godot 引擎 ...' White
    $needMono = $false
    foreach ($p in $projects) {
        if (Test-ProjectUsesCSharp -ProjectDir $p) { $needMono = $true; break }
    }
    if ($needMono) { Write-Log '   检测到 C# 项目，将使用 .NET (mono) 版 Godot。' DarkGray }

    $godotExe = Resolve-GodotExe -NeedMono $needMono -Explicit $Godot
    Write-Log ('   ' + $godotExe) Green
    Write-Log ''

    if (-not (Test-Path -LiteralPath (Join-Path $env:APPDATA 'Godot\export_templates'))) {
        Write-Log '[提示] 没有找到导出模板目录，首次导出可能失败：' Yellow
        Write-Log '       Godot 编辑器 -> 编辑器/Editor -> 管理导出模板 -> 下载并安装。' Yellow
        Write-Log ''
    }

    if ($Platforms -contains 'Android') {
        $and = Get-AndroidPrereqs
        if (-not $and.SdkPath -or -not (Test-Path -LiteralPath $and.SdkPath)) {
            Write-Log '[提示] 未从 Godot 设置里读到可用的 Android SDK 路径，Android 导出可能失败。' Yellow
            Write-Log '       编辑器 -> 编辑器设置 -> 导出/Export -> Android -> Android SDK Path。' Yellow
            Write-Log ''
        }
        if (-not $and.JdkPath -or -not (Test-Path -LiteralPath $and.JdkPath)) {
            Write-Log '[提示] 未读到可用的 JDK(Java SDK) 路径，Android 导出可能失败。' Yellow
            Write-Log ''
        }
    }

    $index = 0
    foreach ($proj in $projects) {
        $index++
        $projectName = Split-Path -Leaf $proj
        $label = $proj
        if ($label.StartsWith($scanRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $label = $label.Substring($scanRoot.Length).TrimStart('\', '/')
        }
        if (-not $label) { $label = $projectName }

        Write-Log ('[' + $index + '/' + $projects.Count + '] ' + $label) White
        Write-Log ('      项目目录：' + $proj) DarkGray

        $projIsCSharp = Test-ProjectUsesCSharp -ProjectDir $proj
        if ($projIsCSharp) { Write-Log '      语言：C#（.NET）' DarkGray }

        $presetFile = Join-Path $proj 'export_presets.cfg'
        if (-not (Test-Path -LiteralPath $presetFile)) {
            Write-Log '      失败：项目里没有 export_presets.cfg（还没配置过导出预设）。' Red
            Write-Log '            在 Godot 编辑器里 项目 -> 导出 中添加 Windows Desktop / Android 预设即可。' Yellow
            foreach ($plat in $Platforms) {
                Add-Result -Project $label -Platform (Get-PlatformSpec -Platform $plat).Label -Status 'FAIL' -Message '缺少 export_presets.cfg'
            }
            Write-Log ''
            continue
        }

        $presets = @(Read-ExportPresets -PresetFile $presetFile)
        if ($presets.Count -eq 0) {
            Write-Log '      失败：export_presets.cfg 里没有解析到任何预设。' Red
            foreach ($plat in $Platforms) {
                Add-Result -Project $label -Platform (Get-PlatformSpec -Platform $plat).Label -Status 'FAIL' -Message '预设解析为空'
            }
            Write-Log ''
            continue
        }

        foreach ($plat in $Platforms) {
            $spec = Get-PlatformSpec -Platform $plat
            $preset = $presets | Where-Object { $_.Platform -eq $spec.GodotPlatform } | Select-Object -First 1

            if (-not $preset) {
                $have = ($presets | ForEach-Object { $_.Platform }) -join ', '
                Write-Log ('      [' + $spec.Label + '] 跳过：没有 "' + $spec.GodotPlatform + '" 预设（现有：' + $have + '）') Yellow
                Add-Result -Project $label -Platform $spec.Label -Status 'FAIL' -Message ('缺少 ' + $spec.GodotPlatform + ' 预设')
                continue
            }

            $outFile = Resolve-ExportTarget -ProjectDir $proj -ProjectName $projectName `
                -PresetExportPath $preset.ExportPath -Extension $spec.Extension -OutRoot $outRootFull

            Write-Log ('      [' + $spec.Label + '] 预设 "' + $preset.Name + '"') DarkCyan
            Export-OneTarget -GodotExe $godotExe -ProjectDir $proj -ProjectLabel $label `
                -Platform $plat -Preset $preset -OutFile $outFile -TimeoutSeconds ($TimeoutMinutes * 60) -IsCSharp $projIsCSharp
        }
        Write-Log ''
    }

    # ---------------- 汇总 ----------------
    $ok = @($script:Results | Where-Object { $_.Status -eq 'OK' })
    $fail = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
    $totalSeconds = ($script:Results | Measure-Object -Property Seconds -Sum).Sum
    if ($null -eq $totalSeconds) { $totalSeconds = 0 }

    Write-Log '==================================================' Cyan
    Write-Log ('   结果：成功 ' + $ok.Count + ' 个，失败 ' + $fail.Count + ' 个，总用时 ' + (Format-Duration $totalSeconds)) Cyan
    Write-Log '==================================================' Cyan

    if ($ok.Count -gt 0) {
        Write-Log ''
        Write-Log '成功：' Green
        foreach ($r in $ok) {
            Write-Log ('  * ' + $r.Project + '  [' + $r.Platform + ']  ' + (Format-Size $r.Bytes)) Green
            Write-Log ('      ' + $r.File) DarkGray
            if ($r.Message) { Write-Log ('      注意：' + $r.Message) Yellow }
        }
    }
    if ($fail.Count -gt 0) {
        Write-Log ''
        Write-Log '失败：' Red
        foreach ($r in $fail) {
            Write-Log ('  * ' + $r.Project + '  [' + $r.Platform + ']  ' + $r.Message) Red
        }
        Write-Log ''
        Write-Log '常见原因：' Yellow
        Write-Log '  - 游戏正在运行，输出文件被占用 -> 先关掉游戏窗口再双击本脚本' Yellow
        Write-Log '  - C# 工程编译失败 -> 在项目目录执行 dotnet build 看具体错误' Yellow
        Write-Log '  - 缺少导出模板 / Android SDK / JDK -> 见上面的 [提示]' Yellow
        Write-Log '  - 项目在 Godot 编辑器里开着 -> 先关闭编辑器再导出' Yellow
    }

    # ---------------- 写日志 ----------------
    try {
        $logDir = Join-Path $scriptRoot '.export-logs'
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
        $logFile = Join-Path $logDir ('export-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
        $script:LogLines | Out-File -FilePath $logFile -Encoding UTF8
        Write-Log ''
        Write-Log ('日志：' + $logFile) DarkGray
    }
    catch {
        Write-Log ('[提示] 日志写入失败：' + $_.Exception.Message) Yellow
    }

    if ($fail.Count -gt 0) { return 1 }
    return 0
}

# ------------------------------------------------------------------ 入口

$exitCode = 1
try {
    $exitCode = Invoke-Main
}
catch {
    Write-Log ''
    Write-Log ('[错误] ' + $_.Exception.Message) Red
    $exitCode = 1
}

# 这里不暂停：双击入口是 export-godot.bat，由它负责「按任意键关闭窗口」。
exit $exitCode
