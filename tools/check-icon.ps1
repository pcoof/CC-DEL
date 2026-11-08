# ============================================================
#  检查一个 exe 里到底有没有图标资源
#
#  ExtractAssociatedIcon 不可靠：图标缺失时它也会返回一个"通用程序图标"，
#  看起来有值，其实 PE 里什么都没有。这里直接读 PE 资源目录：
#    RT_ICON       = 3   单张位图
#    RT_GROUP_ICON = 14  图标组（资源管理器取的就是它）
#
#  用法：
#    pwsh -File tools/check-icon.ps1 -Exe CC-DEL.exe
#  退出码：0 = 有图标；1 = 没有图标或读不到
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$DumpPng = ""
)

if (-not (Test-Path -LiteralPath $Exe)) { throw "找不到：$Exe" }
$Exe = (Resolve-Path -LiteralPath $Exe).Path

if (-not ('CCDELRes.Pe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CCDELRes
{
    public static class Pe
    {
        private const uint LOAD_LIBRARY_AS_DATAFILE = 0x00000002;
        private const int RT_ICON = 3;
        private const int RT_GROUP_ICON = 14;

        private delegate bool EnumProc(IntPtr hModule, IntPtr type, IntPtr name, IntPtr param);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibraryExW(string file, IntPtr reserved, uint flags);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool FreeLibrary(IntPtr hModule);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool EnumResourceNamesW(IntPtr hModule, IntPtr type, EnumProc cb, IntPtr param);

        private static int Count(IntPtr hModule, int type)
        {
            int n = 0;
            EnumResourceNamesW(hModule, (IntPtr)type, delegate (IntPtr m, IntPtr t, IntPtr name, IntPtr p)
            {
                n++;
                return true;
            }, IntPtr.Zero);
            return n;
        }

        /// 返回 [图标组数, 单张图标数]；打不开文件返回 [-1, -1]
        public static int[] IconStats(string path)
        {
            IntPtr h = LoadLibraryExW(path, IntPtr.Zero, LOAD_LIBRARY_AS_DATAFILE);
            if (h == IntPtr.Zero) return new int[] { -1, -1 };
            try { return new int[] { Count(h, RT_GROUP_ICON), Count(h, RT_ICON) }; }
            finally { FreeLibrary(h); }
        }
    }
}
'@
}

$stats = [CCDELRes.Pe]::IconStats($Exe)
if ($stats[0] -lt 0) {
    Write-Output "读不到 PE 资源（文件可能被占用或不是有效 exe）"
    exit 1
}

$fi = Get-Item -LiteralPath $Exe
Write-Output ("文件: " + $fi.Name + "  " + $fi.Length + " 字节")
Write-Output ("RT_GROUP_ICON（图标组）: " + $stats[0])
Write-Output ("RT_ICON（单张图标）    : " + $stats[1])

# 子系统：2 = GUI（不弹控制台），3 = Console（双击会带一个黑窗）
$subsystem = 0
try {
    $fs = [System.IO.File]::OpenRead($Exe)
    $br = New-Object System.IO.BinaryReader($fs)
    $fs.Position = 0x3C
    $peOff = $br.ReadInt32()
    $fs.Position = $peOff + 0x5C          # OptionalHeader.Subsystem
    $subsystem = $br.ReadUInt16()
    $br.Dispose(); $fs.Dispose()
} catch { }
$subText = switch ($subsystem) {
    2 { 'Windows GUI（不弹控制台）' }
    3 { 'Windows Console（会带黑窗）' }
    default { "未知($subsystem)" }
}
Write-Output ("子系统: " + $subText)

$bad = @()
if ($stats[0] -eq 0) { $bad += "没有图标资源 —— rsrc.syso 没参与链接" }
if ($subsystem -eq 3) { $bad += "是控制台子系统 —— 编译时漏了 -H windowsgui" }

if ($bad.Count -gt 0) {
    foreach ($b in $bad) { Write-Output ("问题: " + $b) }
    exit 1
}

if ($DumpPng) {
    Add-Type -AssemblyName System.Drawing
    $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($Exe)
    if ($ico) {
        $bmp = $ico.ToBitmap()
        $bmp.Save($DumpPng, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-Output ("图标已导出: " + $DumpPng + "（" + $bmp.Width + "x" + $bmp.Height + "）")
        $bmp.Dispose(); $ico.Dispose()
    }
}

Write-Output "结论: 图标资源正常"
exit 0
