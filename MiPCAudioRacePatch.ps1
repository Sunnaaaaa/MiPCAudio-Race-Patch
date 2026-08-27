[CmdletBinding()]
param(
    [ValidateSet('Status', 'Apply', 'Restore')]
    [string]$Mode = 'Status',
    [ValidateRange(250, 2000)]
    [int]$DelayMs = 350,
    [switch]$WaitAtEnd
)

$ErrorActionPreference = 'Stop'
$script:BackupSuffix = '.mipaudio-patch-backup'
$script:MetadataSuffix = '.mipaudio-patch.json'

function Write-Good([string]$Text) { Write-Host $Text -ForegroundColor Green }
function Write-Bad([string]$Text) { Write-Host $Text -ForegroundColor Red }

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-Elevated {
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath),
        '-Mode', $Mode,
        '-DelayMs', $DelayMs,
        '-WaitAtEnd'
    )
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments -Wait -PassThru
    exit $process.ExitCode
}

function Get-Installation {
    $root = Join-Path $env:ProgramFiles 'MI\XiaomiPCManager'
    $runFile = Join-Path $root '.run'
    if (-not (Test-Path -LiteralPath $runFile)) { throw "找不到版本文件：$runFile" }
    $runInfo = Get-Content -LiteralPath $runFile -Raw | ConvertFrom-Json
    $version = [string]$runInfo.version
    if ([string]::IsNullOrWhiteSpace($version)) { throw '.run 中没有有效版本号。' }
    $target = Join-Path (Join-Path $root $version) 'MiPlayPCAudioDll.dll'
    $launcher = Join-Path $root 'Launch.exe'
    if (-not (Test-Path -LiteralPath $target)) { throw "找不到目标 DLL：$target" }
    if (-not (Test-Path -LiteralPath $launcher)) { throw "找不到启动器：$launcher" }
    [pscustomobject]@{ Version = $version; Target = $target; Launcher = $launcher }
}

function Get-U16([byte[]]$Data, [int]$Offset) { [BitConverter]::ToUInt16($Data, $Offset) }
function Get-U32([byte[]]$Data, [int]$Offset) { [BitConverter]::ToUInt32($Data, $Offset) }
function Get-U64([byte[]]$Data, [int]$Offset) { [BitConverter]::ToUInt64($Data, $Offset) }

function Find-SleepPatchSite([byte[]]$Data) {
    if ($Data.Length -lt 256 -or $Data[0] -ne 0x4D -or $Data[1] -ne 0x5A) { throw '目标文件不是有效 PE 文件。' }
    $pe = [int](Get-U32 $Data 0x3C)
    if ($Data[$pe] -ne 0x50 -or $Data[$pe + 1] -ne 0x45 -or $Data[$pe + 2] -ne 0 -or $Data[$pe + 3] -ne 0) { throw 'PE 文件头无效。' }
    $sectionCount = [int](Get-U16 $Data ($pe + 6))
    $optionalSize = [int](Get-U16 $Data ($pe + 20))
    $optional = $pe + 24
    if ((Get-U16 $Data $optional) -ne 0x20B) { throw '只支持 64 位 PE32+ DLL。' }
    $importRva = [uint32](Get-U32 $Data ($optional + 120))
    $sectionsOffset = $optional + $optionalSize
    $sections = @()
    for ($i = 0; $i -lt $sectionCount; $i++) {
        $o = $sectionsOffset + $i * 40
        $name = [Text.Encoding]::ASCII.GetString($Data, $o, 8).Trim([char]0)
        $sections += [pscustomobject]@{
            Name = $name; VirtualSize = [uint32](Get-U32 $Data ($o + 8));
            VirtualAddress = [uint32](Get-U32 $Data ($o + 12)); RawSize = [uint32](Get-U32 $Data ($o + 16));
            RawOffset = [uint32](Get-U32 $Data ($o + 20))
        }
    }
    function Convert-Rva([uint32]$Rva) {
        foreach ($section in $sections) {
            $size = [Math]::Max([uint64]$section.VirtualSize, [uint64]$section.RawSize)
            if ([uint64]$Rva -ge [uint64]$section.VirtualAddress -and [uint64]$Rva -lt ([uint64]$section.VirtualAddress + $size)) {
                return [int]([uint64]$section.RawOffset + [uint64]$Rva - [uint64]$section.VirtualAddress)
            }
        }
        throw ('无法映射 RVA 0x{0:X}。' -f $Rva)
    }
    function Read-CString([int]$Offset) {
        $end = $Offset
        while ($end -lt $Data.Length -and $Data[$end] -ne 0) { $end++ }
        [Text.Encoding]::ASCII.GetString($Data, $Offset, $end - $Offset)
    }

    $sleepIatRva = $null
    $desc = Convert-Rva $importRva
    while ($desc + 20 -le $Data.Length) {
        $allZero = $true
        for ($z = 0; $z -lt 20; $z++) { if ($Data[$desc + $z] -ne 0) { $allZero = $false; break } }
        if ($allZero) { break }
        $originalFirstThunk = [uint32](Get-U32 $Data $desc)
        $firstThunk = [uint32](Get-U32 $Data ($desc + 16))
        if ($originalFirstThunk -eq 0) { $lookupRva = $firstThunk } else { $lookupRva = $originalFirstThunk }
        $lookup = Convert-Rva $lookupRva
        for ($index = 0; ; $index++) {
            $entry = [uint64](Get-U64 $Data ($lookup + $index * 8))
            if ($entry -eq 0) { break }
            if (($entry -band 0x8000000000000000) -ne 0) { continue }
            $importName = Read-CString ((Convert-Rva ([uint32]$entry)) + 2)
            if ($importName -ceq 'Sleep') { $sleepIatRva = [uint32]($firstThunk + $index * 8) }
        }
        $desc += 20
    }
    if ($null -eq $sleepIatRva) { throw 'DLL 没有导入 Kernel32!Sleep，版本结构可能已变化。' }

    $text = @($sections | Where-Object Name -eq '.text')
    if ($text.Count -ne 1) { throw 'DLL 没有唯一的 .text 节。' }
    $start = [int]$text[0].RawOffset
    $end = [Math]::Min($Data.Length, $start + [int]$text[0].RawSize)
    $hits = @()
    for ($pos = $start + 9; $pos -le $end - 6; $pos++) {
        if ($Data[$pos] -ne 0xFF -or $Data[$pos + 1] -ne 0x15) { continue }
        $instructionRva = [uint32]([uint64]$text[0].VirtualAddress + [uint64]($pos - $start))
        $signedDisplacement = [BitConverter]::ToInt32($Data, $pos + 2)
        $targetRva = [uint32](([int64]$instructionRva + 6 + [int64]$signedDisplacement) -band 0xFFFFFFFFL)
        if ($targetRva -ne $sleepIatRva) { continue }
        if ($Data[$pos - 9] -eq 0xB9 -and $Data[$pos - 4] -eq 0x48 -and $Data[$pos - 3] -eq 0x89 -and $Data[$pos - 2] -eq 0x47 -and $Data[$pos - 1] -eq 0x10) {
            $hits += [pscustomobject]@{ Offset = $pos - 8; Delay = [BitConverter]::ToInt32($Data, $pos - 8) }
        }
    }
    if ($hits.Count -ne 1) { throw "应找到 1 个安全补丁点，实际找到 $($hits.Count) 个；拒绝修改此版本。" }
    return $hits[0]
}

function Get-Sha256([byte[]]$Data) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Data))).Replace('-', '') } finally { $sha.Dispose() }
}

function Stop-ManagerProcesses {
    Get-Process -Name 'XiaomiPcManager','MiPCAudio' -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 1500
}

function Start-Manager([string]$Launcher) {
    Start-Process -FilePath $Launcher -ArgumentList '--AutoRun=1' -WorkingDirectory (Split-Path $Launcher)
}

function Get-RecentConnectionState([datetime]$Since = [datetime]::MinValue) {
    $dir = Join-Path $env:ProgramData 'MI\Miplay\AudioShare\PCAudiodll'
    if (-not (Test-Path -LiteralPath $dir)) { return '没有控制日志' }
    foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter '*.log' -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 2)) {
        if ($file.LastWriteTime -lt $Since) { continue }
        try { $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop } catch { continue }
        if ($text -match 'Connect successed') { return '连接成功' }
        if ($text -match 'connect failed -4058') { return '循环失败（-4058）' }
    }
    return '尚无明确结果'
}

function Test-PatchedConnection {
    $stablePid = $null; $stablePolls = 0; $verificationStart = Get-Date; $deadline = $verificationStart.AddSeconds(35)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (-not (Get-Process -Name 'XiaomiPcManager' -ErrorAction SilentlyContinue)) { return @{ Success = $false; Message = '电脑管家主进程已退出' } }
        $audio = Get-Process -Name 'MiPCAudio' -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending | Select-Object -First 1
        if ($audio) {
            if ($stablePid -eq $audio.Id) { $stablePolls++ } else { $stablePid = $audio.Id; $stablePolls = 1 }
        }
        if ((Get-RecentConnectionState -Since $verificationStart) -eq '连接成功' -and $stablePolls -ge 8) {
            return @{ Success = $true; Message = "IPC 连接成功，MiPCAudio PID $stablePid 持续稳定" }
        }
    }
    return @{ Success = $false; Message = '超时，未同时观察到连接成功和稳定 PID' }
}

function Show-Status {
    $install = Get-Installation
    $bytes = [IO.File]::ReadAllBytes($install.Target)
    $site = Find-SleepPatchSite $bytes
    $backupExists = (Test-Path -LiteralPath ($install.Target + $script:BackupSuffix)) -or (Test-Path -LiteralPath ($install.Target + '.original'))
    Write-Host "当前管家版本：$($install.Version)"
    Write-Host "当前等待时间：$($site.Delay) ms"
    Write-Host ('补丁状态：' + $(if ($site.Delay -gt 200) { '已修改' } else { '官方原始值' }))
    Write-Host ('原始备份：' + $(if ($backupExists) { '存在' } else { '不存在' }))
    Write-Host "MiPCAudio 进程数：$(@(Get-Process -Name 'MiPCAudio' -ErrorAction SilentlyContinue).Count)"
    Write-Host "最近通信状态：$(Get-RecentConnectionState)"
    Write-Host "DLL SHA-256：$(Get-Sha256 $bytes)"
}

function Apply-Patch {
    if (-not (Test-Administrator)) { Start-Elevated }
    $install = Get-Installation; $target = $install.Target
    $backup = $target + $script:BackupSuffix; $legacy = $target + '.original'; $metadata = $target + $script:MetadataSuffix
    $current = [IO.File]::ReadAllBytes($target); $site = Find-SleepPatchSite $current
    Write-Host "当前管家版本：$($install.Version)"; Write-Host "检测到连接前等待：$($site.Delay) ms"
    if ($site.Delay -eq $DelayMs) { Write-Good '当前版本已经应用相同补丁，无需重复操作。'; return }
    if ($site.Delay -ne 200 -and -not (Test-Path $backup) -and -not (Test-Path $legacy)) { throw "当前等待值为 $($site.Delay) ms，且没有可信原始备份，拒绝修改。" }
    if (-not (Test-Path $backup)) {
        if ($site.Delay -eq 200) { [IO.File]::WriteAllBytes($backup, $current) }
        elseif (Test-Path $legacy) { Copy-Item -LiteralPath $legacy -Destination $backup }
    }
    $original = [IO.File]::ReadAllBytes($backup); $originalSite = Find-SleepPatchSite $original
    if ($originalSite.Delay -ne 200) { throw '备份 DLL 不是未修改的 200 ms 版本，拒绝继续。' }
    $patched = [byte[]]$current.Clone(); [BitConverter]::GetBytes([int]$DelayMs).CopyTo($patched, [int]$site.Offset)
    Stop-ManagerProcesses
    try {
        [IO.File]::WriteAllBytes($target, $patched)
        @{ version=$install.Version; patchedAt=(Get-Date).ToString('o'); originalDelayMs=200; patchedDelayMs=$DelayMs; originalSha256=(Get-Sha256 $original); patchedSha256=(Get-Sha256 $patched); patchOffset=('0x{0:X}' -f $site.Offset) } |
            ConvertTo-Json | Set-Content -LiteralPath $metadata -Encoding UTF8
        Start-Manager $install.Launcher
        Write-Host '正在验证本地通信和进程稳定性（最长约 35 秒）……'
        $result = Test-PatchedConnection
        if (-not $result.Success) { throw ('验证失败：' + $result.Message) }
        Write-Good ('补丁成功：' + $result.Message)
        Write-Host '提示：DLL 内容已修改，因此原小米数字签名会显示 HashMismatch；原文件已备份。'
    } catch {
        Write-Host '补丁未通过验证，正在自动恢复原始 DLL……'
        Stop-ManagerProcesses; Copy-Item -LiteralPath $backup -Destination $target -Force
        Remove-Item -LiteralPath $metadata -Force -ErrorAction SilentlyContinue; Start-Manager $install.Launcher
        throw
    }
}

function Restore-Patch {
    if (-not (Test-Administrator)) { Start-Elevated }
    $install = Get-Installation; $target = $install.Target
    $backup = $target + $script:BackupSuffix; $legacy = $target + '.original'
    if (Test-Path $backup) { $source = $backup } elseif (Test-Path $legacy) { $source = $legacy } else { throw '当前版本没有找到原始备份，无法自动还原。' }
    if ((Find-SleepPatchSite ([IO.File]::ReadAllBytes($source))).Delay -ne 200) { throw '备份不是原始 200 ms 版本，拒绝还原。' }
    Stop-ManagerProcesses; Copy-Item -LiteralPath $source -Destination $target -Force
    Remove-Item -LiteralPath ($target + $script:MetadataSuffix) -Force -ErrorAction SilentlyContinue
    Start-Manager $install.Launcher; Write-Good "已还原 $($install.Version) 的原始 DLL，并重新启动电脑管家。"
}

$exitCode = 0
try {
    switch ($Mode) { 'Status' { Show-Status }; 'Apply' { Apply-Patch }; 'Restore' { Restore-Patch } }
} catch {
    Write-Bad ('操作失败：' + $_.Exception.Message); $exitCode = 1
}
if ($WaitAtEnd) { Write-Host ''; Read-Host '按回车键关闭' | Out-Null }
exit $exitCode
