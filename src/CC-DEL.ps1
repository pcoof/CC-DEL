#Requires -Version 5.1
<#
==========================================================================
 CC-DEL —— Windows 强制删除工具（单文件 / 免安装 / 无外部依赖）
==========================================================================
 作者说明：
   本脚本只有这一个文件，不写 HKLM、不需要管理员权限即可运行（处理系统目录时才需要提权）。

 用法（推荐用编译好的 CC-DEL.exe，全程不出现控制台窗口）：
   1) 图形界面：  双击 CC-DEL.exe
   2) 右键菜单：  CC-DEL.exe -Install / CC-DEL.exe -Uninstall（界面右上角也有按钮）
   3) 自检：      CC-DEL.exe -SelfTest
   4) 诊断占用：  CC-DEL.exe -Probe "路径"     只查不删，回答"到底谁锁着它"
   5) 重启后删：  CC-DEL.exe -Pending "路径"   登记到下次开机由系统清除
   直接跑脚本也可以：powershell -ExecutionPolicy Bypass -File CC-DEL.ps1 [-Install|-SelfTest]
  说明：CC-DEL.exe 优先使用同目录的 CC-DEL.ps1；没有时用内置副本（释放到 %LOCALAPPDATA%\CC-DEL\）。

 删除策略（渐进式，能在前面解决就绝不乱动权限）：
   ① 直接删（.NET，带 \\?\ 长路径支持）
   ② 清属性  attrib -R -H -S
   ③ 解占用  Restart Manager API（系统自带，等价 handle.exe）
   ④ 修权限  takeown + icacls（仅在前面全失败时才动 ACL）
   ⑤ 强兜底  robocopy 空目录镜像 / cmd del
   ⑥ 重启删  登记 PendingFileRenameOperations（专治 dll 被加载后的映像锁定）

 关于「删不掉」的两类占用（-Probe 会直接告诉你属于哪类）：
   · 句柄占用：进程开着文件句柄，结束进程即可释放
   · 映像锁定：dll 已被加载进进程，没有句柄，结束进程也未必释放，通常只能重启

 界面能力：
   · 列表支持拖拽加入、Ctrl 多选、悬停显示完整路径
   · 右侧「解除占用」按钮：只结束占用进程，不删除文件、不改权限
   · 删除完成后成功的项自动从列表移除，失败的项保留
==========================================================================
#>
[CmdletBinding()]
param(
    [string]$Add,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$SelfTest,
    [string]$Probe,
    [string]$Pending
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# ========================= 全局状态 =========================
$script:Root      = Join-Path $env:LOCALAPPDATA 'CC-DEL'
$script:QueueFile = Join-Path $script:Root 'queue.txt'
$script:LogFile   = Join-Path $script:Root 'CC-DEL.log'
$script:MutexName = 'Local\CCDEL_Gui'
$script:PsExe     = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
# exe 宿主（CC-DEL.exe）会注入 WINDEL_HOST_EXE。
# 有值时，右键菜单与提权重启都指向 exe 自身，避免 "powershell -File" 那种闪黑窗。
$script:HostExe   = ''
try {
    $hx = [string]$env:WINDEL_HOST_EXE
    if ($hx -and (Test-Path -LiteralPath $hx)) { $script:HostExe = $hx }
} catch { }
if ($script:HostExe) {
    # 被 exe 宿主调用时用 UTF-8 输出，宿主捕获后才能在对话框里正确显示中文
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
}
$script:EchoLog   = $false
$script:GuiMode   = $false
$script:AppId     = 'CCDEL.ForceDelete.Gui'
# 窗口/任务栏图标：exe 宿主会注入 WINDEL_ICON（内嵌 ico 释放出来的路径）
$script:IconPath  = ''
try {
    $ip = [string]$env:WINDEL_ICON
    if ($ip -and (Test-Path -LiteralPath $ip)) { $script:IconPath = $ip }
} catch { }
if (-not $script:IconPath) {
    $here = ''
    try { $here = Split-Path -Path $PSCommandPath -Parent } catch { }
    $cands = @()
    if ($here) {
        $cands += (Join-Path $here 'CC-DEL.ico')
        $cands += (Join-Path $here 'logo.ico')
    }
    $cands += (Join-Path $script:Root 'CC-DEL.ico')
    foreach ($cand in $cands) {
        if ($cand -and (Test-Path -LiteralPath $cand)) { $script:IconPath = $cand; break }
    }
}
$script:Busy      = $false
$script:AskKill   = $true
$script:KillAll   = $false
$script:RebootAll = $false
$script:LastError = ''
$script:LastModuleLock = ''
$script:QueueStamp = ''
$script:Opt = @{ Unlock = $true; FixAcl = $true; Confirm = $true; Reboot = $true }
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path -LiteralPath $script:Root)) {
    New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
}

# 老版本（WinDel）队列迁移：换名不该把用户攒了一路的待删列表弄丢。
try {
    $legacyQueue = Join-Path (Join-Path $env:LOCALAPPDATA 'WinDel') 'queue.txt'
    if ((Test-Path -LiteralPath $legacyQueue) -and -not (Test-Path -LiteralPath $script:QueueFile)) {
        Copy-Item -LiteralPath $legacyQueue -Destination $script:QueueFile -Force
    }
} catch { }
if (-not (Test-Path -LiteralPath $script:QueueFile)) {
    [System.IO.File]::WriteAllText($script:QueueFile, '', $script:Utf8NoBom)
}
# 日志限长：超过 5MB 就归档，避免无限膨胀
try {
    if ((Test-Path -LiteralPath $script:LogFile) -and ((Get-Item -LiteralPath $script:LogFile).Length -gt 5MB)) {
        Move-Item -LiteralPath $script:LogFile -Destination ($script:LogFile + '.old') -Force
    }
} catch { }

# ========================= 日志 =========================
function Write-Log {
    param([string]$Text)
    $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Text
    try { [System.IO.File]::AppendAllText($script:LogFile, $line + "`r`n", $script:Utf8NoBom) } catch { }
    if ($script:GuiMode -and $script:LogBox) {
        try {
            $script:LogBox.AppendText($line + "`r`n")
            $script:LogBox.SelectionStart = $script:LogBox.TextLength
            $script:LogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        } catch { }
    }
    if ($script:EchoLog) { Write-Host $line }
}

# ========================= 队列文件（列表的唯一数据源） =========================
function Get-QueueItems {
    if (-not (Test-Path -LiteralPath $script:QueueFile)) { return @() }
    try {
        $lines = [System.IO.File]::ReadAllLines($script:QueueFile, [System.Text.Encoding]::UTF8)
        $out = @()
        foreach ($l in $lines) { if ($l -and $l.Trim().Length -gt 0) { $out += $l } }
        return $out
    } catch { return @() }
}

function Set-QueueItems {
    param([string[]]$Items)
    if ($null -eq $Items) { $Items = @() }
    try {
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines($script:QueueFile, [string[]]$Items, $enc)
    } catch { Write-Log ('❌ 写入队列失败：' + $_.Exception.Message) }
}

function Add-QueuePath {
    param([string]$Path)
    $p = ($Path + '').Trim().Trim('"')
    if ($p.Length -eq 0) { return $false }
    if ($p -notmatch '^[A-Za-z]:\\?$') { $p = $p.TrimEnd('\') }
    # 这里绝不能用 Test-Path：它走 Win32 的路径规范化，会把 nul/con/aux 当作设备名，
    # 导致一个真实存在的 0 字节文件被判定为"不存在"，也会在超长路径上直接失败。
    # Test-Exists 用 \\?\ 前缀按字面路径判断，不受这两类影响。
    if (-not (Test-Exists -Path $p)) {
        Write-Log ('⚠️ 路径不存在，已忽略：' + $p)
        return $false
    }
    if (Test-ReservedName -Path $p) {
        Write-Log ('🧩 这是 Windows 保留名文件，普通接口会把它当设备，已按 \\?\ 字面路径处理：' + $p)
    }
    $items = @(Get-QueueItems)
    foreach ($i in $items) {
        if ([string]::Equals($i, $p, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Log ('ℹ️ 已在列表中：' + $p)
            return $false
        }
    }
    $items += $p
    Set-QueueItems -Items $items
    Write-Log ('➕ 加入列表：' + $p)
    return $true
}

function Get-QueueStamp {
    if (-not (Test-Path -LiteralPath $script:QueueFile)) { return '0' }
    try {
        $fi = New-Object System.IO.FileInfo($script:QueueFile)
        return ([string]$fi.LastWriteTimeUtc.Ticks + ':' + [string]$fi.Length)
    } catch { return '0' }
}

# ========================= 路径工具 =========================
function ConvertTo-ExtendedPath {
    param([string]$Path)
    if (-not $Path) { return $Path }
    $p = $Path.Trim()
    if ($p.StartsWith('\\?\')) { return $p }
    if ($p.StartsWith('\\')) { return '\\?\UNC\' + $p.Substring(2) }
    if ($p -match '^[A-Za-z]:\\?$') { return '\\?\' + $p.Substring(0, 2) + '\' }
    $full = $p
    try { if (-not ($p -match '^[A-Za-z]:\\')) { $full = [System.IO.Path]::GetFullPath($p) } } catch { $full = $p }
    return '\\?\' + $full
}

function Test-Exists {
    param([string]$Path)
    if (-not $Path) { return $false }
    $ext = ConvertTo-ExtendedPath -Path $Path
    try { if ([System.IO.File]::Exists($ext)) { return $true } } catch { }
    try { if ([System.IO.Directory]::Exists($ext)) { return $true } } catch { }
    return $false
}

function Test-IsDirectory {
    param([string]$Path)
    try { return [System.IO.Directory]::Exists((ConvertTo-ExtendedPath -Path $Path)) } catch { return $false }
}

# Windows 保留设备名：con / prn / aux / nul / ncl / com1-9 / lpt1-9。
# 这类名字即使作为普通文件存在于磁盘上，任何不带 \\?\ 前缀的 API 都会解析成设备：
#   · Test-Path 返回 False（文件"不存在"）
#   · 写入会打到空设备（数据凭空消失）
#   · 只有 \\?\ 前缀能把它们当字面文件名处理
function Test-ReservedName {
    param([string]$Path)
    if (-not $Path) { return $false }
    $leaf = $Path.TrimEnd('\')
    $i = $leaf.LastIndexOf('\')
    if ($i -ge 0) { $leaf = $leaf.Substring($i + 1) }
    $j = $leaf.IndexOf('.')
    if ($j -ge 0) { $leaf = $leaf.Substring(0, $j) }
    if (-not $leaf) { return $false }
    return ($leaf -match '^(con|prn|aux|nul|ncl|com[1-9]|lpt[1-9])$')
}

# 保护名单：只拦「目录本身」，不拦其子项，避免误删整棵树
function Test-Protected {
    param([string]$Path)
    $p = $Path.Trim()
    if ($p -match '^[A-Za-z]:[\\/]*$') { return $true }   # 盘符根，如 C:\ / C:
    $p = $p.TrimEnd('\')
    if ($p -eq '' -or $p -eq '\\') { return $true }
    $guard = @(
        $env:SystemRoot,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        $env:USERPROFILE,
        (Split-Path $env:USERPROFILE -Parent),
        $env:LOCALAPPDATA,
        $env:APPDATA,
        $script:Root
    )
    foreach ($g in $guard) {
        if (-not $g) { continue }
        if ([string]::Equals($p, $g.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# ========================= Restart Manager（替代 handle.exe） =========================
if (-not ('CCDEL.Rm' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace CCDEL
{
    public static class Rm
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct RM_UNIQUE_PROCESS
        {
            public int dwProcessId;
            public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct RM_PROCESS_INFO
        {
            public RM_UNIQUE_PROCESS Process;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
            public string strAppName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
            public string strServiceShortName;
            public int ApplicationType;
            public uint AppStatus;
            public uint TSSessionId;
            [MarshalAs(UnmanagedType.Bool)]
            public bool bRestartable;
        }

        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        private static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, StringBuilder strSessionKey);

        [DllImport("rstrtmgr.dll")]
        private static extern int RmEndSession(uint pSessionHandle);

        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        private static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames,
            uint nApplications, RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);

        [DllImport("rstrtmgr.dll")]
        private static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo,
            [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);

        /// <summary>返回占用指定路径的进程，格式 "pid|名称"；失败时抛异常。</summary>
        public static string[] GetLockers(string path)
        {
            return GetLockers(new string[] { path });
        }

        /// <summary>
        /// 一次注册多个路径。删除目录时必须把内部文件逐个注册——
        /// Restart Manager 不会递归目录，只注册目录路径会漏掉里面的被锁文件。
        /// </summary>
        public static string[] GetLockers(string[] paths)
        {
            List<string> result = new List<string>();
            if (paths == null || paths.Length == 0) return result.ToArray();
            uint handle = 0;
            StringBuilder key = new StringBuilder(64);
            int rv = RmStartSession(out handle, 0, key);
            if (rv != 0) throw new Exception("RmStartSession 失败，代码 " + rv);
            try
            {
                rv = RmRegisterResources(handle, (uint)paths.Length, paths, 0, null, 0, null);
                if (rv != 0) throw new Exception("RmRegisterResources 失败，代码 " + rv);

                uint needed = 0, count = 0, reasons = 0;
                rv = RmGetList(handle, out needed, ref count, null, ref reasons);
                if (rv == 234 && needed > 0)
                {
                    RM_PROCESS_INFO[] infos = new RM_PROCESS_INFO[needed];
                    count = needed;
                    rv = RmGetList(handle, out needed, ref count, infos, ref reasons);
                    if (rv == 0)
                    {
                        for (int i = 0; i < count; i++)
                        {
                            string nm = infos[i].strAppName;
                            if (nm == null) nm = "";
                            result.Add(infos[i].Process.dwProcessId.ToString() + "|" + nm);
                        }
                    }
                }
            }
            finally { RmEndSession(handle); }
            return result.ToArray();
        }
    }
}
'@
}

$script:CriticalProcs = @('system', 'idle', 'csrss', 'wininit', 'winlogon', 'services',
    'lsass', 'smss', 'dwm', 'svchost', 'fontdrvhost', 'msmpeng', 'audiodg')

function Get-LockerList {
    param([string]$Path)
    $entries = @()
    $raw = @()

    # Restart Manager 只认传进去的路径，不会递归目录。
    # 删除目录时若只注册目录本身，内部被锁的 dll/exe 会完全漏检（表现为"未检测到占用进程"）。
    $probe = New-Object System.Collections.Generic.List[string]
    if ($Path.Length -le 250) { [void]$probe.Add($Path) }
    if (Test-IsDirectory -Path $Path) {
        try {
            $inner = @(Get-ChildItem -LiteralPath (ConvertTo-ExtendedPath -Path $Path) -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -match '^\.(dll|exe|sys|ocx|cpl|scr)$' } |
                Select-Object -First 60)
            foreach ($i in $inner) {
                $fn = $i.FullName
                if ($fn.StartsWith('\\?\')) { $fn = $fn.Substring(4) }   # RM 不认扩展路径前缀
                if ($fn.Length -le 250 -and -not $probe.Contains($fn)) { [void]$probe.Add($fn) }
            }
        } catch { }
    }
    if ($probe.Count -eq 0) { return $entries }

    try { $raw = [CCDEL.Rm]::GetLockers([string[]]$probe.ToArray()) }
    catch {
        Write-Log ('⚠️ 占用检测不可用：' + $_.Exception.Message)
        return $entries
    }
    foreach ($line in $raw) {
        $parts = $line -split '\|', 2
        $procId = 0
        if (-not [int]::TryParse($parts[0], [ref]$procId)) { continue }
        if ($procId -eq $PID) { continue }
        $nm = ''
        try {
            $pr = Get-Process -Id $procId -ErrorAction Stop
            $nm = $pr.ProcessName
        } catch { $nm = ('PID ' + $procId) }
        $entries += [pscustomobject]@{ Id = $procId; Name = $nm }
    }
    return $entries
}

# RM 查不到、但文件确实被锁的另一种原因：dll/exe 已被加载进进程（映像节映射）。
# 这种占用根本没有文件句柄，结束进程也未必释放，典型表现就是"访问被拒绝"。
function Get-ModuleLocker {
    param([string]$Path)

    $targets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if (Test-IsDirectory -Path $Path) {
        try {
            $inner = @(Get-ChildItem -LiteralPath (ConvertTo-ExtendedPath -Path $Path) -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -match '^\.(dll|exe|sys|ocx|cpl|scr)$' } |
                Select-Object -First 60)
            foreach ($i in $inner) {
                $fn = $i.FullName
                if ($fn.StartsWith('\\?\')) { $fn = $fn.Substring(4) }
                [void]$targets.Add($fn)
            }
        } catch { }
    } else {
        [void]$targets.Add($Path)
    }
    if ($targets.Count -eq 0) { return @() }

    $hits = @()
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        if ($p.Id -eq $PID) { continue }
        try {
            foreach ($m in $p.Modules) {
                if ($m.FileName -and $targets.Contains($m.FileName)) {
                    $hits += [pscustomobject]@{ Id = $p.Id; Name = $p.ProcessName; Module = $m.FileName }
                    break
                }
            }
        } catch { }
    }
    return $hits
}

function Unlock-Target {
    param([string]$Path)

    $lockers = @(Get-LockerList -Path $Path)
    if ($lockers.Count -eq 0) {
        # RM 说没占用，但还有另一种锁：dll 已经被 LoadLibrary 加载进进程，
        # 文件没有句柄、只有映像节映射，RM 查不出来，删除照样"访问被拒绝"。
        $mods = @(Get-ModuleLocker -Path $Path)
        if ($mods.Count -gt 0) {
            $names = ($mods | ForEach-Object { $_.Name + '(' + $_.Id + ')' }) -join '、'
            Write-Log ('🧩 检测到已加载模块锁定：' + $names)
            Write-Log '   这类占用不是文件句柄，无法靠常规解锁释放；结束进程后文件仍可能被映射，通常需要重启才能删。'
            $script:LastModuleLock = $names
            return 'module'
        }
        Write-Log '🔍 未检测到占用进程'
        return 'none'
    }

    $killable = @()
    foreach ($l in $lockers) {
        $low = ([string]$l.Name).ToLowerInvariant()
        if ($script:CriticalProcs -contains $low) {
            Write-Log ('🛡️ 受保护进程，跳过结束：' + $l.Name + '(' + $l.Id + ')')
            continue
        }
        $killable += $l
    }
    if ($killable.Count -eq 0) { return 'blocked' }

    $names = ($killable | ForEach-Object { $_.Name + '(' + $_.Id + ')' }) -join '、'
    Write-Log ('🔒 占用进程：' + $names)

    $doKill = $false
    if ($script:KillAll) {
        $doKill = $true
    } elseif ($script:GuiMode -and $script:AskKill) {
        $msg = "以下进程正在占用：`r`n`r`n$names`r`n`r`n结束进程可能造成未保存数据丢失。是否结束它们？"
        $r = [System.Windows.Forms.MessageBox]::Show($msg, '解除占用', 'YesNoCancel', 'Warning')
        if ($r -eq 'Cancel') { Write-Log '⏹️ 已中止该项'; return 'abort' }
        if ($r -eq 'Yes') { $doKill = $true }
    }

    if (-not $doKill) {
        Write-Log '⏭️ 跳过结束进程'
        return 'skip'
    }

    foreach ($l in $killable) {
        try {
            Stop-Process -Id $l.Id -Force -ErrorAction Stop
            Write-Log ('🔴 已结束 ' + $l.Name + '(' + $l.Id + ')')
        } catch {
            Write-Log ('⚠️ 结束失败 ' + $l.Name + '(' + $l.Id + ')：' + $_.Exception.Message)
        }
    }
    Start-Sleep -Milliseconds 350
    return 'killed'
}

# ========================= 属性 / 权限 =========================
function Clear-Attribute {
    param([string]$Path)
    # 保留名文件不能交给 attrib.exe：它拿到的参数会被解析成设备，等于什么都没做
    if (Test-ReservedName -Path $Path) {
        Write-Log '🔧 清除只读/隐藏/系统属性（保留名文件，走 .NET 直接改属性）'
        try { [System.IO.File]::SetAttributes((ConvertTo-ExtendedPath -Path $Path), [System.IO.FileAttributes]::Normal) } catch { }
        return
    }
    # attrib.exe 不认 \\?\ 前缀，优先用原始路径；超长路径再退回扩展路径
    $usePath = $Path
    if ($Path.Length -gt 240) { $usePath = ConvertTo-ExtendedPath -Path $Path }
    Write-Log '🔧 清除只读/隐藏/系统属性'
    try {
        if (Test-IsDirectory -Path $Path) {
            & attrib.exe -R -H -S /S /D "$usePath" *> $null
        } else {
            & attrib.exe -R -H -S "$usePath" *> $null
            try { [System.IO.File]::SetAttributes((ConvertTo-ExtendedPath -Path $Path), [System.IO.FileAttributes]::Normal) } catch { }
        }
    } catch { }
}

function Repair-Acl {
    param([string]$Path)
    $ext = ConvertTo-ExtendedPath -Path $Path
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    if (Test-IsDirectory -Path $Path) {
        Write-Log '🔧 接管所有权（递归）'
        & takeown.exe /F "$ext" /R /D Y *> $null
        Write-Log ('🔧 授予完全控制：' + $me)
        & icacls.exe "$ext" /grant "$($me):(OI)(CI)F" /T /C /Q *> $null
    } else {
        Write-Log '🔧 接管所有权'
        & takeown.exe /F "$ext" *> $null
        Write-Log ('🔧 授予完全控制：' + $me)
        & icacls.exe "$ext" /grant "$($me):F" /C /Q *> $null
    }
}

# ========================= 删除原子操作 =========================
function Remove-Target {
    param([string]$Path, [switch]$Hard)

    $ext = ConvertTo-ExtendedPath -Path $Path
    $isDir = Test-IsDirectory -Path $Path
    $script:LastError = ''

    try {
        if ($isDir) {
            if (-not $Hard) {
                [System.IO.Directory]::Delete($ext, $true)
            } else {
                $empty = Join-Path $env:TEMP ('wdel_' + [Guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $empty -Force | Out-Null
                try {
                    & robocopy.exe "$empty" "$Path" /MIR /R:0 /W:0 /NFL /NDL /NJH /NJS /NP *> $null
                    try { [System.IO.Directory]::Delete($ext, $true) } catch {
                        try { [System.IO.Directory]::Delete($ext, $false) } catch { & cmd.exe /c rd /s /q "$ext" *> $null }
                    }
                } finally {
                    Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        } else {
            if (-not $Hard) {
                try { [System.IO.File]::SetAttributes($ext, [System.IO.FileAttributes]::Normal) } catch { }
                [System.IO.File]::Delete($ext)
            } else {
                & cmd.exe /c del /f /q /a "$ext" *> $null
            }
        }
    } catch {
        $script:LastError = $_.Exception.Message
        if (-not $Hard) { return (Test-DeleteRetry -Path $Path) }
    }

    Start-Sleep -Milliseconds 120
    return (-not (Test-Exists -Path $Path))
}

function Test-DeleteRetry {
    param([string]$Path)
    Start-Sleep -Milliseconds 120
    return (-not (Test-Exists -Path $Path))
}

# ========================= 单项目流水线 =========================
# ========================= 重启后删除（PendingFileRenameOperations） =========================
# 被映像节锁定的 dll 在当前会话里删不掉——但重启那一刻没有任何进程加载它。
# 登记到 Session Manager 的延迟操作队列，开机时由系统替我们删掉。
function Add-PendingDelete {
    param([string]$Path)

    $targets = New-Object System.Collections.Generic.List[string]
    if (Test-IsDirectory -Path $Path) {
        try {
            $all = @(Get-ChildItem -LiteralPath (ConvertTo-ExtendedPath -Path $Path) -Recurse -Force -ErrorAction SilentlyContinue)
            # 先删文件，再按层级由深到浅删目录（目录必须为空才能删）
            foreach ($i in ($all | Where-Object { -not $_.PSIsContainer })) { [void]$targets.Add($i.FullName) }
            foreach ($i in ($all | Where-Object { $_.PSIsContainer } | Sort-Object { $_.FullName.Length } -Descending)) { [void]$targets.Add($i.FullName) }
        } catch { }
    }
    [void]$targets.Add($Path)

    $root = $null
    try {
        $root = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager', $true)
    } catch { }
    if ($null -eq $root) {
        Write-Log '⚠️ 无法写入重启删除队列：需要点「以管理员重启」后再试'
        return $false
    }
    try {
        $list = New-Object System.Collections.Generic.List[string]
        $old = $root.GetValue('PendingFileRenameOperations')
        if ($old) { foreach ($o in @($old)) { if ($null -ne $o) { [void]$list.Add([string]$o) } } }
        foreach ($t in $targets) {
            $q = [string]$t
            if ($q.StartsWith('\\?\')) { $q = $q.Substring(4) }
            [void]$list.Add('\??\' + $q)   # 源路径
            [void]$list.Add('')            # 目标为空 = 删除
        }
        $root.SetValue('PendingFileRenameOperations', [string[]]$list.ToArray(), [Microsoft.Win32.RegistryValueKind]::MultiString)

        # 写完立刻读回校验：这是系统启动项，写坏了会影响开机，宁可回滚
        $verify = $root.GetValue('PendingFileRenameOperations')
        if (-not $verify -or @($verify).Count -lt $list.Count) {
            if ($old) { $root.SetValue('PendingFileRenameOperations', [string[]]@($old), [Microsoft.Win32.RegistryValueKind]::MultiString) }
            else { $root.DeleteValue('PendingFileRenameOperations', $false) }
            Write-Log '⚠️ 重启删除登记校验未通过，已回滚'
            return $false
        }
        Write-Log ('📌 已登记重启后删除：' + $Path + '（文件/目录共 ' + $targets.Count + ' 项）')
        return $true
    } catch {
        Write-Log ('⚠️ 登记重启删除失败：' + $_.Exception.Message)
        return $false
    } finally {
        try { $root.Close() } catch { }
    }
}

function Invoke-ForceDelete {
    param([string]$Path)

    $target = $Path
    $script:LastModuleLock = ''
    if (Test-Protected -Path $target) {
        Write-Log ('⛔ 受保护路径，已跳过：' + $target)
        return $false
    }
    if (-not (Test-Exists -Path $target)) {
        Write-Log ('ℹ️ 目标已不存在：' + $target)
        return $true
    }

    # ① 直接删（零副作用，绝大多数情况一次过）
    if (Remove-Target -Path $target) {
        Write-Log ('✅ 删除成功（直接）：' + $target)
        return $true
    }
    Write-Log ('… 直接删除失败：' + $script:LastError)

    # ② 清属性
    Clear-Attribute -Path $target
    if (Remove-Target -Path $target) {
        Write-Log ('✅ 删除成功（清属性后）：' + $target)
        return $true
    }
    Write-Log '… 清属性后仍失败'

    # ③ 解占用
    if ($script:Opt.Unlock) {
        $st = Unlock-Target -Path $target
        if ($st -eq 'abort') { return $false }
        if ($st -eq 'killed') {
            if (Remove-Target -Path $target) {
                Write-Log ('✅ 删除成功（解除占用后）：' + $target)
                return $true
            }
            Write-Log '… 解除占用后仍失败'
        }
    }

    # ④ 修权限（会改 ACL，只有前面全跪才走到这里）
    if ($script:Opt.FixAcl) {
        Repair-Acl -Path $target
        if (Remove-Target -Path $target) {
            Write-Log ('✅ 删除成功（修复权限后）：' + $target)
            return $true
        }
        Write-Log '… 修复权限后仍失败'
    }

    # ⑤ 强兜底
    if (Remove-Target -Path $target -Hard) {
        Write-Log ('✅ 删除成功（强力兜底）：' + $target)
        return $true
    }

    Write-Log ('❌ 常规手段无法删除：' + $target)
    if ($script:LastError) { Write-Log ('   最后错误：' + $script:LastError) }
    if ($script:LastModuleLock) { Write-Log ('   锁定来源（已加载模块）：' + $script:LastModuleLock) }

    # ⑥ 重启后删除：被映像节锁定的目标只能等下次开机释放
    if ($script:Opt.Reboot) {
        $doIt = $false
        if ($script:RebootAll) {
            $doIt = $true
        } elseif ($script:GuiMode) {
            $msg = '该目标被已加载的模块锁住，本次开机期间无法释放。' + "`r`n`r`n" +
                   '要登记为「重启后自动删除」吗？' + "`r`n" +
                   '系统会在下次开机时清除它，不需要你再手动操作。'
            $r = [System.Windows.Forms.MessageBox]::Show($msg, '需要重启才能删除', 'YesNoCancel', 'Question')
            if ($r -eq 'Cancel') { Write-Log '⏹️ 已取消登记'; return $false }
            if ($r -eq 'Yes') { $doIt = $true; $script:RebootAll = $true }
        }
        if ($doIt -and (Add-PendingDelete -Path $target)) {
            Write-Log '   ✅ 已受理：重启后该目标会被自动清除'
            return $true
        }
    }
    return $false
}

# ========================= 右键菜单注册（HKCU，免管理员） =========================
# 注意：注册表里 '*' 在 PowerShell 路径中是通配符，New-Item/Set-ItemProperty 会写入异常，
#       因此统一改用 .NET 注册表 API，键名按字面处理，不会踩通配符坑。
function Get-ShellKeys {
    if ($script:HostExe) {
        # exe 模式：直接调 exe，全程无控制台
        $scriptRel = '"' + $script:HostExe + '"'
    } else {
        $scriptRel = '"' + $script:PsExe + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '"'
    }
    return @(
        [pscustomobject]@{ Key = 'Software\Classes\*\shell\CCDELAdd'; Cmd = ($scriptRel + ' -Add "%1"') },
        [pscustomobject]@{ Key = 'Software\Classes\Directory\shell\CCDELAdd'; Cmd = ($scriptRel + ' -Add "%1"') },
        [pscustomobject]@{ Key = 'Software\Classes\Directory\Background\shell\CCDELAdd'; Cmd = ($scriptRel + ' -Add "%V"') }
    )
}

# 右键菜单项的图标。
# 资源管理器只认「带图标资源的文件 + 索引」，写成 exe 时索引固定为 0；
# 退回 ico 文件时不要带索引号，否则会解析成"第 0 个图标之外的空白"。
function Get-MenuIcon {
    if ($script:HostExe -and (Test-Path -LiteralPath $script:HostExe)) {
        return ('"' + $script:HostExe + '",0')
    }
    if ($script:IconPath -and (Test-Path -LiteralPath $script:IconPath)) {
        return $script:IconPath
    }
    return ''
}

# 旧版本（WinDel）留下的菜单项要顺手清掉，否则右键里会出现两条同名命令。
function Remove-LegacyMenu {
    $parents = @('Software\Classes\*\shell', 'Software\Classes\Directory\shell', 'Software\Classes\Directory\Background\shell')
    foreach ($p in $parents) {
        try { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree(($p + '\WinDelAdd'), $false) } catch { }
    }
}

function Install-Menu {
    $ok = $true
    $icon = Get-MenuIcon
    Remove-LegacyMenu
    foreach ($e in (Get-ShellKeys)) {
        try {
            $root = [Microsoft.Win32.Registry]::CurrentUser
            $k = $root.CreateSubKey($e.Key)
            $k.SetValue('', '添加到强制删除列表', [Microsoft.Win32.RegistryValueKind]::String)
            if ($icon) {
                $k.SetValue('Icon', $icon, [Microsoft.Win32.RegistryValueKind]::String)
            } else {
                try { $k.DeleteValue('Icon', $false) } catch { }
            }
            $c = $k.CreateSubKey('command')
            $c.SetValue('', $e.Cmd, [Microsoft.Win32.RegistryValueKind]::String)
            $c.Close()
            $k.Close()
        } catch {
            Write-Host ('写入失败：HKCU\' + $e.Key + ' -> ' + $_.Exception.Message) -ForegroundColor Red
            $ok = $false
        }
    }
    if ($ok) {
        if ($icon) { Write-Host ('✅ 右键菜单已安装，图标：' + $icon) -ForegroundColor Green }
        else { Write-Host '✅ 右键菜单已安装（未找到图标资源，菜单项为默认外观）' -ForegroundColor Green }
        Write-Host '   重新打开一个文件夹或重启资源管理器后生效' -ForegroundColor DarkGray
    }
    return $ok
}

function Uninstall-Menu {
    foreach ($e in (Get-ShellKeys)) {
        try { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($e.Key, $false) } catch { }
    }
    Write-Host '✅ 右键菜单已移除' -ForegroundColor Green
}

function Test-MenuInstalled {
    try {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Classes\*\shell\CCDELAdd')
        if ($k) { $k.Close(); return $true }
        return $false
    } catch { return $false }
}

# ========================= 任务栏身份（AppUserModelID） =========================
# 界面跑在 powershell.exe 进程里，任务栏默认按 exe 归组，按钮图标就是 PowerShell 的。
# 想让任务栏认成"CC-DEL"，必须显式设置 AppUserModelID；再给它登记图标，
# 否则系统只知道身份、不知道图标，反而可能显示成空白。
if (-not ('CCDEL.Shell' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CCDEL
{
    public static class Shell
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SetCurrentProcessExplicitAppUserModelID(
            [MarshalAs(UnmanagedType.LPWStr)] string appId);

        public static bool SetAppId(string appId)
        {
            try { return SetCurrentProcessExplicitAppUserModelID(appId) == 0; }
            catch { return false; }
        }
    }
}
'@
}

# 把 AppUserModelID 与图标路径登记到 HKCU，任务栏/开始菜单据此取图标（免管理员）
function Register-AppIdIcon {
    param([string]$AppId, [string]$IconPath)
    if (-not $AppId) { return }
    try {
        $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Classes\AppUserModelId\' + $AppId)
        if (-not $k) { return }
        try { $k.SetValue('DisplayName', 'CC-DEL 强制删除工具') } catch { }
        if ($IconPath) { try { $k.SetValue('IconUri', $IconPath) } catch { } }
        $k.Close()
    } catch { }
}

# ========================= 图形界面 =========================
function Show-MainWindow {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # 必须在窗口创建前设置：任务栏按 AppUserModelID 归组取图标
    $appIdOk = $false
    try {
        if ('CCDEL.Shell' -as [type]) { $appIdOk = [CCDEL.Shell]::SetAppId($script:AppId) }
    } catch { }
    Register-AppIdIcon -AppId $script:AppId -IconPath $script:IconPath
    if (-not $appIdOk) { Write-Log '⚠️ 任务栏身份设置失败，图标可能仍显示为 PowerShell' }

    [System.Windows.Forms.Application]::EnableVisualStyles()

    $script:GuiMode = $true
    $script:HotIndex = -1

    # ---- 配色 ----
    $cBg      = [System.Drawing.ColorTranslator]::FromHtml('#F5F6F8')
    $cCard    = [System.Drawing.ColorTranslator]::FromHtml('#FFFFFF')
    $cText    = [System.Drawing.ColorTranslator]::FromHtml('#1F2328')
    $cMuted   = [System.Drawing.ColorTranslator]::FromHtml('#6B7280')
    $cFaint   = [System.Drawing.ColorTranslator]::FromHtml('#9AA4B2')
    $cAccent  = [System.Drawing.ColorTranslator]::FromHtml('#D93025')
    $cAccentD = [System.Drawing.ColorTranslator]::FromHtml('#B72A20')
    $cBorder  = [System.Drawing.ColorTranslator]::FromHtml('#E4E7EB')

    $fTitle  = New-Object System.Drawing.Font('Microsoft YaHei UI', 15, [System.Drawing.FontStyle]::Bold)
    $fSub    = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $fBody   = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $fSmall  = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
    $fBtn    = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $fMain   = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
    $fLog    = New-Object System.Drawing.Font('Consolas', 9)
    $script:FontItem = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $script:FontTag  = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)

    $script:Form = New-Object System.Windows.Forms.Form
    $script:Form.Text = 'CC-DEL 强制删除工具'
    $script:Form.ClientSize = New-Object System.Drawing.Size(820, 572)
    $script:Form.StartPosition = 'CenterScreen'
    $script:Form.FormBorderStyle = 'FixedSingle'
    $script:Form.MaximizeBox = $false
    $script:Form.BackColor = $cBg
    $script:Form.Font = $fBody
    $script:Form.AllowDrop = $true

    # 图标同时喂给窗口本身：任务栏按钮、Alt+Tab、标题栏都取它
    if ($script:IconPath) {
        try {
            $script:Form.Icon = New-Object System.Drawing.Icon($script:IconPath)
            $script:Form.ShowIcon = $true
            Write-Log ('🖼️ 窗口图标已应用：' + $script:IconPath)
        } catch { Write-Log ('⚠️ 图标加载失败：' + $_.Exception.Message) }
    } else {
        Write-Log '⚠️ 未找到图标文件，界面将使用系统默认图标'
    }

    # ================= 头部 =================
    $head = New-Object System.Windows.Forms.Panel
    $head.Location = New-Object System.Drawing.Point(0, 0)
    $head.Size = New-Object System.Drawing.Size(820, 68)
    $head.BackColor = $cCard
    $script:Form.Controls.Add($head)

    $bar = New-Object System.Windows.Forms.Panel
    $bar.Location = New-Object System.Drawing.Point(0, 0)
    $bar.Size = New-Object System.Drawing.Size(4, 68)
    $bar.BackColor = $cAccent
    $head.Controls.Add($bar)

    $lbTitle = New-Object System.Windows.Forms.Label
    $lbTitle.Text = '强制删除工具'
    $lbTitle.Font = $fTitle
    $lbTitle.ForeColor = $cText
    $lbTitle.AutoSize = $true
    $lbTitle.Location = New-Object System.Drawing.Point(20, 10)
    $head.Controls.Add($lbTitle)

    $lbSub = New-Object System.Windows.Forms.Label
    $lbSub.Text = '先温和后强力：直接删 → 清属性 → 解占用 → 修权限 → 强力兜底'
    $lbSub.Font = $fSub
    $lbSub.ForeColor = $cMuted
    $lbSub.AutoSize = $true
    $lbSub.Location = New-Object System.Drawing.Point(22, 41)
    $head.Controls.Add($lbSub)

    # 权限徽章
    $isAdmin = $false
    try {
        $isAdmin = (New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }
    $lbAdmin = New-Object System.Windows.Forms.Label
    if ($isAdmin) {
        $lbAdmin.Text = '● 管理员权限'
        $lbAdmin.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#188038')
    } else {
        $lbAdmin.Text = '● 普通权限'
        $lbAdmin.ForeColor = $cMuted
    }
    $lbAdmin.Font = $fSmall
    $lbAdmin.AutoSize = $true
    $lbAdmin.Location = New-Object System.Drawing.Point(446, 27)
    $head.Controls.Add($lbAdmin)

    # ================= 按钮工厂 =================
    function New-Btn {
        param(
            $Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H,
            [string]$Back = '#FFFFFF', [string]$Fore = '#1F2328', [string]$Border = '#DDE1E6',
            [int]$BorderW = 1, $Font = $null, [string]$Hover = '#F2F4F7'
        )
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $Text
        $b.Location = New-Object System.Drawing.Point($X, $Y)
        $b.Size = New-Object System.Drawing.Size($W, $H)
        $b.FlatStyle = 'Flat'
        $b.UseVisualStyleBackColor = $false
        $b.BackColor = [System.Drawing.ColorTranslator]::FromHtml($Back)
        $b.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Fore)
        $b.FlatAppearance.BorderColor = [System.Drawing.ColorTranslator]::FromHtml($Border)
        $b.FlatAppearance.BorderSize = $BorderW
        $b.FlatAppearance.MouseOverBackColor = [System.Drawing.ColorTranslator]::FromHtml($Hover)
        $b.FlatAppearance.MouseDownBackColor = [System.Drawing.ColorTranslator]::FromHtml($Hover)
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand
        if ($Font) { $b.Font = $Font } else { $b.Font = $fBtn }
        $Parent.Controls.Add($b)
        return $b
    }

    $script:BtnMenu  = New-Btn -Parent $head -Text '右键菜单' -X 598 -Y 20 -W 88 -H 28 -Fore '#6B7280' -Border '#E4E7EB'
    $script:BtnAdmin = New-Btn -Parent $head -Text '以管理员重启' -X 694 -Y 20 -W 110 -H 28 -Fore '#6B7280' -Border '#E4E7EB'

    $headLine = New-Object System.Windows.Forms.Panel
    $headLine.Location = New-Object System.Drawing.Point(0, 67)
    $headLine.Size = New-Object System.Drawing.Size(820, 1)
    $headLine.BackColor = $cBorder
    $head.Controls.Add($headLine)

    # ================= 选项行 =================
    $optPanel = New-Object System.Windows.Forms.Panel
    $optPanel.Location = New-Object System.Drawing.Point(0, 68)
    $optPanel.Size = New-Object System.Drawing.Size(820, 40)
    $optPanel.BackColor = $cBg
    $script:Form.Controls.Add($optPanel)

    $script:CkUnlock = New-Object System.Windows.Forms.CheckBox
    $script:CkUnlock.Text = '删除失败时解除占用'
    $script:CkUnlock.Checked = $true
    $script:CkUnlock.AutoSize = $true
    $script:CkUnlock.ForeColor = $cText
    $script:CkUnlock.Font = $fBody
    $script:CkUnlock.Location = New-Object System.Drawing.Point(16, 11)
    $optPanel.Controls.Add($script:CkUnlock)

    $script:CkAcl = New-Object System.Windows.Forms.CheckBox
    $script:CkAcl.Text = '删除失败时修复权限'
    $script:CkAcl.Checked = $true
    $script:CkAcl.AutoSize = $true
    $script:CkAcl.ForeColor = $cText
    $script:CkAcl.Font = $fBody
    $script:CkAcl.Location = New-Object System.Drawing.Point(170, 11)
    $optPanel.Controls.Add($script:CkAcl)

    $script:CkConfirm = New-Object System.Windows.Forms.CheckBox
    $script:CkConfirm.Text = '删除前二次确认'
    $script:CkConfirm.Checked = $true
    $script:CkConfirm.AutoSize = $true
    $script:CkConfirm.ForeColor = $cText
    $script:CkConfirm.Font = $fBody
    $script:CkConfirm.Location = New-Object System.Drawing.Point(324, 11)
    $optPanel.Controls.Add($script:CkConfirm)

    # ================= 列表 =================
    $script:ListLabel = New-Object System.Windows.Forms.Label
    $script:ListLabel.Text = '待删除列表（共 0 项）'
    $script:ListLabel.ForeColor = $cMuted
    $script:ListLabel.Font = $fSmall
    $script:ListLabel.AutoSize = $true
    $script:ListLabel.Location = New-Object System.Drawing.Point(17, 114)
    $script:Form.Controls.Add($script:ListLabel)

    $listWrap = New-Object System.Windows.Forms.Panel
    $listWrap.Location = New-Object System.Drawing.Point(16, 136)
    $listWrap.Size = New-Object System.Drawing.Size(608, 232)
    $listWrap.BackColor = $cBorder
    $listWrap.Padding = New-Object System.Windows.Forms.Padding(1)
    $script:Form.Controls.Add($listWrap)

    $script:ListBox = New-Object System.Windows.Forms.ListBox
    $script:ListBox.Dock = 'Fill'
    $script:ListBox.BorderStyle = 'None'
    $script:ListBox.BackColor = $cCard
    $script:ListBox.ForeColor = $cText
    $script:ListBox.Font = $script:FontItem
    $script:ListBox.SelectionMode = 'MultiExtended'
    $script:ListBox.IntegralHeight = $false
    $script:ListBox.DrawMode = 'OwnerDrawFixed'
    $script:ListBox.ItemHeight = 38
    $script:ListBox.AllowDrop = $true
    $listWrap.Controls.Add($script:ListBox)

    # 空列表提示
    $script:EmptyHint = New-Object System.Windows.Forms.Label
    $script:EmptyHint.Dock = 'Fill'
    $script:EmptyHint.BackColor = $cCard
    $script:EmptyHint.TextAlign = 'MiddleCenter'
    $script:EmptyHint.ForeColor = $cFaint
    $script:EmptyHint.Font = $fSub
    $script:EmptyHint.Text = "还没有待删项`r`n`r`n把文件或文件夹拖到这里，`r`n或在资源管理器里右键选择「添加到强制删除列表」"
    $script:EmptyHint.AllowDrop = $true
    $listWrap.Controls.Add($script:EmptyHint)
    $script:EmptyHint.BringToFront()

    # 行绘制
    $script:ListBox.Add_DrawItem({
        param($sender, $e)
        if ($e.Index -lt 0) { return }
        $g = $e.Graphics
        $item = [string]$sender.Items[$e.Index]
        $rc = $e.Bounds
        $sel = (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0)

        $bgHex = '#FFFFFF'
        if ($sel) { $bgHex = '#FDECEA' } elseif ($e.Index -eq $script:HotIndex) { $bgHex = '#F4F6F8' }
        $br = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml($bgHex))
        $g.FillRectangle($br, $rc)
        $br.Dispose()

        if ($sel) {
            $br = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml('#D93025'))
            $g.FillRectangle($br, $rc.X, ($rc.Y + 7), 3, ($rc.Height - 14))
            $br.Dispose()
        }

        $isDir = $false
        try { $isDir = [System.IO.Directory]::Exists($item) } catch { }
        $dotHex = '#9AA4B2'
        if ($isDir) { $dotHex = '#F2994A' }
        $br = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml($dotHex))
        $g.FillEllipse($br, ($rc.X + 14), ($rc.Y + [int](($rc.Height - 6) / 2)), 6, 6)
        $br.Dispose()

        $tagW = 42
        $textRect = New-Object System.Drawing.Rectangle(($rc.X + 30), $rc.Y, ($rc.Width - 30 - $tagW - 14), $rc.Height)
        $flags = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::PathEllipsis -bor [System.Windows.Forms.TextFormatFlags]::SingleLine -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
        $fcHex = '#1F2328'
        if ($sel) { $fcHex = '#A52A1E' }
        [System.Windows.Forms.TextRenderer]::DrawText($g, $item, $script:FontItem, $textRect, [System.Drawing.ColorTranslator]::FromHtml($fcHex), $flags)

        $tag = '文件'
        if ($isDir) { $tag = '文件夹' }
        $tagRect = New-Object System.Drawing.Rectangle(($rc.Right - $tagW - 12), $rc.Y, $tagW, $rc.Height)
        $tagFlags = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::Right -bor [System.Windows.Forms.TextFormatFlags]::SingleLine
        [System.Windows.Forms.TextRenderer]::DrawText($g, $tag, $script:FontTag, $tagRect, [System.Drawing.ColorTranslator]::FromHtml('#9AA4B2'), $tagFlags)
    })

    $script:Tip = New-Object System.Windows.Forms.ToolTip
    $script:Tip.InitialDelay = 700
    $script:Tip.AutoPopDelay = 15000

    $script:ListBox.Add_MouseMove({
        param($sender, $e)
        $idx = $sender.IndexFromPoint($e.X, $e.Y)
        if ($idx -ne $script:HotIndex) {
            $script:HotIndex = $idx
            if ($idx -ge 0 -and $idx -lt $sender.Items.Count) {
                $script:Tip.SetToolTip($sender, [string]$sender.Items[$idx])
            }
            $sender.Invalidate()
        }
    })
    $script:ListBox.Add_MouseLeave({
        param($sender, $e)
        if ($script:HotIndex -ne -1) { $script:HotIndex = -1; $sender.Invalidate() }
    })

    # ================= 右侧操作列 =================
    $side = New-Object System.Windows.Forms.Panel
    $side.Location = New-Object System.Drawing.Point(636, 136)
    $side.Size = New-Object System.Drawing.Size(168, 232)
    $side.BackColor = $cBg
    $script:Form.Controls.Add($side)

    $script:BtnUnlock = New-Btn -Parent $side -Text '解除占用' -X 0 -Y 0 -W 168 -H 44 -Fore '#D93025' -Border '#F0B7B1' -Hover '#FDECEA'

    $script:BtnRemove = New-Btn -Parent $side -Text '移除选中' -X 0 -Y 54 -W 168 -H 38
    $script:BtnClear  = New-Btn -Parent $side -Text '清空列表' -X 0 -Y 100 -W 168 -H 38
    $script:BtnLog    = New-Btn -Parent $side -Text '打开日志' -X 0 -Y 146 -W 168 -H 38

    $sideHint = New-Object System.Windows.Forms.Label
    $sideHint.Text = '「解除占用」只结束占用进程，不删除文件。'
    $sideHint.Font = $fSmall
    $sideHint.ForeColor = $cFaint
    $sideHint.Location = New-Object System.Drawing.Point(2, 190)
    $sideHint.Size = New-Object System.Drawing.Size(164, 42)
    $side.Controls.Add($sideHint)

    # ================= 日志 =================
    $lbLog = New-Object System.Windows.Forms.Label
    $lbLog.Text = '运行日志'
    $lbLog.ForeColor = $cMuted
    $lbLog.Font = $fSmall
    $lbLog.AutoSize = $true
    $lbLog.Location = New-Object System.Drawing.Point(17, 376)
    $script:Form.Controls.Add($lbLog)

    $logWrap = New-Object System.Windows.Forms.Panel
    $logWrap.Location = New-Object System.Drawing.Point(16, 398)
    $logWrap.Size = New-Object System.Drawing.Size(788, 112)
    $logWrap.BackColor = $cBorder
    $logWrap.Padding = New-Object System.Windows.Forms.Padding(1)
    $script:Form.Controls.Add($logWrap)

    $script:LogBox = New-Object System.Windows.Forms.RichTextBox
    $script:LogBox.Dock = 'Fill'
    $script:LogBox.BorderStyle = 'None'
    $script:LogBox.BackColor = $cCard
    $script:LogBox.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#30363D')
    $script:LogBox.Font = $fLog
    $script:LogBox.ReadOnly = $true
    $script:LogBox.WordWrap = $false
    $script:LogBox.DetectUrls = $false
    $logWrap.Controls.Add($script:LogBox)

    # ================= 底部 =================
    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Location = New-Object System.Drawing.Point(0, 510)
    $bottom.Size = New-Object System.Drawing.Size(820, 62)
    $bottom.BackColor = $cCard
    $script:Form.Controls.Add($bottom)

    $botLine = New-Object System.Windows.Forms.Panel
    $botLine.Location = New-Object System.Drawing.Point(0, 0)
    $botLine.Size = New-Object System.Drawing.Size(820, 1)
    $botLine.BackColor = $cBorder
    $bottom.Controls.Add($botLine)

    $script:Status = New-Object System.Windows.Forms.Label
    $script:Status.Text = '就绪'
    $script:Status.ForeColor = $cMuted
    $script:Status.Font = $fSub
    $script:Status.AutoSize = $false
    $script:Status.Size = New-Object System.Drawing.Size(560, 18)
    $script:Status.Location = New-Object System.Drawing.Point(18, 14)
    $bottom.Controls.Add($script:Status)

    $script:Bar = New-Object System.Windows.Forms.ProgressBar
    $script:Bar.Location = New-Object System.Drawing.Point(18, 40)
    $script:Bar.Size = New-Object System.Drawing.Size(560, 5)
    $script:Bar.Style = 'Continuous'
    $bottom.Controls.Add($script:Bar)

    $script:BtnStart = New-Btn -Parent $bottom -Text '开始执行删除' -X 624 -Y 11 -W 180 -H 40 -Back '#D93025' -Fore '#FFFFFF' -Border '#D93025' -BorderW 0 -Hover '#B72A20' -Font $fMain

    # ================= 列表刷新 =================
    $script:Items = @()
    function Refresh-List {
        $items = @(Get-QueueItems)
        $script:ListBox.BeginUpdate()
        $script:ListBox.Items.Clear()
        foreach ($i in $items) { [void]$script:ListBox.Items.Add($i) }
        $script:ListBox.EndUpdate()
        $script:Items = $items
        $script:ListLabel.Text = '待删除列表（共 ' + $items.Count + ' 项，可按住 Ctrl 多选）'
        if ($items.Count -eq 0) {
            $script:EmptyHint.Visible = $true
            $script:EmptyHint.BringToFront()
        } else {
            $script:EmptyHint.Visible = $false
            $script:ListBox.BringToFront()
        }
        $script:QueueStamp = Get-QueueStamp
    }

    function Set-UiEnabled([bool]$On) {
        foreach ($b in @($script:BtnUnlock, $script:BtnRemove, $script:BtnClear, $script:BtnMenu, $script:BtnAdmin, $script:BtnStart, $script:CkUnlock, $script:CkAcl, $script:CkConfirm)) {
            $b.Enabled = $On
        }
        $script:ListBox.Enabled = $On
    }

    function Get-SelectedItems {
        $picked = @()
        foreach ($it in $script:ListBox.SelectedItems) { $picked += [string]$it }
        return $picked
    }

    # ================= 拖拽加入 =================
    $dropHandler = {
        param($sender, $e)
        try {
            $files = $e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
            foreach ($f in $files) { $null = Add-QueuePath -Path ([string]$f) }
        } catch { }
        Refresh-List
    }
    $dragHandler = {
        param($sender, $e)
        if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
        } else {
            $e.Effect = [System.Windows.Forms.DragDropEffects]::None
        }
    }
    $script:ListBox.Add_DragEnter($dragHandler)
    $script:ListBox.Add_DragDrop($dropHandler)
    $script:EmptyHint.Add_DragEnter($dragHandler)
    $script:EmptyHint.Add_DragDrop($dropHandler)
    $script:Form.Add_DragEnter($dragHandler)
    $script:Form.Add_DragDrop($dropHandler)

    # ================= 事件 =================
    $script:BtnRemove.Add_Click({
        if ($script:Busy) { return }
        $picked = @(Get-SelectedItems)
        if ($picked.Count -eq 0) { Write-Log 'ℹ️ 未选中任何项'; return }
        $remain = @()
        foreach ($i in @(Get-QueueItems)) {
            $hit = $false
            foreach ($p in $picked) { if ([string]::Equals($i, $p, [StringComparison]::OrdinalIgnoreCase)) { $hit = $true } }
            if (-not $hit) { $remain += $i }
        }
        Set-QueueItems -Items $remain
        Refresh-List
        foreach ($p in $picked) { Write-Log ('➖ 移除：' + $p) }
    })

    $script:BtnClear.Add_Click({
        if ($script:Busy) { return }
        Set-QueueItems -Items @()
        Refresh-List
        Write-Log '🗑️ 列表已清空'
    })

    $script:BtnLog.Add_Click({ Start-Process explorer.exe -ArgumentList ('/select,"' + $script:LogFile + '"') })

    # 仅解除占用：不删除、不改权限、不改属性
    $script:BtnUnlock.Add_Click({
        if ($script:Busy) { return }
        $picked = @(Get-SelectedItems)
        if ($picked.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('请先在列表中选中要解除占用的项（可按住 Ctrl 多选）。', '解除占用', 'OK', 'Information') | Out-Null
            return
        }

        $script:Busy = $true
        Set-UiEnabled $false
        Write-Log ('══════ 仅解除占用：' + $picked.Count + ' 项（不会删除任何文件）══════')

        $auto = $false
        $killed = 0
        $clean = 0
        $failed = 0
        $modLocked = 0
        $aborted = $false
        $n = 0

        foreach ($it in $picked) {
            $n++
            $script:Status.Text = '解除占用 ' + $n + '/' + $picked.Count + '：' + $it
            Write-Log ('—————————— ' + $it + ' ——————————')
            if (-not (Test-Exists -Path $it)) {
                Write-Log 'ℹ️ 目标已不存在，跳过'
                $failed++
                continue
            }
            $script:KillAll = $auto
            $st = Unlock-Target -Path $it
            if ($st -eq 'killed') { $killed++; $auto = $true }
            elseif ($st -eq 'none') { $clean++ }
            elseif ($st -eq 'module') { $modLocked++ }
            elseif ($st -eq 'blocked') { $failed++ }
            elseif ($st -eq 'abort') { $aborted = $true; break }
            [System.Windows.Forms.Application]::DoEvents()
        }

        $script:KillAll = $false
        $script:Busy = $false
        Set-UiEnabled $true
        $msg = '解除占用完成：结束进程 ' + $killed + ' 项，本来无占用 ' + $clean + ' 项'
        if ($modLocked -gt 0) { $msg += '，被已加载模块锁定 ' + $modLocked + ' 项（需重启才能释放）' }
        $msg += '，未处理 ' + $failed + ' 项'
        if ($aborted) { $msg += '（中途停止）' }
        $script:Status.Text = $msg
        Write-Log ('══════ ' + $msg + ' ══════')
    })

    $script:BtnMenu.Add_Click({
        if (Test-MenuInstalled) {
            if ([System.Windows.Forms.MessageBox]::Show('右键菜单已存在，是否移除？', '右键菜单', 'YesNo', 'Question') -eq 'Yes') {
                Uninstall-Menu
            }
        } else {
            Install-Menu
        }
    })

    $script:BtnAdmin.Add_Click({
        if ($script:Busy) { return }
        try {
            if ($script:HostExe) {
                # 以管理员身份重启 exe；-ForceNew 让新实例等旧实例让出锁，避免抢不到单实例锁直接退出
                Start-Process -FilePath $script:HostExe -Verb RunAs -ArgumentList '-ForceNew' | Out-Null
                $script:Form.Close()
            } else {
                Start-Process -FilePath $script:PsExe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"')
                $script:Form.Close()
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show('提权被取消或失败。', '提示', 'OK', 'Warning') | Out-Null
        }
    })

    $script:BtnStart.Add_Click({
        if ($script:Busy) { return }
        $items = @(Get-QueueItems)
        if ($items.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('列表为空。', '提示', 'OK', 'Information') | Out-Null
            return
        }
        $script:Opt.Unlock  = $script:CkUnlock.Checked
        $script:Opt.FixAcl  = $script:CkAcl.Checked
        $script:Opt.Confirm = $script:CkConfirm.Checked
        if ($script:CkConfirm.Checked) {
            $msg = '即将删除 ' + $items.Count + " 项，删除后不可恢复。`r`n`r`n过程中可能结束占用进程、修改文件权限。是否继续？"
            if ([System.Windows.Forms.MessageBox]::Show($msg, '确认删除', 'YesNo', 'Warning') -ne 'Yes') { return }
        }

        $script:Busy = $true
        $script:KillAll = $false
        $script:RebootAll = $false
        Set-UiEnabled $false
        $script:Bar.Maximum = [Math]::Max(1, $items.Count)
        $script:Bar.Value = 0
        Write-Log ('══════ 开始批量处理，共 ' + $items.Count + ' 项 ══════')

        $done = 0
        $okCount = 0
        $skipCount = 0
        foreach ($it in $items) {
            $done++
            $script:Status.Text = '处理中 ' + $done + '/' + $items.Count + '：' + $it
            Write-Log ('—————————— ' + $it + ' ——————————')
            $ok = $false
            try { $ok = Invoke-ForceDelete -Path $it }
            catch { Write-Log ('❌ 异常：' + $_.Exception.Message) }
            if ($ok) {
                $okCount++
                $remain = @()
                foreach ($q in @(Get-QueueItems)) {
                    if (-not [string]::Equals($q, $it, [StringComparison]::OrdinalIgnoreCase)) { $remain += $q }
                }
                Set-QueueItems -Items $remain
                Refresh-List
            } else {
                $skipCount++
            }
            $script:Bar.Value = [Math]::Min($done, $script:Bar.Maximum)
            [System.Windows.Forms.Application]::DoEvents()
        }

        $script:Busy = $false
        Set-UiEnabled $true
        Refresh-List
        $fail = $items.Count - $okCount
        $script:Status.Text = '完成：成功 ' + $okCount + ' 项，失败 ' + $fail + ' 项'
        Write-Log ('══════ 处理完毕：成功 ' + $okCount + '，失败 ' + $fail + ' ══════')
        if ($fail -gt 0) {
            [System.Windows.Forms.MessageBox]::Show(('有 ' + $fail + ' 项未能删除，详见日志。'), '完成', 'OK', 'Warning') | Out-Null
        }
    })

    $script:Form.Add_FormClosing({
        param($s, $e)
        if ($script:Busy) {
            if ([System.Windows.Forms.MessageBox]::Show('正在处理中，确定退出？', '提示', 'YesNo', 'Warning') -ne 'Yes') {
                $e.Cancel = $true
            }
        }
    })

    # 轮询队列文件：另一个 -Add 进程写入后自动刷新
    $script:Timer = New-Object System.Windows.Forms.Timer
    $script:Timer.Interval = 700
    $script:Timer.Add_Tick({
        if ($script:Busy) { return }
        if ((Get-QueueStamp) -ne $script:QueueStamp) { Refresh-List }
    })

    $script:Form.Add_Shown({
        Refresh-List
        $script:Timer.Start()
        Write-Log ('🪟 界面就绪，句柄=' + $script:Form.Handle + ' 尺寸=' + $script:Form.Width + 'x' + $script:Form.Height)
        if (Test-MenuInstalled) { Write-Log 'ℹ️ 右键菜单已安装' } else { Write-Log 'ℹ️ 未安装右键菜单，可点右上角「右键菜单」安装' }
        $items = @(Get-QueueItems)
        if ($items.Count -gt 0) { Write-Log ('ℹ️ 当前队列 ' + $items.Count + ' 项，待处理') }
        else { Write-Log 'ℹ️ 提示：可把文件直接拖进列表' }
    })

    [void]$script:Form.ShowDialog()
    Write-Log '👋 界面已关闭'
    $script:Timer.Stop()
    $script:Timer.Dispose()
    $script:Form.Dispose()
}


# ========================= 自检 =========================
function Invoke-SelfTest {
    $script:EchoLog = $true
    $script:AskKill = $false
    $script:GuiMode = $false
    function Check([string]$Name, [bool]$Cond) {
        if ($Cond) { $script:t_pass = $script:t_pass + 1; Write-Host ('  [PASS] ' + $Name) -ForegroundColor Green }
        else { $script:t_fail = $script:t_fail + 1; Write-Host ('  [FAIL] ' + $Name) -ForegroundColor Red }
    }
    $script:t_pass = 0
    $script:t_fail = 0

    Write-Host '== CC-DEL 自检 ==' -ForegroundColor Cyan

    # 1 长路径转换
    Check '扩展路径-本地盘' ((ConvertTo-ExtendedPath -Path 'C:\Temp\a.txt') -eq '\\?\C:\Temp\a.txt')
    Check '扩展路径-UNC'   ((ConvertTo-ExtendedPath -Path '\\srv\share\a') -eq '\\?\UNC\srv\share\a')
    Check '扩展路径-幂等' ((ConvertTo-ExtendedPath -Path '\\?\C:\a') -eq '\\?\C:\a')

    # 2 保护名单
    Check '保护-系统盘根' (Test-Protected -Path 'C:\')
    Check '保护-Windows' (Test-Protected -Path $env:SystemRoot)
    Check '放行-系统子目录' (-not (Test-Protected -Path (Join-Path $env:SystemRoot 'Temp')))

    $repo = Join-Path $env:TEMP ('wdel_test_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $repo -Force | Out-Null

    # 3 普通文件
    $f1 = Join-Path $repo 'plain.txt'
    Set-Content -LiteralPath $f1 -Value 'x'
    Check '删除-普通文件' ((Invoke-ForceDelete -Path $f1) -and (-not (Test-Exists -Path $f1)))

    # 4 只读+隐藏+系统
    $f2 = Join-Path $repo 'locked_attr.txt'
    Set-Content -LiteralPath $f2 -Value 'x'
    try { (Get-Item -LiteralPath $f2).Attributes = 'ReadOnly,Hidden,System' } catch { }
    Check '删除-只读隐藏系统' ((Invoke-ForceDelete -Path $f2) -and (-not (Test-Exists -Path $f2)))

    # 5 占用检测
    $f3 = Join-Path $repo 'inuse.txt'
    Set-Content -LiteralPath $f3 -Value 'x'
    $fs = [System.IO.File]::Open($f3, 'Open', 'ReadWrite', 'None')
    $lockers = @()
    try { $lockers = @([CCDEL.Rm]::GetLockers($f3)) } catch { Write-Host ('  RM 异常：' + $_.Exception.Message) -ForegroundColor Yellow }
    Check '解占用-能识别持有进程' ($lockers.Count -gt 0)
    if ($lockers.Count -gt 0) { Write-Host ('        识别到：' + ($lockers -join ', ')) -ForegroundColor DarkGray }
    # 该进程正是自检自身，不会被杀；验证删除失败路径不崩溃
    $r5 = Invoke-ForceDelete -Path $f3
    Check '解占用-锁定文件不误删' ((-not $r5) -and (Test-Exists -Path $f3))
    $fs.Close(); $fs.Dispose()

    # 6 目录树（含只读子项）
    $d1 = Join-Path $repo 'tree'
    $sub = Join-Path $d1 'sub'
    New-Item -ItemType Directory -Path $sub -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $d1 'a.txt') -Value 'a'
    $childFile = Join-Path $sub 'b.txt'
    Set-Content -LiteralPath $childFile -Value 'b'
    try { (Get-Item -LiteralPath $childFile).Attributes = 'ReadOnly,Hidden,System' } catch { }
    Check '删除-目录树含只读子项' ((Invoke-ForceDelete -Path $d1) -and (-not (Test-Exists -Path $d1)))

    # 6b 真实外部进程占用：验证「发现 → 结束 → 删除」整条链路
    $f4 = Join-Path $repo 'hold.txt'
    Set-Content -LiteralPath $f4 -Value 'x'
    $holdCmd = "`$fs=[System.IO.File]::Open('" + ($f4 -replace "'", "''") + "','Open','ReadWrite','None'); Start-Sleep -Seconds 45"
    $holder = $null
    try {
        $holder = Start-Process -FilePath $script:PsExe -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-Command', $holdCmd) -PassThru -WindowStyle Hidden
    } catch { Write-Host ('  占用进程启动失败：' + $_.Exception.Message) -ForegroundColor Yellow }
    Start-Sleep -Milliseconds 2500
    $lk = @(Get-LockerList -Path $f4)
    Check '解占用-发现外部占用进程' ($lk.Count -gt 0)
    if ($lk.Count -gt 0) { Write-Host ('        占用者：' + (($lk | ForEach-Object { $_.Name + '(' + $_.Id + ')' }) -join ', ')) -ForegroundColor DarkGray }
    $oldKillAll = $script:KillAll
    $script:KillAll = $true
    $r6 = Invoke-ForceDelete -Path $f4
    $script:KillAll = $oldKillAll
    Check '解占用-结束后删除成功' ($r6 -and (-not (Test-Exists -Path $f4)))
    if ($holder) { try { if (-not $holder.HasExited) { Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue } } catch { } }

    # 7 超长路径（用扩展路径 API 创建，绕开 PS 的 260 限制）
    $longDir = $repo
    for ($n = 0; $n -lt 6; $n++) { $longDir = Join-Path $longDir ('L' + ('x' * 40)) }
    $extLong = ConvertTo-ExtendedPath -Path $longDir
    try {
        $null = [System.IO.Directory]::CreateDirectory($extLong)
        [System.IO.File]::WriteAllText($extLong + '\deep.txt', 'deep')
    } catch { Write-Host ('  长路径创建失败：' + $_.Exception.Message) -ForegroundColor Yellow }
    Write-Host ('        长路径长度：' + $longDir.Length) -ForegroundColor DarkGray
    Check '删除-超长路径' ((Invoke-ForceDelete -Path $longDir) -and (-not (Test-Exists -Path $longDir)))

    # 7b 保留名文件（nul）：普通接口会当成设备，只有 \\?\ 才认得出是真的文件
    $nulPath = Join-Path $repo 'nul'
    $extNul = ConvertTo-ExtendedPath -Path $nulPath
    try { [System.IO.File]::WriteAllText($extNul, 'nul-test') } catch { Write-Host ('  保留名创建失败：' + $_.Exception.Message) -ForegroundColor Yellow }
    Check '保留名-文件真实存在' ([System.IO.File]::Exists($extNul))
    Check '保留名-识别出保留名' (Test-ReservedName -Path $nulPath)
    Check '保留名-Test-Exists 判为存在' (Test-Exists -Path $nulPath)
    Check '删除-保留名文件' ((Invoke-ForceDelete -Path $nulPath) -and (-not (Test-Exists -Path $nulPath)))

    # 8 队列读写
    $bak = @(Get-QueueItems)
    Set-QueueItems -Items @('C:\a.txt', 'C:\b c.txt')
    Check '队列-写入读取' ((@(Get-QueueItems).Count) -eq 2)
    Set-QueueItems -Items $bak

    Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host ('结果：通过 ' + $script:t_pass + ' 项，失败 ' + $script:t_fail + ' 项') -ForegroundColor Cyan
    if ($script:t_fail -gt 0) { exit 1 } else { exit 0 }
}

# ========================= 入口分发 =========================
# -Probe：只做占用体检，不删任何东西。用来回答"为什么删不掉"。
if ($Probe) {
    Write-Host ('路径：' + $Probe)
    if (-not (Test-Exists -Path $Probe)) { Write-Host '状态：不存在'; exit 0 }
    if (Test-IsDirectory -Path $Probe) { Write-Host '类型：文件夹' } else { Write-Host '类型：文件' }
    if (Test-ReservedName -Path $Probe) {
        Write-Host '注意：这是 Windows 保留名文件（nul/con/aux 等）。'
        Write-Host '      普通接口会把它解析成设备而不是文件，必须走 \\?\ 字面路径才能读写删。'
    }

    $rm = @(Get-LockerList -Path $Probe)
    if ($rm.Count -eq 0) {
        Write-Host '句柄占用：无'
    } else {
        Write-Host ('句柄占用：' + (($rm | ForEach-Object { $_.Name + '(' + $_.Id + ')' }) -join '、'))
    }

    $mods = @(Get-ModuleLocker -Path $Probe)
    if ($mods.Count -eq 0) {
        Write-Host '模块锁定：无'
    } else {
        Write-Host ('模块锁定：' + (($mods | ForEach-Object { $_.Name + '(' + $_.Id + ')' }) -join '、'))
        Write-Host ('            ' + (($mods | ForEach-Object { $_.Module }) | Select-Object -First 1))
        Write-Host '结论：文件已被加载进进程，属于映像节锁定，结束进程后通常仍需重启才能删除。'
    }
    exit 0
}

# -Pending：直接登记「重启后删除」，不弹界面。需要管理员权限。
if ($Pending) {
    Write-Host ('登记重启后删除：' + $Pending)
    if (Add-PendingDelete -Path $Pending) { Write-Host '结果：已登记，下次开机会自动清除' }
    else { Write-Host '结果：登记失败' }
    exit 0
}

if ($Install)   { Install-Menu; exit 0 }
if ($Uninstall) { Uninstall-Menu; exit 0 }
if ($SelfTest)  { Invoke-SelfTest }

if ($Add) {
    $null = Add-QueuePath -Path $Add
    $running = $false
    try { $null = [System.Threading.Mutex]::OpenExisting($script:MutexName); $running = $true } catch { $running = $false }
    if (-not $running) {
        if ($script:HostExe) {
            Start-Process -FilePath $script:HostExe | Out-Null
        } else {
            $argLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '"'
            Start-Process -FilePath $script:PsExe -ArgumentList $argLine | Out-Null
        }
    }
    exit 0
}

# 单实例：抢到互斥体才显示窗口
$createdNew = $false
$script:Mtx = New-Object System.Threading.Mutex($true, $script:MutexName, [ref]$createdNew)
if (-not $createdNew) { exit 0 }
try { Show-MainWindow } finally {
    try { $script:Mtx.ReleaseMutex() } catch { }
    try { $script:Mtx.Dispose() } catch { }
}
