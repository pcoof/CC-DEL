# ============================================================
#  CC-DEL 截图脚本（生成 README 用的界面图）
#
#  用法：
#    pwsh -File tools/screenshot.ps1 -Out docs/screenshot.png [-ProcessId 1234]
#
#  原理：窗口是 WinForms 画的，用 PrintWindow + PW_RENDERFULLCONTENT 抓窗口位图。
#        比截全屏干净：不会被别的窗口盖住，也不会拍到桌面上的杂物。
# ============================================================
param(
    [string]$Exe    = (Join-Path (Split-Path -Parent $PSScriptRoot) 'CC-DEL.exe'),
    [string]$Out    = (Join-Path (Split-Path -Parent $PSScriptRoot) 'docs\screenshot.png'),
    [string]$Title  = 'CC-DEL 强制删除工具',
    [int]$ProcessId = 0,
    [int]$TimeoutMs = 20000
)

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

if (-not ('CCDELShot.Win' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace CCDELShot
{
    public static class Win
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct RECT { public int Left, Top, Right, Bottom; }

        private delegate bool EnumProc(IntPtr h, IntPtr l);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowTextLengthW(IntPtr h);
        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")]
        public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr FindWindowW(string cls, string name);

        public const uint WM_CLOSE = 0x0010;
        public const uint PW_RENDERFULLCONTENT = 0x00000002;

        // 按标题"包含"匹配，避免标题里多个空格/全角半角差异导致精确匹配失败
        public static IntPtr FindByTitle(string title)
        {
            IntPtr found = IntPtr.Zero;
            EnumWindows(delegate (IntPtr h, IntPtr l)
            {
                if (!IsWindowVisible(h)) return true;
                int n = GetWindowTextLengthW(h);
                if (n <= 0) return true;
                StringBuilder sb = new StringBuilder(n + 2);
                GetWindowTextW(h, sb, sb.Capacity);
                string t = sb.ToString();
                if (t.IndexOf(title, StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    found = h;
                    return false;
                }
                return true;
            }, IntPtr.Zero);
            return found;
        }
    }
}
'@
}

# 等窗口出现（界面进程是 powershell/pwsh 宿主，从启动到 Form.Shown 有一段准备时间）
$hwnd = [IntPtr]::Zero
$deadline = [Environment]::TickCount + $TimeoutMs
while ([Environment]::TickCount -lt $deadline) {
    if ($ProcessId -gt 0) {
        $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) { $hwnd = $p.MainWindowHandle }
    }
    if ($hwnd -eq [IntPtr]::Zero) { $hwnd = [CCDELShot.Win]::FindByTitle($Title) }
    if ($hwnd -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 250
}
if ($hwnd -eq [IntPtr]::Zero) { throw "等不到窗口：$Title" }

# 刚显示时可能还在布局，稍等再抓，避免拍到半透明/未排版状态
Start-Sleep -Milliseconds 1200
[void][CCDELShot.Win]::SetForegroundWindow($hwnd)
Start-Sleep -Milliseconds 500

$r = New-Object CCDELShot.Win+RECT
[void][CCDELShot.Win]::GetWindowRect($hwnd, [ref]$r)
$w = $r.Right - $r.Left
$h = $r.Bottom - $r.Top
if ($w -le 0 -or $h -le 0) { throw "窗口尺寸异常：$w x $h" }

$bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
$ok = [CCDELShot.Win]::PrintWindow($hwnd, $hdc, [CCDELShot.Win]::PW_RENDERFULLCONTENT)
$g.ReleaseHdc($hdc)
$g.Dispose()

if (-not $ok) {
    # 个别显卡驱动/远程桌面下 PrintWindow 会失败，退回屏幕抓取
    $bmp.Dispose()
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g2 = [System.Drawing.Graphics]::FromImage($bmp)
    $g2.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
    $g2.Dispose()
}

$dir = Split-Path -Parent $Out
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

# 裁掉不可见的透明边框。
# Windows 10/11 的 GetWindowRect 比"看得见的那圈"大 8px 左右（左边和底边），
# PrintWindow 抓到的这部分是纯黑。判定方式：整列/整行全黑就认为是可以裁掉的边。
function Is-BlackPixel([System.Drawing.Color]$c) { return ($c.R -lt 14 -and $c.G -lt 14 -and $c.B -lt 14) }

function Test-ColumnBlack($bitmap, [int]$x) {
    # 只在客户区取样：标题栏横贯整宽，从 y=0 判断会永远得出"不是黑边"
    $from = [int]($bitmap.Height * 0.25)
    for ($y = $from; $y -lt $bitmap.Height; $y += 6) {
        if (-not (Is-BlackPixel $bitmap.GetPixel($x, $y))) { return $false }
    }
    return (Is-BlackPixel $bitmap.GetPixel($x, $bitmap.Height - 1))
}

function Test-RowBlack($bitmap, [int]$y) {
    $from = [int]($bitmap.Width * 0.25)
    for ($x = $from; $x -lt $bitmap.Width; $x += 6) {
        if (-not (Is-BlackPixel $bitmap.GetPixel($x, $y))) { return $false }
    }
    return (Is-BlackPixel $bitmap.GetPixel(($bitmap.Width - 1), $y))
}

$left = 0; while ($left -lt 20 -and (Test-ColumnBlack $bmp $left)) { $left++ }
$right = 0; while ($right -lt 20 -and (Test-ColumnBlack $bmp ($w - 1 - $right))) { $right++ }
$top = 0; while ($top -lt 20 -and (Test-RowBlack $bmp $top)) { $top++ }
$bottom = 0; while ($bottom -lt 20 -and (Test-RowBlack $bmp ($h - 1 - $bottom))) { $bottom++ }

$nw = $w - $left - $right
$nh = $h - $top - $bottom
if (($left + $right + $top + $bottom) -gt 0 -and $nw -gt 120 -and $nh -gt 120) {
    $crop = New-Object System.Drawing.Bitmap($nw, $nh, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $gc = [System.Drawing.Graphics]::FromImage($crop)
    $srcRect = New-Object System.Drawing.Rectangle($left, $top, $nw, $nh)
    $dstRect = New-Object System.Drawing.Rectangle(0, 0, $nw, $nh)
    $gc.DrawImage($bmp, $dstRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
    $gc.Dispose()
    $bmp.Dispose()
    $bmp = $crop
    $w = $nw
    $h = $nh
}

$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

Write-Output ("已保存：" + (Resolve-Path $Out) + "  " + $w + "x" + $h)
