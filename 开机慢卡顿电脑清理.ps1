#Requires -Version 5.1
<#
================================================================
 开机慢卡顿电脑清理  v1.1
 解决: 开机慢 / 加载桌面慢 / 黑屏 / 电脑卡顿 / 垃圾清理
 用法:  powershell -ExecutionPolicy Bypass -File "开机慢卡顿电脑清理.ps1"
================================================================
#>
param(
    [ValidateSet('Menu','Scan','Fix','Junk','Rollback','Bench')][string]$Mode = 'Menu'
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$APP_DIR  = Split-Path -Parent $MyInvocation.MyCommand.Path
$DATA_DIR = Join-Path $env:ProgramData 'KaQiCleanup'
$BAK_DIR  = Join-Path $DATA_DIR 'backups'
New-Item -ItemType Directory -Path $BAK_DIR -Force | Out-Null
$STAMP     = Get-Date -Format 'yyyyMMdd_HHmmss'
$THIS_BAK  = Join-Path $BAK_DIR $STAMP
$MANIFEST  = Join-Path $THIS_BAK 'rollback.json'

# ============================ 提权 ============================
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) {
    Write-Host ''
    Write-Host '  需要管理员权限, 正在请求授权...' -ForegroundColor Yellow
    Write-Host '  请在弹出的窗口中点击 [是]' -ForegroundColor Yellow
    Start-Sleep -Seconds 2
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Mode',$Mode
    ) -WorkingDirectory $APP_DIR
    exit
}

# ============================ 系统兼容性检查 ============================
function Test-Compatibility {
    # 在最早期告知用户当前系统是否完全支持, 避免运行到一半才发现功能缺失
    $os = $null
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch {}
    if (-not $os) { return }

    $build = 0
    try { $build = [int]$os.BuildNumber } catch {}
    $name  = "$($os.Caption)"

    # 硬门槛判定。
    # 注意: Windows 7 的 Build 就是 7601, 和 Windows 8.1 相同,
    # 只看 BuildNumber 无法区分 Win7/Win8。因此必须双条件:
    #   1) Build >= 9200        (Windows 8 起)
    #   2) 存在 Storage 模块    (Get-Volume/Get-PhysicalDisk 的提供程序, Win8 才引入)
    $hasStorage = $null -ne (Get-Command Get-Volume -ErrorAction SilentlyContinue)
    $tooOld = ($build -lt 9200) -or (-not $hasStorage)

    if ($tooOld) {
        Clear-Line
        Write-Host ('=' * 64) -ForegroundColor Red
        Write-Host '  系统版本过低, 无法保证功能正常' -ForegroundColor Red
        Write-Host ('=' * 64) -ForegroundColor Red
        Write-Host ''
        Write-Host "  当前系统: $name (Build $build)" -ForegroundColor Yellow
        Write-Host '  本工具需要: Windows 8 / 8.1 / 10 / 11 (Build 9200 及以上)' -ForegroundColor Yellow
        Write-Host "  Storage 存储模块: $(if($hasStorage){'存在'}else{'缺失'})" -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  在 Windows 7 及更早版本上以下功能会失效:' -ForegroundColor Gray
        Write-Host '    - 磁盘枚举与扫描修复 (缺少 Storage 模块 / Get-Volume)'
        Write-Host '    - 开机计划任务扫描 (缺少 ScheduledTasks 模块)'
        Write-Host '    - 物理磁盘健康信息读取'
        Write-Host '    - 快速启动开关 (该功能 Windows 8 才引入)'
        Write-Host ''
        Write-Host '  仍可使用的功能: 垃圾清理 / 注册表残留清理 / 基础检测'
        Write-Host ''
        Write-Host '  仍要继续吗? (部分功能不可用)' -ForegroundColor Yellow
        $a = Read-Host '  输入 Y 继续'
        if ($a -notmatch '^[Yy]') { exit }
        Clear-Line
    }

    # 提示缺失的可选组件(不阻断, 只是让用户知道少了什么)
    $missing = @()
    foreach ($c in @('Get-Volume','Get-ScheduledTask','Get-MpPreference')) {
        if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { $missing += $c }
    }
    if ($missing.Count -gt 0) {
        # 只提示一次, 避免每步都刷
        $script:MissingCmds = $missing
    }
}

# ============================ 输出函数 ============================
function Clear-Line { Write-Host '' }
function Banner {
    Clear-Line
    Write-Host ('=' * 64) -ForegroundColor Cyan
    Write-Host "  开机慢卡顿电脑清理" -ForegroundColor White
    Write-Host ('=' * 64) -ForegroundColor Cyan
}
function Section([string]$t) {
    Clear-Line
    Write-Host ('-' * 64) -ForegroundColor DarkCyan
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ('-' * 64) -ForegroundColor DarkCyan
}
function Ok($t)    { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Info($t)  { Write-Host "  [信息] $t" -ForegroundColor Gray }
function Warn($t)  { Write-Host "  [注意] $t" -ForegroundColor Yellow }
function Bad($t)   { Write-Host "  [问题] $t" -ForegroundColor Red }
function Head($t)  { Write-Host "`n  $t" -ForegroundColor White }
function Ask([string]$q, [string]$d = 'Y') {
    $a = Read-Host "     $q (Y/N) [$d]"
    if ([string]::IsNullOrWhiteSpace($a)) { $a = $d }
    return ($a -match '^[Yy]')
}

# ============================ 备份登记 ============================
$script:RB = [System.Collections.ArrayList]::new()
function Backup-Record([string]$type, [string]$key, $value) {
    [void]$script:RB.Add([PSCustomObject]@{ type=$type; key=$key; value=$value })
}
function Backup-Save {
    $script:RB | ConvertTo-Json -Depth 5 | Set-Content -Path $MANIFEST -Encoding UTF8
}
function Backup-RunKey([string]$path, [string]$name) {
    $v = (Get-ItemProperty $path -Name $name -ErrorAction SilentlyContinue).($name)
    if ($null -ne $v) { Backup-Record 'RunKey' "$path::$name" $v }
}
function Backup-Service([string]$name) {
    $sv = Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue
    if ($sv) { Backup-Record 'Service' $name $sv.StartMode }
}
function Backup-Value([string]$path, [string]$name) {
    $v = (Get-ItemProperty $path -Name $name -ErrorAction SilentlyContinue).($name)
    if ($null -ne $v) { Backup-Record 'RegValue' "$path::$name" $v }
}

# =================================================================
#  检测模块
# =================================================================

function Get-BootTiming {
    $r = [PSCustomObject]@{
        LastBoot = $null; LogEnabled = $false; Times = @()
        BootSec = 0; MainPathSec = 0; PostSec = 0; DegrSec = 0
    }
    try { $r.LastBoot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime } catch {}
    $ln = 'Microsoft-Windows-Diagnostics-Performance/Operational'
    try {
        $log = Get-WinEvent -ListLog $ln -ErrorAction Stop
        $r.LogEnabled = $log.IsEnabled
        if ($log.IsEnabled -and $log.RecordCount -gt 0) {
            $list = @()
            $evs = Get-WinEvent -FilterHashtable @{ LogName=$ln; Id=100 } -MaxEvents 10 -ErrorAction SilentlyContinue
            foreach ($e in $evs) {
                try {
                    $x = [xml]$e.ToXml(); $m = @{}
                    foreach ($n in $x.Event.EventData.Data) { $m[$n.Name] = $n.'#text' }
                    $list += [PSCustomObject]@{
                        Time      = $e.TimeCreated
                        BootMs    = [int]$m['BootTime']
                        MainMs    = [int]$m['MainPathBootTime']
                        PostMs    = [int]$m['BootPostBootTime']
                        DegrMs    = [int]$m['BootDegradationTime']
                    }
                } catch {}
            }
            if ($list.Count) {
                $r.Times = $list
                $r.BootSec   = [math]::Round((($list | Measure-Object BootMs -Average).Average)/1000,1)
                $r.MainPathSec = [math]::Round((($list | Measure-Object MainMs -Average).Average)/1000,1)
                $r.PostSec   = [math]::Round((($list | Measure-Object PostMs -Average).Average)/1000,1)
                $r.DegrSec   = [math]::Round((($list | Measure-Object DegrMs -Average).Average)/1000,1)
            }
        }
    } catch {}
    return $r
}

function Enable-DiagLog {
    $ln = 'Microsoft-Windows-Diagnostics-Performance/Operational'
    try {
        wevtutil sl $ln /e:true 2>&1 | Out-Null
        return $true
    } catch { return $false }
}

function Get-DiskProfile {
    $d = [PSCustomObject]@{ Disks=@(); IsSsd=$false; CFreeGB=0; CTotalGB=0 }
    try {
        $disks = Get-PhysicalDisk -ErrorAction Stop
        foreach ($x in $disks) {
            $d.Disks += [PSCustomObject]@{
                Name = $x.FriendlyName; Media = $x.MediaType; Bus = $x.BusType
                SizeGB = [math]::Round($x.Size/1GB,0); Health = $x.HealthStatus
            }
            if ("$($x.MediaType)" -match 'SSD|Solid') { $d.IsSsd = $true }
        }
    } catch {
        # 回退: Get-PhysicalDisk 不可用时用 WMI, 并靠型号名判断固态
        foreach ($x in (Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue)) {
            $nm = "$($x.Model) $($x.Caption)"
            $isSsd = ($nm -match '(?i)SSD|NVMe|Intel.*Optane|Solid State')
            $d.Disks += [PSCustomObject]@{
                Name = $x.Model; Bus = $x.InterfaceType
                Media = $(if ($isSsd) { 'SSD' } else { 'HDD' })
                SizeGB = [math]::Round($x.Size/1GB,0); Health = $x.Status
            }
            if ($isSsd) { $d.IsSsd = $true }
        }
    }

    # C 盘空间: 优先 Get-Volume, 缺失时用 WMI 回退(Win7 无 Storage 模块)
    $cDrive = [char]67
    if ($null -ne (Get-Command Get-Volume -ErrorAction SilentlyContinue)) {
        try {
            $v = Get-Volume -DriveLetter $cDrive -ErrorAction Stop
            $d.CFreeGB  = [math]::Round($v.SizeRemaining/1GB,1)
            $d.CTotalGB = [math]::Round($v.Size/1GB,1)
        } catch {}
    } else {
        try {
            $ld = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
            $d.CFreeGB  = [math]::Round($ld.FreeSpace/1GB,1)
            $d.CTotalGB = [math]::Round($ld.Size/1GB,1)
        } catch {}
    }
    return $d
}

function Test-DiskSpeed {
    # 注: 不能只读一个大文件, Windows 文件缓存会给出虚高的假速度。
    # 正确做法: 随机挑多个文件, 每个只读首块, 尽量命中不同磁盘位置。
    $r = [PSCustomObject]@{ ColdMBps = 0; FileCountMs = 0; Slow = $false }
    $files = @(Get-ChildItem "$env:SystemRoot\System32" -Filter *.dll -ErrorAction SilentlyContinue)
    if ($files.Count -gt 20) {
        try {
            $pick = $files | Get-Random -Count ([math]::Min(25, $files.Count))
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $tot = 0L
            $buf = New-Object byte[] 65536
            foreach ($f in $pick) {
                try {
                    $tot += $f.Length
                    $fs = [IO.File]::OpenRead($f.FullName)
                    $null = $fs.Read($buf, 0, $buf.Length)
                    $fs.Close()
                } catch {}
            }
            $sw.Stop()
            $sec = $sw.Elapsed.TotalSeconds
            if ($sec -gt 0) { $r.ColdMBps = [math]::Round(($tot/1MB)/$sec, 1) }
        } catch {}
    }
    # 小文件枚举耗时: 最能反映开机时加载几千个系统文件的速度
    try {
        $sw2 = [Diagnostics.Stopwatch]::StartNew()
        $null = @(Get-ChildItem "$env:SystemRoot\System32" -Filter *.dll -ErrorAction SilentlyContinue)
        $sw2.Stop()
        $r.FileCountMs = [math]::Round($sw2.Elapsed.TotalMilliseconds)
    } catch {}
    # 判定: SSD 冷读一般 >200MB/s, 机械盘通常 10-120MB/s
    if ($r.ColdMBps -gt 0 -and $r.ColdMBps -lt 60) { $r.Slow = $true }
    if ($r.FileCountMs -gt 3000) { $r.Slow = $true }
    return $r
}
function Get-StartupItems {
    $items = [System.Collections.ArrayList]::new()

    $runPaths = @(
        @{ P='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';              Src='注册表 HKLM' },
        @{ P='HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';  Src='注册表 HKLM32' },
        @{ P='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';              Src='注册表 HKCU' }
    )
    foreach ($rp in $runPaths) {
        $o = Get-ItemProperty $rp.P -ErrorAction SilentlyContinue
        if ($o) {
            foreach ($p in $o.PSObject.Properties) {
                if ($p.Name -like 'PS*') { continue }
                [void]$items.Add([PSCustomObject]@{
                    Name=$p.Name; Source=$rp.Src; Kind='RunKey'
                    Cmd=$p.Value; Path=$rp.P; Vendor=$null; Startup='-'
                })
            }
        }
    }

    $folders = @(
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
    )
    foreach ($f in $folders) {
        foreach ($f2 in (Get-ChildItem $f -ErrorAction SilentlyContinue)) {
            [void]$items.Add([PSCustomObject]@{
                Name=$f2.Name; Source='启动文件夹'; Kind='Folder'
                Cmd=$f2.FullName; Path=$f2.FullName; Vendor=$null; Startup='-'
            })
        }
    }

    foreach ($s in (Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)) {
        if ($s.StartMode -eq 'Auto' -and $s.State -eq 'Running' -and
            $s.PathName -and $s.PathName -notmatch '(?i)^\s*"?C:\\Windows\\') {
            [void]$items.Add([PSCustomObject]@{
                Name=$s.DisplayName; Source='服务(自动)'; Kind='Service'
                Cmd=$s.PathName; Path=$s.Name; Vendor=$null; Startup='服务'
            })
        }
    }

    try {
        foreach ($t in (Get-ScheduledTask -ErrorAction Stop)) {
            if ($t.TaskPath -like '\Microsoft\*') { continue }
            if ($t.State -eq 'Disabled') { continue }
            $has = @($t.Triggers | Where-Object {
                $_.CimClass.CimClassName -match 'LogonTrigger|BootTrigger' }).Count
            if ($has -gt 0) {
                [void]$items.Add([PSCustomObject]@{
                    Name=$t.TaskName; Source='计划任务'; Kind='Task'
                    Cmd=$t.TaskPath + $t.TaskName; Path=$t.TaskPath + $t.TaskName
                    Vendor=$null; Startup='计划'
                })
            }
        }
    } catch {}

    return ,$items
}

function Get-DiskErrors {
    $r = [PSCustomObject]@{ ByDrive = @{}; DiskErr = 0; WHEA = 0; LastReal = $null }
    try {
        $ev = Get-WinEvent -FilterHashtable @{ LogName='System'; Id=55,98 } -MaxEvents 300 -ErrorAction SilentlyContinue |
              Where-Object { $_.ProviderName -eq 'Ntfs' }
        foreach ($e in $ev) {
            if ($e.Message -match ([char]0x5377 + '\s*([A-Z]):')) { $dv = $Matches[1]; if (-not $r.ByDrive.ContainsKey($dv)) { $r.ByDrive[$dv] = 0 }; $r.ByDrive[$dv]++ }

            if ($r.LastReal -eq $null -or $e.TimeCreated -gt $r.LastReal) { $r.LastReal = $e.TimeCreated }
        }
    } catch {}
    try {
        $r.DiskErr = @(Get-WinEvent -FilterHashtable @{ LogName='System'; Level=1,2,3 } -MaxEvents 200 -ErrorAction SilentlyContinue |
                       Where-Object { $_.ProviderName -match '^(Disk|Ntfs|storahci|stornvme|iaStor)' }).Count
    } catch {}
    try {
        $r.WHEA = @(Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger' } -MaxEvents 20 -ErrorAction SilentlyContinue).Count
    } catch {}
    return $r
}

function Get-SystemInfo {
    # 注意: 不能用 [PSCustomObject]@{} —— 空对象不可扩展, 赋值会抛异常被 catch 吞掉
    # 必须用 [ordered]@{} 或预先声明全部属性
    $s = [PSCustomObject]@{ Brand=""; CPU=""; OS=""; RAMGB=0; PageFile=""; FastBoot=$null; Hiber=$null; ReadyBoot=$null }
    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        $s.Brand = "$($cs.Manufacturer) $($cs.Model)"
        $s.RAMGB = [math]::Round($cs.TotalPhysicalMemory/1GB,1)
    } catch {}
    try { $s.CPU = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim() } catch {}
    try { $s.OS = (Get-CimInstance Win32_OperatingSystem).Caption } catch {}
    try {
        $pf = Get-CimInstance Win32_PageFileUsage -ErrorAction Stop
        $s.PageFile = ($pf | ForEach-Object { "$($_.Name) ($($_.AllocatedBaseSize)MB)" }) -join ', '
    } catch { $s.PageFile = '无' }
    try {
        $s.FastBoot = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction Stop).HiberbootEnabled
    } catch { $s.FastBoot = $null }
    try {
        $s.Hiber = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction Stop).HibernateEnabled
    } catch { $s.Hiber = $null }
    try { $s.ReadyBoot = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' -ErrorAction Stop).EnablePrefetcher } catch { $s.ReadyBoot = $null }
    return $s
}

function Get-TempStats {
    $r = [PSCustomObject]@{ UserGB=0; WinGB=0; RecycleGB=0; WerGB=0 }
    function DirSize($p) {
        if (-not (Test-Path $p)) { return 0 }
        try { return [math]::Round(((Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum)/1GB,2) } catch { return 0 }
    }
    $r.UserGB    = DirSize $env:TEMP
    $r.WinGB     = DirSize "$env:SystemRoot\Temp"
    $r.RecycleGB = DirSize "$env:SystemDrive\`$Recycle.Bin"
    $r.WerGB     = DirSize "$env:ProgramData\Microsoft\Windows\WER"
    return $r
}

# =================================================================
#  扫描报告
# =================================================================
function Invoke-Scan([switch]$Quiet) {
    if (-not $Quiet) { Banner }
    $issues = [System.Collections.ArrayList]::new()

    Section '硬件与系统'
    $sys = Get-SystemInfo
    $disk = Get-DiskProfile
    Info "机型    : $($sys.Brand)"
    Info "处理器  : $($sys.CPU)"
    Info "内存    : $($sys.RAMGB) GB"
    Info "系统    : $($sys.OS)"
    if ($disk.Disks) {
        foreach ($x in $disk.Disks) {
            Info ("磁盘    : {0} | {1} | {2}GB | {3}" -f $x.Name,$x.Media,$x.SizeGB,$x.Health)
        }
    }
    Info "C盘     : 剩余 $($disk.CFreeGB) GB / 共 $($disk.CTotalGB) GB"

    Head '硬盘速度 (开机慢的核心指标)'
    $sp = Test-DiskSpeed
    if ($sp.ColdMBps -gt 0) {
        Info ("冷读取速度  : {0} MB/s   (随机多文件实测)" -f $sp.ColdMBps)
        if ($sp.ColdMBps -lt 60) {
            Bad "速度明显偏低 —— 这就是开机慢的根本原因"
            [void]$issues.Add('硬盘读取速度不足')
        } elseif ($sp.ColdMBps -lt 200) { Warn "速度一般 (机械盘高速型号或低端SSD)" }
        else { Ok '速度良好 (固态硬盘水平)' }
    }
    if ($sp.FileCountMs -gt 0) {
        Info ("枚举系统DLL耗时: {0} 毫秒" -f $sp.FileCountMs)
        if ($sp.FileCountMs -gt 3000) { Bad "读取小文件很慢, 开机时加载系统文件会被严重拖慢" }
    }
    if (-not $disk.IsSsd) {
        Warn '未检测到固态硬盘 —— 硬件层面无法根治, 建议加装 SSD'
    }

    Section '开机耗时'
    $bt = Get-BootTiming
    if ($bt.LastBoot) { Info "上次开机: $($bt.LastBoot)" }
    if ($bt.LogEnabled -and $bt.Times.Count) {
        Ok "性能日志已启用, 近 $($bt.Times.Count) 次开机平均:"
        Info ("  主启动耗时    : {0} 秒" -f $bt.MainPathSec)
        Info ("  登录后加载    : {0} 秒" -f $bt.PostSec)
        Info ("  完整开机总计  : {0} 秒" -f $bt.BootSec)
        if ($bt.DegrSec -gt 1) {
            Warn ("性能退化 {0} 秒 (自启动项拖慢)" -f $bt.DegrSec)
            [void]$issues.Add('开机性能退化')
        }
        Head '最近 5 次开机明细'
        $bt.Times | Select-Object -First 5 | ForEach-Object {
            Write-Host ("     {0}  主启动 {1,6:N1}s  登录后 {2,5:N1}s  总计 {3,6:N1}s" -f `
                $_.Time.ToString('MM-dd HH:mm'), ($_.MainMs/1000), ($_.PostMs/1000), ($_.BootMs/1000)) -ForegroundColor Gray
        }
    } else {
        Warn '开机性能日志未启用, 无法获取精确耗时分解'
        Info '建议启用后重启一次, 即可看到专业级的启动耗时分析'
        [void]$issues.Add('性能日志未启用')
    }

    Section '启动速度相关设置'
    if ($sys.FastBoot -eq 1) { Ok '快速启动: 已开启' }
    else {
        Bad '快速启动: 未开启 (每次都是完整冷启动)'
        [void]$issues.Add('快速启动关闭')
    }
    if ($sys.Hiber -eq 1) { Ok '休眠功能: 已启用 (快速启动的前提)' }
    else { Bad '休眠功能: 未启用 —— 必须先启用休眠, 快速启动才能生效' }
    Info "页面文件  : $($sys.PageFile)"

    Section '磁盘错误'
    $de = Get-DiskErrors
$anyErr = $false
    if ($de.ByDrive -and $de.ByDrive.Count -gt 0) {
        foreach ($kv in ($de.ByDrive.GetEnumerator() | Sort-Object Name)) {
            if ($kv.Value -gt 0) {
                $anyErr = $true
                $extra = if ($kv.Name -eq 'C') { ' <- 系统盘, 这会严重拖慢开机!' } else { '' }
                Bad ("盘 {0}: 发现文件系统损坏 {1} 次{2}" -f $kv.Name, $kv.Value, $extra)
            }
        }
        if ($de.LastReal) { Info ("最后一次损坏记录: {0}" -f $de.LastReal) }
    }
    if (-not $anyErr) { Ok '未发现文件系统损坏' }
    if ($de.WHEA -gt 0) {
        Bad "硬件错误 (WHEA): $($de.WHEA) 条"
        [void]$issues.Add('硬件错误')
    }

    Section '开机自启项'
    $items = Get-StartupItems
    Info "共发现 $($items.Count) 项开机自启"
    $n = 0
    foreach ($i in $items) {
        $n++
        if ($n -gt 25) { Info "  ... 还有 $($items.Count - 25) 项"; break }
        $short = $i.Cmd
        if ($short -and $short.Length -gt 58) { $short = $short.Substring(0,55) + '...' }
        Write-Host ("     {0,-30} {1,-14} {2}" -f $i.Name, $i.Source, $short) -ForegroundColor Gray
    }
    $runCount = @($items | Where-Object { $_.Kind -eq 'RunKey' }).Count
    $svcCount = @($items | Where-Object { $_.Kind -eq 'Service' }).Count
    if ($runCount -ge 6) {
        Warn "注册表自启项 $($runCount) 个, 偏多"
        [void]$issues.Add('自启项过多')
    }

    Section '垃圾文件'
    $ts = Get-TempStats
    $tot = $ts.UserGB + $ts.WinGB + $ts.RecycleGB + $ts.WerGB
    Info ("用户临时  : {0} GB" -f $ts.UserGB)
    Info ("系统临时  : {0} GB" -f $ts.WinGB)
    Info ("回收站    : {0} GB" -f $ts.RecycleGB)
    Info ("错误报告  : {0} GB" -f $ts.WerGB)
    if ($tot -gt 2) {
        Warn "垃圾文件合计 $([math]::Round($tot,2)) GB"
        [void]$issues.Add('垃圾文件过多')
    }

    Section '扫描结论'
    if ($issues.Count -eq 0) {
        Ok '未发现明显问题, 系统状态良好'
    } else {
        Info "共发现 $($issues.Count) 项待处理:"
        $k = 0
        foreach ($x in $issues) { $k++; Write-Host "     $k. $x" -ForegroundColor Yellow }
    }
    return [PSCustomObject]@{ Issues = $issues; Items = $items; Sys = $sys; Disk = $disk }
}

# =================================================================
#  修复模块
# =================================================================
function Repair-FastStartup {
    Section '修复: 开启快速启动'
    Backup-Value 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled'
    $hib = 0
    try { $hib = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction Stop).HibernateEnabled } catch {}
    if ($hib -ne 1) {
        Warn '休眠未启用, 正在启用 (快速启动依赖它)'
        powercfg /h on 2>&1 | Out-Null
        Start-Sleep -Seconds 2
    }
    try {
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
            -Name 'HiberbootEnabled' -Value 1 -Type DWord -ErrorAction Stop
        Ok '快速启动已开启, 预计节省 20-40 秒'
    } catch { Bad "开启失败: $($_.Exception.Message)" }
}

function Get-ChkdskPatterns {
    # chkdsk 的输出文案随系统语言变化, 硬编码英文会让中文系统永远判定为 UNKNOWN。
    # 这里同时提供中英文模式, 并用 Unicode 码点构造, 避免脚本文件编码影响。
    $zh = @{
        Clean    = [char]0x6CA1 + [char]0x6709 + [char]0x53D1 + [char]0x73B0 + [char]0x95EE + [char]0x9898   # 没有发现问题
        Fixed    = [char]0x5DF2 + [char]0x4FEE + [char]0x6B63 + [char]0x4E86 + [char]0x6587 + [char]0x4EF6 + [char]0x7CFB + [char]0x7EDF   # 已修正了文件系统
        Fixed2   = [char]0x5DF2 + [char]0x4FEE + [char]0x6B63 + [char]0x4E86 + [char]0x5377   # 已修正了卷
        Problem  = [char]0x53D1 + [char]0x73B0 + [char]0x95EE + [char]0x9898   # 发现问题(注意: 不能与"没有问题"冲突)
        BadSect  = [char]0x574F + [char]0x6247 + [char]0x533A   # 坏扇区
        AccessD  = [char]0x62D2 + [char]0x7EDD + [char]0x8BBF + [char]0x95EE   # 拒绝访问
        Locked   = [char]0x4F7F + [char]0x7528 + [char]0x4E2D   # 使用中
        Duration = [char]0x603B + [char]0x65F6 + [char]0x95F4   # 总时间
    }
    $en = @{
        Clean    = 'found no problems|no errors'
        Fixed    = 'Windows has made corrections'
        Fixed2   = 'Windows has made corrections'
        Problem  = 'found problems'
        BadSect  = 'bad sectors'
        AccessD  = 'Access Denied|access is denied'
        Locked   = 'in use|is being used|cannot be locked'
        Duration = 'Total duration'
    }
    return [PSCustomObject]@{ Zh=$zh; En=$en }
}

function Invoke-Chkdsk {
    # 用 chkdsk 代替 Repair-Volume: Repair-Volume 没有任何输出参数,
    # 调用后拿不到结果, 无法判断是否真的修复成功。chkdsk 会输出明确文本。
    param([string]$DriveLetter, [switch]$SpotFix)

    $argStr = "$DriveLetter`: /scan"
    if ($SpotFix) { $argStr = "$DriveLetter`: /f /spotfix" }
    $raw = cmd /c "chkdsk $argStr" 2>&1 | Out-String -Width 300
    $raw = $raw -replace "`r", ''

    $P = Get-ChkdskPatterns
    $pat = @($P.En.Clean)     + @($P.Zh.Clean)
    $fix = @($P.En.Fixed, $P.En.Fixed2) + @($P.Zh.Fixed, $P.Zh.Fixed2)
    $prb = @($P.En.Problem)   + @($P.Zh.Problem)
    $bad = @($P.En.BadSect)   + @($P.Zh.BadSect)
    $acc = @($P.En.AccessD)   + @($P.Zh.AccessD)
    $lck = @($P.En.Locked)    + @($P.Zh.Locked)

    function Has($text, $patterns) {
        foreach ($x in $patterns) { if ($text -match $x) { return $true } }
        return $false
    }

    $denied   = Has $raw $acc
    $wasFixed = Has $raw $fix
    $clean    = Has $raw $pat
    # "没有问题" 里也含 "问题" 两字, 必须先排除"没有/未"的否定形式, 否则健康盘会误判为有问题
    $hasProb  = (Has $raw $prb) -and (-not $clean)
    $inUse    = Has $raw $lck

    # 坏扇区: 必须排除 "0 KB" 这种正常情况
    $badSec = $false
    foreach ($b in $bad) {
        # 形如 "  4096 KB in bad sectors" 或 "坏扇区 4096 KB"
        if ($raw -match "(?m)^.*?([0-9][0-9,]*)\s*KB.*$($b)") {
            $num = [regex]::Replace($Matches[1], ',', '')
            if ([int64]$num -gt 0) { $badSec = $true; break }
        }
    }

    $verdict = 'UNKNOWN'
    if ($denied)                        { $verdict = 'DENIED' }
    elseif ($wasFixed)                 { $verdict = 'FIXED' }
    elseif ($badSec)                   { $verdict = 'BADSEC' }
    elseif ($hasProb)                  { $verdict = 'PROBLEM' }
    elseif ($clean)                    { $verdict = 'CLEAN' }
    elseif ($inUse)                    { $verdict = 'INUSE' }
    elseif ($raw -match '(?im)^\s*(error|错误|cannot|无法)') { $verdict = 'ERROR' }

    # 结论摘要也按语言取
    $key = @()
    $bl = ($raw -split "`n" | Where-Object { $_.Trim() } )
    $b1 = $bl | Where-Object { $_ -match $P.En.BadSect -or $_ -match $P.Zh.BadSect } | Select-Object -First 1
    if ($b1) { $key += ($b1.Trim() -replace '\s+',' ') }
    $b2 = $bl | Where-Object { $_ -match $P.En.Duration -or $_ -match $P.Zh.Duration } | Select-Object -First 1
    if ($b2) { $key += $b2.Trim() }
    $b3 = $bl | Where-Object { $_ -match $P.En.Clean -or $_ -match $P.Zh.Clean -or $_ -match $P.En.Fixed -or $_ -match $P.Zh.Fixed -or $_ -match $P.En.Problem -or $_ -match $P.Zh.Problem } | Select-Object -First 1
    if ($b3) { $key += $b3.Trim() }

    return [PSCustomObject]@{
        Verdict=$verdict; Clean=$clean; WasFixed=$wasFixed
        HasProblem=$hasProb; BadSector=$badSec; InUse=$inUse
        Summary = ,$key
    }
}

function Get-ScanTargets {
    # 自动发现所有本地固定磁盘, 判断哪些需要扫描。
    # 规则: 有 NTFS 损坏记录的必扫; 其余盘交给用户勾选。
    $targets = [System.Collections.ArrayList]::new()
    $de = Get-DiskErrors

    # 优先用 Get-Volume(Win8+); 缺失时回退到 WMI Win32_LogicalDisk(Win7 可用)
    $vols = @()
    if ($null -ne (Get-Command Get-Volume -ErrorAction SilentlyContinue)) {
        $vols = @(Get-Volume -ErrorAction SilentlyContinue |
                  Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.Size -gt 0 } |
                  ForEach-Object {
                      [PSCustomObject]@{
                          DriveLetter=$_.DriveLetter; FileSystemLabel=$_.FileSystemLabel
                          FileSystem=$_.FileSystem; Size=[double]$_.Size
                          SizeRemaining=[double]$_.SizeRemaining
                      }
                  })
    } else {
        # Win7 回退路径: Win32_LogicalDisk 是 WinNT 时代就有的, 全版本可用
        $vols = @(Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue |
                  Where-Object { $_.DriveType -eq 3 -and $_.Size -gt 0 } |
                  ForEach-Object {
                      [PSCustomObject]@{
                          DriveLetter=[string]$_.DeviceID; FileSystemLabel=$_.VolumeName
                          FileSystem=$_.FileSystem; Size=[double]$_.Size
                          SizeRemaining=[double]$_.FreeSpace
                      }
                  })
    }

    foreach ($v in $vols) {
        $d = [string]$v.DriveLetter
        $errCount = 0
        if ($de.ByDrive -and $de.ByDrive.ContainsKey($d)) { $errCount = $de.ByDrive[$d] }

        [void]$targets.Add([PSCustomObject]@{
            Drive      = $d
            Label      = $v.FileSystemLabel
            FS         = $v.FileSystem
            SizeGB     = [math]::Round($v.Size/1GB,1)
            FreeGB     = [math]::Round($v.SizeRemaining/1GB,1)
            FreePct    = [math]::Round($v.SizeRemaining/$v.Size*100)
            ErrCount   = $errCount
            MustScan   = ($errCount -gt 0)
            Skipped    = ($v.FileSystem -eq 'FAT32' -and $errCount -eq 0)
        })
    }
    return ,$targets
}

function Show-TargetTable($targets) {
    if (-not $targets -or $targets.Count -eq 0) {
        Warn '未找到可扫描的本地磁盘'
        return
    }
    Write-Host ''
    Write-Host '     盘符  文件系统   容量      剩余      占用   损坏记录' -ForegroundColor White
    Write-Host '     ' + ('-' * 58) -ForegroundColor DarkGray
    $k = 0
    foreach ($t in $targets) {
        $k++
        if ($t.Skipped) {
            Write-Host ("     {0}. {1}:   {2,-8} {3,6} GB  {4,6} GB  {5,5}%  {6}" -f `
                $k, $t.Drive, $t.FS, $t.SizeGB, $t.FreeGB, $t.FreePct, '(跳过: FAT32)') -ForegroundColor DarkGray
        } else {
            $ec = if ($t.ErrCount -gt 0) { "$($t.ErrCount) 次" } else { '无' }
            $col = if ($t.ErrCount -gt 0) { 'Red' } else { 'Gray' }
            Write-Host ("     {0}. {1}:   {2,-8} {3,6} GB  {4,6} GB  {5,5}%  {6}" -f `
                $k, $t.Drive, $t.FS, $t.SizeGB, $t.FreeGB, $t.FreePct, $ec) -ForegroundColor $col
        }
    }
}

function Repair-DiskScan {
    Section '修复: 磁盘文件系统检查'

    $targets = Get-ScanTargets
    if (-not $targets -or $targets.Count -eq 0) {
        Warn '未找到可扫描的本地固定磁盘'
        return
    }

    Info '自动扫描出以下本地磁盘:'
    Show-TargetTable $targets

    $must = @($targets | Where-Object { $_.MustScan })
    $opt  = @($targets | Where-Object { -not $_.MustScan -and -not $_.Skipped })

    Clear-Line
    if ($must.Count -gt 0) {
        Bad "检测到 $($must.Count) 个盘有文件系统损坏记录, 必须扫描: $($must.Drive -join ', ')"
    } else {
        Ok '所有磁盘均无损坏记录'
    }

    $selected = @()
    foreach ($t in $must) {
        Write-Host ''
        Write-Host "     $($t.Drive): $(if($t.MustScan){'已损坏, 建议立即修复'})" -ForegroundColor $(if($t.MustScan){'Red'}else{'Gray'})
        if (Ask "扫描盘 ${($t.Drive)}: ?" 'Y') { $selected += $t.Drive }
    }
    if ($opt.Count -gt 0) {
        Clear-Line
        Info "另外还有 $($opt.Count) 个未记录损坏的盘, 可选扫描 (选1=只扫损坏的盘, 选2=全部扫描):"
        foreach ($t in $opt) {
            Write-Host ''
            $est = [math]::Max(1, [math]::Round($t.SizeGB / 100))
            Write-Host "     盘 ${($t.Drive)}: ($($t.SizeGB) GB, 预计 $est-$(($est*4)) 分钟)" -ForegroundColor Gray
            if (Ask "也扫描盘 ${($t.Drive)}: ?" 'N') { $selected += $t.Drive }
        }
    }

    $selected = @($selected | Select-Object -Unique)
    if ($selected.Count -eq 0) {
        Clear-Line
        Info '未选择任何盘, 跳过磁盘扫描'
        return
    }

    Clear-Line
    Warn "即将扫描: $($selected -join ', ')  共 $($selected.Count) 个盘"
    Info '机械盘每个 5-20 分钟, 中途请勿关机'
    if (-not (Ask '现在开始?' 'Y')) { Info '已取消'; return }

    $results = @()
    foreach ($d in $selected) {
        Clear-Line
        Warn "开始在线扫描盘 ${d}:"
        $r = Invoke-Chkdsk -DriveLetter $d
        foreach ($s in $r.Summary) { Write-Host "       $s" -ForegroundColor DarkGray }
        Clear-Line

        switch ($r.Verdict) {
            'CLEAN'  { Ok "盘 ${d}: 扫描通过, 文件系统健康"; $results += [PSCustomObject]@{D=$d;V='CLEAN'} }
            'FIXED'  { Warn "盘 ${d}: 发现问题并已修复, 建议重启后再扫描确认"; $results += [PSCustomObject]@{D=$d;V='FIXED'} }
            'BADSEC' {
                Bad "盘 ${d}: 发现坏扇区!"
                Info '坏扇区无法用 chkdsk 修复, 说明磁盘已有物理损坏'
                Info '请立即备份重要数据, 并尽快更换硬盘'
                $results += [PSCustomObject]@{D=$d;V='BADSEC'}
            }
            'PROBLEM' {
                Warn "盘 ${d}: 存在逻辑错误, 执行强制修复"
                $f = Invoke-Chkdsk -DriveLetter $d -SpotFix
                foreach ($s in $f.Summary) { Write-Host "       $s" -ForegroundColor DarkGray }
                Clear-Line
                switch ($f.Verdict) {
                    'FIXED'  { Warn "盘 ${d}: 已修复, 若仍报错请重启后再运行"; $results += [PSCustomObject]@{D=$d;V='FIXED'} }
                    'CLEAN'  { Ok "盘 ${d}: 修复完成, 文件系统已健康"; $results += [PSCustomObject]@{D=$d;V='CLEAN'} }
                    'INUSE'  { Warn "盘 ${d}: 卷被占用, 修复将在下次重启时执行"; $results += [PSCustomObject]@{D=$d;V='INUSE'} }
                    default  { Bad "盘 ${d}: 修复未成功"; $results += [PSCustomObject]@{D=$d;V=$f.Verdict} }
                }
            }
            'INUSE'  { Warn "盘 ${d}: 卷被占用, 修复将在下次重启时自动执行"; $results += [PSCustomObject]@{D=$d;V='INUSE'} }
            'DENIED' { Bad "盘 ${d}: 权限不足, 请以管理员身份运行"; $results += [PSCustomObject]@{D=$d;V='DENIED'} }
            default  { Bad "盘 ${d}: 扫描异常 (状态 $($r.Verdict))"; $results += [PSCustomObject]@{D=$d;V='ERR'} }
        }
    }

    Clear-Line
    Section '磁盘扫描汇总'
    foreach ($x in $results) {
        $msg = switch ($x.V) {
            'CLEAN'  { '健康'; }
            'FIXED'  { '已修复'; }
            'BADSEC' { '存在坏扇区, 建议更换硬盘'; }
            'INUSE'  { '已排队, 重启时修复'; }
            'DENIED' { '权限不足'; }
            default  { $x.V }
        }
        $col = switch ($x.V) {
            'CLEAN' { 'Green' } 'FIXED' { 'Yellow' } 'BADSEC' { 'Red' } default { 'Yellow' }
        }
        Write-Host ("     盘 {0}:  {1}" -f $x.D, $msg) -ForegroundColor $col
    }
    Clear-Line
    Info '建议重启一次, 再运行本工具确认磁盘已完全健康'
}
function Repair-StartupItems($items) {
    Section '修复: 精简开机自启'
    Info "共 $($items.Count) 项, 逐项询问"
    Info '输入 Y 禁用 / N 保留 / 直接回车用推荐值'
    $changed = 0

    $skipPaths = 'C:\\Windows\\|C:\\Program Files\\WindowsApps|svchost|Microsoft'
    $cand = $items | Where-Object {
        $_.Kind -in 'RunKey','Folder' -or ($_.Kind -eq 'Service')
    }

    foreach ($i in $cand) {
        if ($i.Cmd -match $skipPaths) {
            Info ("跳过系统项: {0}" -f $i.Name)
            continue
        }
        Clear-Line
        Write-Host "  -> $($i.Name)" -ForegroundColor White
        Info "     来源: $($i.Source)"
        $short = $i.Cmd
        if ($short -and $short.Length -gt 60) { $short = $short.Substring(0,57) + '...' }
        Write-Host "     路径: $short" -ForegroundColor DarkGray

        $def = 'Y'
        if ($i.Name -match '(?i)sunlogin|awesun|向日葵') { $def = 'N'; Write-Host '     (远程控制类, 不建议禁用)' -ForegroundColor DarkYellow }
        if (-not (Ask "禁用此开机自启?" $def)) { Info '     已保留'; continue }

        try {
            if ($i.Kind -eq 'Service') {
                Backup-Service $i.Path
                Stop-Service -Name $i.Path -Force -ErrorAction SilentlyContinue
                Set-Service -Name $i.Path -StartupType Disabled -ErrorAction Stop
                Ok "已禁用服务: $($i.Name)"
            } else {
                if ($i.Kind -eq 'Folder') {
                    $dest = Join-Path $THIS_BAK ("启动文件夹_" + $i.Name)
                    Copy-Item $i.Path $dest -Force -ErrorAction Stop
                    Move-Item $i.Path ($i.Path + '.disabled') -Force -ErrorAction Stop
                    Backup-Record 'StartupFile' $i.Path $dest
                } else {
                    Backup-RunKey $i.Path $i.Name
                    Remove-ItemProperty -Path $i.Path -Name $i.Name -ErrorAction Stop
                }
                Ok "已禁用自启: $($i.Name)"
            }
            $changed++
        } catch { Bad "禁用失败: $($_.Exception.Message)" }
    }
    Clear-Line
    if ($changed -gt 0) { Ok "共禁用 $changed 项, 备份在 $THIS_BAK" }
    else { Info '未禁用任何项目' }
}

function Repair-TempClean {
    Section '修复: 清理垃圾文件'
    $ts = Get-TempStats
    $tot = $ts.UserGB + $ts.WinGB + $ts.RecycleGB + $ts.WerGB
    if ($tot -lt 0.5) { Ok '垃圾文件很少, 无需清理'; return }
    Warn "可清理约 $([math]::Round($tot,2)) GB"
    if (-not (Ask '继续清理?' 'N')) { Info '已跳过'; return }

    $targets = @(
        @{ N='用户临时文件'; P=$env:TEMP },
        @{ N='系统临时文件'; P="$env:SystemRoot\Temp" },
        @{ N='错误报告';     P="$env:ProgramData\Microsoft\Windows\WER" }
    )
    foreach ($t in $targets) {
        if (-not (Test-Path $t.P)) { continue }
        $n = 0
        Get-ChildItem $t.P -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            try { Remove-Item $_.FullName -Force -ErrorAction Stop; $n++ } catch {}
        }
        Ok ("{0}: 已删除 {1} 个文件" -f $t.N, $n)
    }
    if ($ts.RecycleGB -gt 0.1 -and (Ask '清空回收站?' 'N')) {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Ok '回收站已清空'
    }
}

function Repair-DiagLog {
    Section '修复: 启用开机性能日志'
    try {
        $ln = 'Microsoft-Windows-Diagnostics-Performance/Operational'
        wevtutil sl $ln /e:true 2>&1 | Out-Null
        $st = (Get-WinEvent -ListLog $ln -ErrorAction Stop).IsEnabled
        if ($st) { Ok '已启用 —— 重启后本工具能显示精确的开机耗时分解' }
        else { Bad '启用失败' }
    } catch { Bad "启用失败: $($_.Exception.Message)" }
}

function Repair-DefenderExcl {
    Section '可选: 优化 Windows Defender'
    Info '实时扫描会拖慢开机, 把大目录加入排除项可减少干扰'
    Info '注意: 排除后该目录将不再被杀毒扫描'

    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        if (-not $mp.AMRunning) {
            Warn 'Defender 未运行 (你可能在用 360 等第三方杀软接管)'
            Info '第三方杀软通常有自己的排除项设置, 本项可跳过'
            return
        }
    } catch {
        Warn '无法读取 Defender 状态, 跳过本项'
        return
    }

    # 让用户自己指定要排除的目录, 不写死任何盘符
    $vols = @(Get-Volume -ErrorAction SilentlyContinue |
              Where-Object { $_.DriveLetter -and $_.Size -gt 50GB })
    if ($vols.Count -eq 0) { Info '没有超过 50GB 的分区, 无需优化'; return }

    Clear-Line
    Info '可选的大容量分区:'
    $k = 0
    foreach ($v in $vols) {
        $k++
        Write-Host ("     {0}. {1}:  ({2} GB)" -f $k, $v.DriveLetter, [math]::Round($v.Size/1GB,0)) -ForegroundColor Gray
    }
    Clear-Line
    $sel = Read-Host '  输入要排除的分区序号 (多个用逗号, 直接回车跳过)'
    if ([string]::IsNullOrWhiteSpace($sel)) { Info '已跳过'; return }

    $picks = @()
    foreach ($s in ($sel -split ',')) {
        $n = 0
        if ([int]::TryParse($s.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $vols.Count) {
            $picks += $vols[$n-1].DriveLetter + '\'
        }
    }
    if ($picks.Count -eq 0) { Warn '输入无效, 已跳过'; return }

    foreach ($p in $picks) {
        try {
            $md = Get-MpPreference -ErrorAction Stop
            if ($md.ExclusionPath -contains $p) { Ok "$p 已在排除列表"; continue }
            Add-MpPreference -ExclusionPath $p -ErrorAction Stop
            Ok "已添加排除项: $p"
        } catch { Bad "添加 $p 失败: $($_.Exception.Message)" }
    }
    Info '若要撤销: Set-MpPreference -RemoveExclusionPath "盘符:\"'
}

function Get-RepairPlan($scanResult) {
    # 根据检测结果生成修复任务清单。
    # 每项: Id/标题/说明/风险等级(安全|注意|需确认)/默认是否执行/执行体
    $plan = [System.Collections.ArrayList]::new()
    $sys  = $scanResult.Sys
    $de   = Get-DiskErrors
    $ts   = Get-TempStats
    $dt   = $scanResult.Disk

    # --- 1. 快速启动 ---
    if ($sys.FastBoot -ne 1 -or $sys.Hiber -ne 1) {
        [void]$plan.Add([PSCustomObject]@{
            Id='fastboot'; Title='开启快速启动'
            Desc='开机时只加载系统内核部分, 可节省 20-40 秒'
            Risk='安全'; Default=$true
            NeedsRestart=$true
            Run = { Repair-FastStartup }
        })
    }

    # --- 2. 性能日志 ---
    if (-not (Get-BootTiming).LogEnabled) {
        [void]$plan.Add([PSCustomObject]@{
            Id='diaglog'; Title='启用开机性能日志'
            Desc='启用后重启一次, 即可看到精确的开机耗时分解'
            Risk='安全'; Default=$true; NeedsRestart=$true
            Run = { Repair-DiagLog }
        })
    }

    # --- 3. 磁盘扫描 ---
    $badDrives = @()
    if ($de.ByDrive -and $de.ByDrive.Count -gt 0) {
        $badDrives = @($de.ByDrive.GetEnumerator() | Where-Object { $_.Value -gt 0 })
    }
    if ($badDrives.Count -gt 0) {
        $names = ($badDrives | ForEach-Object { "$($_.Key):($($_.Value)次)" }) -join ' '
        [void]$plan.Add([PSCustomObject]@{
            Id='disk'; Title='修复文件系统损坏'
            Desc="检测到损坏的盘: $names  (机械盘 5-20 分钟)"
            Risk='需确认'; Default=$true; NeedsRestart=$true; Slow=$true
            Run = { Repair-DiskScan }
        })
    }

    # --- 4. 垃圾清理 ---
    $totGB = $ts.UserGB + $ts.WinGB + $ts.RecycleGB + $ts.WerGB
    if ($totGB -gt 0.5) {
        [void]$plan.Add([PSCustomObject]@{
            Id='temp'; Title='清理垃圾文件'
            Desc=("可清理约 {0:N2} GB (临时文件/回收站/错误报告)" -f $totGB)
            Risk='注意'; Default=$false
            Run = { Repair-TempClean }
        })
    }

    # --- 5. 开机自启 ---
    $candCount = @($scanResult.Items | Where-Object {
        $_.Cmd -notmatch 'C:\\Windows\\|C:\\Program Files\\WindowsApps|svchost|Microsoft'
    }).Count
    if ($candCount -gt 0) {
        [void]$plan.Add([PSCustomObject]@{
            Id='startup'; Title='精简开机自启项'
            Desc="发现 $candCount 个可精简的启动项"
            Risk='注意'; Default=$true
            Run = { Repair-StartupItems $scanResult.Items }
        })
    }

    # --- 6. Defender (可选优化, 永不在一键修复中自动执行) ---
    [void]$plan.Add([PSCustomObject]@{
        Id='defender'; Title='优化 Defender 扫描 (可选)'
        Desc='把大目录加入排除项以减少开机时的实时扫描干扰'
        Risk='注意'; Default=$false; AlwaysAsk=$true
        Run = { Repair-DefenderExcl }
    })

    return ,$plan
}

function Show-PlanTable($plan) {
    Section '发现以下可修复项'
    if (-not $plan -or $plan.Count -eq 0) {
        Ok '未发现需要修复的问题'
        return $false
    }
    Write-Host ''
    $riskCol = @{ '安全'='Green'; '注意'='Yellow'; '需确认'='Red' }
    for ($i = 0; $i -lt $plan.Count; $i++) {
        $t = $plan[$i]
        Write-Host ("     {0}. {1}" -f ($i+1), $t.Title) -ForegroundColor White
        Write-Host ("        {0}" -f $t.Desc) -ForegroundColor DarkGray
        Write-Host ("        风险: {0}   默认: {1}" -f $t.Risk, $(if($t.Default){'执行'}else{'跳过'})) `
            -ForegroundColor $riskCol[$t.Risk]
    }
    Write-Host ''
    return $true
}

function Select-PlanItems($plan) {
    # 返回用户勾选的修复项集合
    Clear-Line
    Section '选择修复方式'
    Info '[1] 一键修复   —— 执行全部推荐项 (跳过可选优化)'
    Info '[2] 逐项选择   —— 自己勾选每一项'
    Info '[0] 取消       —— 不做任何修改'
    Write-Host ''
    $c = Read-Host '  请选择'

    switch ($c.Trim()) {
        '1' {
            $sel = @($plan | Where-Object { $_.Default })
            Clear-Line
            Ok "已选择一键修复, 将执行 $($sel.Count) 项:"
            foreach ($t in $sel) { Write-Host "       - $($t.Title)" -ForegroundColor Gray }
            if (-not (Ask "`n确认执行?" 'Y')) { return $null }
            return ,$sel
        }
        '2' {
            $sel = @()
            Clear-Line
            Section '逐项选择'
            Info '输入数字可多选 (如: 1 3 4), 直接回车使用推荐值, 输入 0 结束'
            Write-Host ''
            for ($i = 0; $i -lt $plan.Count; $i++) {
                $t = $plan[$i]
                $mark = if ($t.Default) { '*' } else { ' ' }
                Write-Host ("     {0}. [{1}] {2}   ({3})" -f ($i+1), $mark, $t.Title, $t.Risk) -ForegroundColor White
            }
            Write-Host ''
            Info '带 * 的为推荐项'
            Write-Host ''
            $inp = Read-Host '  选择要修复的项目'
            if ([string]::IsNullOrWhiteSpace($inp)) {
                $sel = @($plan | Where-Object { $_.Default })
                Info "使用推荐值: $($sel.Count) 项"
                return ,$sel
            }
            if ($inp.Trim() -eq '0') { return @() }
            foreach ($s in ($inp -split '[,\s]+')) {
                $n = 0
                if ([int]::TryParse($s.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $plan.Count) {
                    $sel += $plan[$n-1]
                }
            }
            # 去重
            $seen = @{}; $uniq = @()
            foreach ($t in $sel) { if (-not $seen.ContainsKey($t.Id)) { $seen[$t.Id] = 1; $uniq += $t } }
            Clear-Line
            Ok "已选择 $($uniq.Count) 项:"
            foreach ($t in $uniq) { Write-Host "       - $($t.Title)" -ForegroundColor Gray }
            Write-Host ''
            return ,$uniq
        }
        '0' { return $null }
        default { Warn '无效选项'; Start-Sleep -Seconds 1; return Select-PlanItems $plan }
    }
}

function Invoke-Task($t, [ref]$log) {
    # 执行单个修复任务, 捕获异常, 保证一个失败不影响其他
    Clear-Line
    Write-Host ('=' * 64) -ForegroundColor DarkCyan
    Write-Host "  正在执行: $($t.Title)" -ForegroundColor White
    Write-Host ('=' * 64) -ForegroundColor DarkCyan
    try {
        & $t.Run
        $log.Value += "OK   $($t.Id) : $($t.Title)"
        Clear-Line
        Ok "完成: $($t.Title)"
    } catch {
        $log.Value += "FAIL $($t.Id) : $($t.Title) -> $($_.Exception.Message)"
        Clear-Line
        Bad "$($t.Title) 失败: $($_.Exception.Message)"
    }
}

function Invoke-Fix {
    Banner
    Section '全面检测'
    Info '正在分析系统状态, 请稍候...'
    $r = Invoke-Scan -Quiet

    $plan = Get-RepairPlan $r
    if (-not (Show-PlanTable $plan)) {
        Clear-Line
        Info '无需修复, 可选择 [3] 磁盘基准测试 了解硬件性能'
        return
    }

    $sel = Select-PlanItems $plan
    if ($null -eq $sel) {
        Clear-Line
        Info '已取消, 未做任何修改'
        return
    }
    if ($sel.Count -eq 0) {
        Clear-Line
        Info '未选择任何项目, 未做任何修改'
        return
    }

    # 建备份目录并写入初始清单
    New-Item -ItemType Directory -Path $THIS_BAK -Force | Out-Null
    Clear-Line
    Section "开始修复 (共 $($sel.Count) 项)"
    Info "备份目录: $THIS_BAK"
    Info '所有改动均可通过菜单 [4] 回滚'
    if (@($sel | Where-Object { $_.Slow }).Count -gt 0) {
        Warn '包含磁盘扫描, 机械盘可能耗时 5-20 分钟, 请勿关机'
    }

    $log = @()
    $okN = 0; $failN = 0
    foreach ($t in $sel) {
        Invoke-Task $t ([ref]$log)
        if ($log[-1] -like "OK*") { $okN++ } else { $failN++ }
        Start-Sleep -Milliseconds 300
    }

    Backup-Save
    $log | Set-Content -Path (Join-Path $THIS_BAK '执行记录.txt') -Encoding UTF8

    Section '修复完成'
    Write-Host "     成功 $okN 项" -ForegroundColor Green
    if ($failN -gt 0) { Write-Host "     失败 $failN 项" -ForegroundColor Red }
    Clear-Line
    Ok '备份位置:'
    Info $THIS_BAK
    Clear-Line
    $needRestart = @($sel | Where-Object { $_.NeedsRestart })
    if ($needRestart.Count -gt 0) {
        Info '以下改动需要重启才完全生效:'
        foreach ($t in $needRestart) { Write-Host "     - $($t.Title)" -ForegroundColor Gray }
    }
    Clear-Line
    Info '建议现在重启一次, 然后运行 [1] 全面检测 验证效果'
    Clear-Line
}

# =================================================================
#  回滚
# =================================================================
function Invoke-Rollback {
    Banner
    Section '回滚设置'
    $baks = Get-ChildItem $BAK_DIR -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending
    if (-not $baks) { Bad '没有找到任何备份'; return }
    $k = 0
    foreach ($b in $baks) {
        $k++
        $mf = Join-Path $b.FullName 'rollback.json'
        $cnt = 0
        if (Test-Path $mf) { $cnt = @((Get-Content $mf -Raw | ConvertFrom-Json)).Count }
        Write-Host ("     {0}. {1}   ({2} 项改动)" -f $k, $b.Name, $cnt) -ForegroundColor Gray
    }
    Clear-Line
    $sel = Read-Host '  输入要回滚的序号 (直接回车=最近一次)'
    if ([string]::IsNullOrWhiteSpace($sel)) { $sel = '1' }
    $idx = [int]$sel - 1
    if ($idx -lt 0 -or $idx -ge $baks.Count) { Bad '序号无效'; return }
    $dir = $baks[$idx].FullName
    $mf  = Join-Path $dir 'rollback.json'
    if (-not (Test-Path $mf)) { Bad '该备份没有回滚清单'; return }
    if (-not (Ask "确定回滚 $($baks[$idx].Name) ?")) { Info '已取消'; return }

    $data = @(Get-Content $mf -Raw | ConvertFrom-Json)
    $okN = 0; $failN = 0
    foreach ($d in $data) {
        try {
            switch ($d.type) {
                'RunKey' {
                    $p = $d.key -replace '::[^:]*$',''
                    $n = ($d.key -split '::')[-1]
                    New-ItemProperty -Path $p -Name $n -Value $d.value -PropertyType String -Force -ErrorAction Stop | Out-Null
                }
                'Service' {
                    Set-Service -Name $d.key -StartupType $d.value -ErrorAction Stop
                }
                'RegValue' {
                    $p = $d.key -replace '::[^:]*$',''
                    $n = ($d.key -split '::')[-1]
                    New-ItemProperty -Path $p -Name $n -Value $d.value -PropertyType DWord -Force -ErrorAction Stop | Out-Null
                }
                'StartupFile' {
                    if (Test-Path ($d.key + '.disabled')) { Move-Item ($d.key + '.disabled') $d.key -Force -ErrorAction Stop }
                }
            }
            $okN++
        } catch { $failN++; Write-Host "     失败: $($d.key)  $($_.Exception.Message)" -ForegroundColor Red }
    }
    Clear-Line
    Ok "已还原 $okN 项"
    if ($failN) { Bad "$failN 项还原失败" }
}

# =================================================================
#  基准测试
# =================================================================
function Invoke-Bench {
    Banner
    Section '磁盘性能基准测试'
    $sp = Test-DiskSpeed
    Info ("冷读取速度 : {0} MB/s   (随机多文件实测, 比顺序读更准)" -f $sp.ColdMBps)
    Info ("小文件枚举: {0} 毫秒" -f $sp.FileCountMs)
    $disk = Get-DiskProfile
    Info "存储类型 : $(if($disk.IsSsd){'SSD 固态'}else{'HDD 机械'})"
    Clear-Line
    Write-Host '  参考值:' -ForegroundColor White
    Write-Host '    机械硬盘 5400转 : 40-90 MB/s,  枚举>3000ms' -ForegroundColor Gray
    Write-Host '    机械硬盘 7200转 : 80-150 MB/s, 枚举 1000-3000ms' -ForegroundColor Gray
    Write-Host '    SATA SSD        : 400-550 MB/s, 枚举 <100ms' -ForegroundColor Gray
    Write-Host '    NVMe SSD        : 1500-3500 MB/s, 枚举 <50ms' -ForegroundColor Gray
    $hist = Join-Path $DATA_DIR 'bench.csv'
    $line = "{0},{1},{2},{3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $sp.ColdMBps, $sp.FileCountMs, ($(if($disk.IsSsd){'SSD'}else{'HDD'}))
    Add-Content -Path $hist -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    Clear-Line
    Info "历史记录已追加到 $hist"
}

# =================================================================
#  主菜单
# =================================================================
function Get-DirSize {
    param([string]$Path, [int]$MaxAgeDays = 0)
    if (-not (Test-Path $Path)) { return 0 }
    try {
        $items = Get-ChildItem $Path -Recurse -File -Force -ErrorAction SilentlyContinue
        if ($MaxAgeDays -gt 0) {
            $cut = (Get-Date).AddDays(-$MaxAgeDays)
            $items = $items | Where-Object { $_.LastWriteTime -lt $cut }
        }
        return [math]::Round((($items | Measure-Object Length -Sum).Sum)/1MB, 1)
    } catch { return 0 }
}

function Get-OrphanStartup {
    # 开机启动项指向的文件已不存在 -> 这类项会在每次开机时报错并拖慢启动
    $bad = [System.Collections.ArrayList]::new()
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    )
    foreach ($p in $paths) {
        $o = Get-ItemProperty $p -ErrorAction SilentlyContinue
        if (-not $o) { continue }
        foreach ($x in ($o.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })) {
            $exe = [regex]::Match("$($x.Value)", '^"?([^"]+?\.exe)').Groups[1].Value
            if ($exe -and -not (Test-Path $exe)) {
                [void]$bad.Add([PSCustomObject]@{
                    RegPath = $p; Name = $x.Name; Value = $x.Value; MissingPath = $exe
                })
            }
        }
    }
    return ,$bad
}
function Get-OrphanUninstall {
    # 判定卸载残留必须同时满足两个条件:
    #   1) InstallLocation 指向的目录不存在
    #   2) UninstallString 指向的卸载程序也不存在
    # 只判断 (1) 会把"仍安装着、只是注册表记录了旧路径"的软件误判为残留,
    # 那样会删掉正常软件的卸载入口, 导致用户无法卸载它。
    $orph = [System.Collections.ArrayList]::new()

    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($reg in (Get-ItemProperty $keys -ErrorAction SilentlyContinue)) {
        if (-not $reg.DisplayName) { continue }

        $loc = ''
        if ($reg.InstallLocation) { $loc = ([string]$reg.InstallLocation).Trim('"').Trim() }
        $locGone = $false
        if ($loc) { $locGone = -not (Test-Path $loc) }

        $uninst = ''
        if ($reg.UninstallString) {
            $m = [regex]::Match([string]$reg.UninstallString, '^"?([^"]+?\.exe)')
            if ($m.Success) { $uninst = $m.Groups[1].Value }
        }
        $uninstGone = $false
        if ($uninst) { $uninstGone = -not (Test-Path $uninst) }

        if ($locGone -and ($uninstGone -or (-not $uninst))) {
            $shown = $loc
            if (-not $shown) { $shown = $uninst }
            [void]$orph.Add([PSCustomObject]@{
                RegPath     = $reg.PSPath
                Name        = $reg.DisplayName
                MissingPath = $shown
            })
        }
    }
    return ,$orph
}
function Get-JunkPlan {
    Section '垃圾清理检测'

    $plan = [System.Collections.ArrayList]::new()

    # ---------- A. 磁盘垃圾 (安全) ----------
# ---------- A. 磁盘垃圾 (安全) ----------
    # 浏览器缓存: 不同浏览器/版本路径不同, 逐个探测
    $browserRoots = @(
        @{ Name='Edge 缓存';    Paths=@("$env:LOCALAPPDATA\Microsoft\Edge\User Data") },
        @{ Name='Chrome 缓存';  Paths=@("$env:LOCALAPPDATA\Google\Chrome\User Data") },
        @{ Name='360浏览器缓存'; Paths=@("$env:APPDATA\360se6\Cache_Data",
                                         "$env:APPDATA\360se6\Cache",
                                         "$env:LOCALAPPDATA\360Chrome\Chrome\User Data") },
        @{ Name='QQ浏览器缓存'; Paths=@("$env:LOCALAPPDATA\Tencent\QQBrowser\User Data") },
        @{ Name='Firefox 缓存'; Paths=@("$env:LOCALAPPDATA\Mozilla\Firefox\Profiles") }
    )
    $cacheHits = @()
    foreach ($b in $browserRoots) {
        foreach ($bp in $b.Paths) {
            if (-not (Test-Path $bp)) { continue }
            # 只取 Profile 下的 Cache / Code Cache / GPUCache 子目录
            $subs = @()
            $subs += @(Get-ChildItem $bp -Directory -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -match '^(Default|Profile \d+)$' } |
                       ForEach-Object {
                           foreach ($n in 'Cache','Cache_Data','Code Cache','GPUCache','DawnCache') {
                               $q = Join-Path $_.FullName $n
                               if (Test-Path $q) { $q }
                           }
                       })
            if (-not $subs) { $subs = @($bp) }
            $tot = 0
            foreach ($s in $subs) { $tot += (Get-DirSize -Path $s) }
            if ($tot -gt 1) {
                $cacheHits += [PSCustomObject]@{ Name=$b.Name; Size=$tot; Paths=$subs }
            }
        }
    }

    $diskTargets = @(
        @{ Id='recycle';  Name='回收站'; Path="$env:SystemDrive\`$Recycle.Bin"; Risk='注意'; Days=0
           Tip='清空后无法恢复删除的文件' }
        @{ Id='usertemp'; Name='用户临时文件'; Path=$env:TEMP; Risk='安全'; Days=3
           Tip='只清理 3 天前的文件, 避免影响正在运行的程序' }
        @{ Id='systemp';  Name='系统临时文件'; Path="$env:SystemRoot\Temp"; Risk='安全'; Days=7
           Tip='只清理 7 天前的文件' }
        @{ Id='wer';      Name='Windows 错误报告'; Path="$env:ProgramData\Microsoft\Windows\WER"; Risk='安全'; Days=0
           Tip='崩溃记录, 对普通用户无用' }
        @{ Id='cbs';      Name='系统维护日志 (CBS)'; Path="$env:SystemRoot\Logs\CBS"; Risk='安全'; Days=7
           Tip='系统安装/更新日志, 排障时才会用到' }
        @{ Id='thumb';    Name='缩略图缓存'; Path="$env:LocalAppData\Microsoft\Windows\Explorer"; Risk='安全'; Days=30
           Tip='会自动重建, 清理后首次浏览文件夹略慢' }
        @{ Id='wupdate';  Name='Windows 更新缓存'; Path="$env:SystemRoot\SoftwareDistribution\Download"; Risk='注意'; Days=30
           Tip='正在更新时不要清理' }
        @{ Id='dstore';   Name='IE/旧浏览器缓存'; Path="$env:LOCALAPPDATA\Microsoft\Windows\INetCache"; Risk='安全'; Days=7
           Tip='' }
        @{ Id='d3d';      Name='DirectX 着色器缓存'; Path="$env:LOCALAPPDATA\D3DSCache"; Risk='安全'; Days=0
           Tip='游戏首次启动会重新编译, 略慢一次' }
        @{ Id='crash';    Name='程序崩溃转储'; Path="$env:LOCALAPPDATA\CrashDumps"; Risk='安全'; Days=0
           Tip='排查程序崩溃时有用, 平时无用' }
        @{ Id='oldwin';   Name='旧版 Windows (Windows.old)'; Path="C:\Windows.old"; Risk='注意'; Days=0
           Tip='可释放大量空间, 但会失去"回退到上一版本"的能力' }
        @{ Id='setup';    Name='系统升级残留日志'; Path="$env:SystemRoot\Logs\MoSetup"; Risk='安全'; Days=0
           Tip='升级完成后已无用' }
        @{ Id='matrix';   Name='升级文件回滚记录'; Path="$env:SystemRoot\Temp\PcbTemp"; Risk='安全'; Days=0
           Tip='' }
    )
    foreach ($t in $diskTargets) {
        if (-not (Test-Path $t.Path)) { continue }
        $sz = Get-DirSize -Path $t.Path -MaxAgeDays $t.Days
        if ($sz -le 0.5) { continue }
        [void]$plan.Add([PSCustomObject]@{
            Cat='disk'; Id=$t.Id; Title=("{0} ({1} MB)" -f $t.Name, $sz)
            Risk=$t.Risk; Tip=$t.Tip; SizeMB=$sz; Path=$t.Path; Days=$t.Days
            Default = ($t.Id -notin 'recycle','wupdate','oldwin')
        })
    }

    # 浏览器缓存逐项加入
    foreach ($c in $cacheHits) {
        [void]$plan.Add([PSCustomObject]@{
            Cat='disk'; Id=('browser_' + ($c.Name -replace '\s',''))
            Title=("{0} ({1} MB)" -f $c.Name, [math]::Round($c.Size,0))
            Risk='安全'; Tip='清理后网页首次打开会略慢'
            SizeMB=[math]::Round($c.Size,0); Path=$null; Days=0
            MultiPaths=$c.Paths; Default=$true
        })
    }

    # ---------- A2. 调用系统自带清理工具 ----------
    # cleanmgr / Disk Cleanup 能安全回收旧版安装副本, 临时安装文件等
    # 这是微软官方工具, 比手工删安全得多
    $sysCleanMB = 0
    try {
        $before = (Get-Volume -DriveLetter ([char]73) -ErrorAction SilentlyContinue).SizeRemaining
    } catch { $before = 0 }
    if ($before -gt 0) {
        try {
            $dismOut = & dism.exe /Online /Cleanup-Image /AnalyzeComponentStore 2>&1 | Out-String
            if ($dismOut -match '(?m)^\s*Component Store Cleanup Recommended\s*:\s*(\w+)') {
                if ($Matches[1] -eq 'Yes') {
                    [void]$plan.Add([PSCustomObject]@{
                        Cat='sys'; Id='dismclean'
                        Title='系统组件存储清理 (DISM)'
                        Risk='安全'; Default=$true
                        Tip='删除被取代的旧版系统组件, 官方工具操作, 通常可释放数百MB'
                        SizeMB=0; NeedsReboot=$false
                    })
                }
            }
        } catch {}
    }

    # ---------- B. 注册表清理 (只做两类确定安全的) ----------
    $orphStartup = Get-OrphanStartup
    if ($orphStartup.Count -gt 0) {
        $names = ($orphStartup | ForEach-Object { $_.Name }) -join ', '
        [void]$plan.Add([PSCustomObject]@{
            Cat='reg'; Id='orphanstartup'
            Title=("失效的开机启动项: {0} 个" -f $orphStartup.Count)
            Detail=$names; Risk='安全'
            Tip='这些启动项指向的程序已被删除, 会在每次开机时报错并拖慢启动'
            Default=$true; Data=$orphStartup
        })
    }

    $orphUninst = Get-OrphanUninstall
    if ($orphUninst.Count -gt 0) {
        $names = ($orphUninst | ForEach-Object { $_.Name }) -join ', '
        [void]$plan.Add([PSCustomObject]@{
            Cat='reg'; Id='orphanuninstall'
            Title=("卸载残留项: {0} 个" -f $orphUninst.Count)
            Detail=$names; Risk='注意'
            Tip='程序已删除但注册表记录还在, 会让"已安装程序"列表变乱'
            Default=$false; Data=$orphUninst
        })
    }

# ---------- 显示 ----------
    Write-Host ''

    $diskMB = 0
    foreach ($p in $plan) { if ($p.Cat -eq 'disk' -and $p.SizeMB) { $diskMB += $p.SizeMB } }
    if ($diskMB -gt 0) {
        Write-Host ("  A. 磁盘垃圾  合计 {0:N0} MB" -f $diskMB) -ForegroundColor Green
    }
    foreach ($p in ($plan | Where-Object { $_.Cat -eq 'disk' })) {
        Write-Host ("     [{0}] {1}   ({2})" -f $(if($p.Default){'*'}else{' '}), $p.Title, $p.Risk) -ForegroundColor Gray
        if ($p.Tip) { Write-Host ("         {0}" -f $p.Tip) -ForegroundColor DarkGray }
    }

    $sysItems = @($plan | Where-Object { $_.Cat -eq 'sys' })
    if ($sysItems.Count -gt 0) {
        Write-Host ''
        Write-Host '  B. 系统官方清理工具 (推荐)' -ForegroundColor Green
        foreach ($p in $sysItems) {
            Write-Host ("     [{0}] {1}   ({2})" -f $(if($p.Default){'*'}else{' '}), $p.Title, $p.Risk) -ForegroundColor Gray
            Write-Host ("         {0}" -f $p.Tip) -ForegroundColor DarkGray
        }
    }

    $regItems = @($plan | Where-Object { $_.Cat -eq 'reg' })
    if ($regItems.Count -gt 0) {
        Write-Host ''
        Write-Host '  C. 注册表清理 (仅限确定安全的残留项)' -ForegroundColor Green
        foreach ($p in $regItems) {
            Write-Host ("     [{0}] {1}   ({2})" -f $(if($p.Default){'*'}else{' '}), $p.Title, $p.Risk) -ForegroundColor Gray
            Write-Host ("         {0}" -f $p.Tip) -ForegroundColor DarkGray
            Write-Host ("         涉及: {0}" -f $p.Detail) -ForegroundColor DarkGray
        }
    }

    $warn = @()
    foreach ($p in $plan) {
        if ($p.Risk -eq '注意' -and -not $p.Default) {
            $warn += ("{0} —— {1}" -f ($p.Title -replace '\s*\(\d+\s*MB\)',''), $p.Tip)
        }
    }
    if ($warn.Count -gt 0) {
        Write-Host ''
        Write-Host '  ⚠ 默认跳过的项目 (不勾选就不会执行):' -ForegroundColor Yellow
        foreach ($w in $warn) { Write-Host ("     - {0}" -f $w) -ForegroundColor DarkYellow }
    }

    if ($plan.Count -eq 0) {
        Clear-Line
        Ok '未发现可清理的垃圾'
    }
    return ,$plan
}

function Clear-TreeFiles([string]$Path, [int]$Days) {
    # 清空目录下所有(足够旧的)文件, 返回删除数量
    $n = 0
    if (-not (Test-Path $Path)) { return 0 }
    $cut = if ($Days -gt 0) { (Get-Date).AddDays(-$Days) } else { $null }
    Get-ChildItem $Path -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            if ($cut -and $_.LastWriteTime -ge $cut) { return }
            Remove-Item $_.FullName -Force -ErrorAction Stop
            $script:CleanedFiles++
            $n++
        } catch {}
    }
    # 顺手删掉空目录
    Get-ChildItem $Path -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
            try {
                if (-not (Get-ChildItem $_.FullName -Force -ErrorAction SilentlyContinue)) {
                    Remove-Item $_.FullName -Force -ErrorAction Stop
                }
            } catch {}
        }
    return $n
}

function Invoke-DiskClean($item) {
    # 支持两种形态: 单路径 或 多路径集合(浏览器缓存)
    if ($item.MultiPaths) {
        $total = 0
        foreach ($mp in $item.MultiPaths) { $total += (Clear-TreeFiles -Path $mp -Days 0) }
        return $total
    }
    return (Clear-TreeFiles -Path $item.Path -Days $item.Days)
}

function Invoke-SysClean($item) {
    # 调用 Windows 官方磁盘清理工具
    # 它能安全回收: 旧版安装副本 / 临时安装文件 / 升级残留 等手工不敢碰的部分
    if ($item.Id -eq 'dismclean') {
        Write-Host '      正在清理系统组件存储 (DISM), 请稍候...' -ForegroundColor DarkGray
        $out = & dism.exe /Online /Cleanup-Image /StartComponentCleanup /NoRestart 2>&1 | Out-String
        if ($out -match '(?i)completed successfully|操作成功') {
            return 'ok'
        } elseif ($out -match '(?i)no component store cleanup|不需要清理') {
            return 'noop'
        } else {
            return 'fail'
        }
    }
    return 'noop'
}

function Invoke-RegClean($item) {
    $ok = 0
    if ($item.Id -eq 'orphanstartup') {
        foreach ($o in $item.Data) {
            try {
                Backup-Record 'RunKey' "$($o.RegPath)::$($o.Name)" $o.Value
                Remove-ItemProperty -Path $o.RegPath -Name $o.Name -ErrorAction Stop
                Ok "已移除失效启动项: $($o.Name)"
                $ok++
            } catch { Warn "移除失败 $($o.Name): $($_.Exception.Message)" }
        }
    } elseif ($item.Id -eq 'orphanuninstall') {
        foreach ($o in $item.Data) {
            try {
                # 先把名称和路径记录到备份目录, 再删除注册表键
                $safeName = ($o.Name -replace '[^\w\-\.]', '_')
                $note = @(
                    "卸载残留项已移除, 如需恢复请手动重建以下信息:",
                    "  名称    : $($o.Name)",
                    "  安装路径: $($o.MissingPath)  (该路径当时已不存在)",
                    "  注册表键: $($o.RegPath)"
                ) -join "`r`n"
                [IO.File]::WriteAllText((Join-Path $THIS_BAK "uninstall_$safeName.txt"), $note, [Text.Encoding]::UTF8)
                Remove-Item -Path $o.RegPath -Recurse -Force -ErrorAction Stop
                Ok "已移除卸载残留: $($o.Name)"
                $ok++
            } catch { Warn "移除失败 $($o.Name): $($_.Exception.Message)" }
        }
    }
    return $ok
}

function Invoke-JunkClean {
    Banner
    $plan = Get-JunkPlan
    if (-not $plan -or $plan.Count -eq 0) { return }

    Clear-Line
    Section '选择清理项目'
    Info '[1] 一键清理   —— 清理所有推荐项'
    Info '[2] 逐项选择   —— 自己勾选'
    Info '[0] 取消'
    Write-Host ''
    $c = (Read-Host '  请选择').Trim()

    $sel = @()
    switch ($c) {
        '1' { $sel = @($plan | Where-Object { $_.Default }); Clear-Line; Ok "将清理 $($sel.Count) 项" }
        '2' {
            Clear-Line
            Section '逐项选择'
            for ($i = 0; $i -lt $plan.Count; $i++) {
                $t = $plan[$i]
                Write-Host ("     {0}. [{1}] {2}" -f ($i+1), $(if($t.Default){'*'}else{' '}), $t.Title) -ForegroundColor White
            }
            Write-Host ''
            $inp = Read-Host '  输入序号 (多个用空格, 回车用推荐值)'
            if ([string]::IsNullOrWhiteSpace($inp)) { $sel = @($plan | Where-Object { $_.Default }) }
            elseif ($inp.Trim() -ne '0') {
                foreach ($s in ($inp -split '[\s,]+')) {
                    $n = 0
                    if ([int]::TryParse($s.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $plan.Count) { $sel += $plan[$n-1] }
                }
            }
            Clear-Line
        }
        '0' { Clear-Line; Info '已取消'; return }
        default { Warn '无效选项'; return }
    }

    if ($sel.Count -eq 0) { Clear-Line; Info '未选择任何项目'; return }

    New-Item -ItemType Directory -Path $THIS_BAK -Force | Out-Null
    $script:CleanedFiles = 0
    Clear-Line
    Section "开始清理 (共 $($sel.Count) 项)"

    foreach ($t in $sel) {
        Clear-Line
        Write-Host ('=' * 64) -ForegroundColor DarkCyan
        Write-Host "  $($t.Title)" -ForegroundColor White
        Write-Host ('=' * 64) -ForegroundColor DarkCyan
        try {
            if ($t.Cat -eq 'sys') {
                $r = Invoke-SysClean $t
                if ($r -eq 'ok')      { Ok '系统组件存储清理完成' }
                elseif ($r -eq 'noop') { Info '无需清理' }
                else { Warn "清理未完全成功 (可能需要管理员权限)" }
            } elseif ($t.Cat -eq 'disk') {
                $n = Invoke-DiskClean $t
                Ok "已清理 $($n) 个文件"
            } else {
                $n = Invoke-RegClean $t
                Ok "已处理 $n 项"
            }
        } catch {
            Bad "失败: $($_.Exception.Message)"
        }
    }

    Backup-Save
    Clear-Line
    Section '清理完成'
    if ($script:CleanedFiles -gt 0) {
        Ok "共删除 $($script:CleanedFiles) 个文件"
    }
    Ok "备份目录: $THIS_BAK"
    Clear-Line
    Info '被占用的文件会自动跳过, 下次重启后可再清理一次'
    Clear-Line
}
function Show-Menu {
    Banner
    Write-Host ''
    Write-Host '   [1] 全面检测        只看不改, 生成问题清单' -ForegroundColor White
    Write-Host '   [2] 检测并修复      一键全修 或 逐项挑选, 自动备份可回滚' -ForegroundColor White
    Write-Host '   [3] 垃圾清理        磁盘缓存/临时文件/注册表残留' -ForegroundColor White
    Write-Host '   [4] 磁盘基准测试    实测硬盘速度' -ForegroundColor White
    Write-Host '   [5] 回滚设置        还原之前的修改' -ForegroundColor White
    Write-Host ''
    if ($script:MissingCmds -and $script:MissingCmds.Count -gt 0) {
        Write-Host ("  提示: 当前系统缺少部分组件, 相关功能会自动跳过: " + ($script:MissingCmds -join ', ')) -ForegroundColor DarkYellow
        Write-Host ''
    }
    $c = Read-Host '  请选择'
    switch ($c.Trim()) {
        '1' { Invoke-Scan | Out-Null; Show-Menu }
        '2' { Invoke-Fix; Show-Menu }
        '3' { Invoke-JunkClean; Show-Menu }
        '4' { Invoke-Bench; Show-Menu }
        '5' { Invoke-Rollback; Show-Menu }
        default { Warn '无效选项'; Start-Sleep -Seconds 1; Show-Menu }
    }
}

# ============================ 入口 ============================
Test-Compatibility
switch ($Mode) {
    'Scan'     { Invoke-Scan | Out-Null; Read-Host '  按回车返回' | Out-Null }
    'Fix'      { Invoke-Fix;         Read-Host '  按回车返回' | Out-Null }
    'Junk'     { Invoke-JunkClean;    Read-Host '  按回车返回' | Out-Null }
    'Bench'    { Invoke-Bench;       Read-Host '  按回车返回' | Out-Null }
    'Rollback' { Invoke-Rollback;    Read-Host '  按回车返回' | Out-Null }
    default    { Show-Menu }
}
