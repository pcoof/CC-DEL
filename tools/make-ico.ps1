# ============================================================
#  把一张正方形 PNG 转成 Windows 多尺寸 .ico
#
#  为什么要多尺寸：只有一个 256x256 的 ico 在资源管理器"大图标"里看着正常，
#  但列表视图(16)、任务栏(32)、标题栏(16) 全靠系统自己缩小，糊得厉害，
#  个别位置干脆显示空白。真正好用的 ico 要把 16/24/32/48/64/128/256 都备齐。
#
#  用法：
#    pwsh -File tools/make-ico.ps1 -Png my-logo.png -Out src/logo.ico
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Png,
    [string]$Out = "logo.ico",
    # 256 用 PNG 压缩（Vista 以后的标准做法），其余用 BMP(DIB)
    [int[]]$Sizes = @(16, 24, 32, 48, 64, 128, 256)
)

Add-Type -AssemblyName System.Drawing

# 32bpp 位图 -> ICON 里的 BMP 条目：BITMAPINFOHEADER + 自下而上的 BGRA + AND 掩码
function ConvertTo-Dib {
    param([System.Drawing.Bitmap]$Bitmap)

    $w = $Bitmap.Width
    $h = $Bitmap.Height
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)

    # BITMAPINFOHEADER：高度要写成 2 倍（XOR 图 + AND 掩码）
    $bw.Write([uint32]40)
    $bw.Write([int32]$w)
    $bw.Write([int32]($h * 2))
    $bw.Write([uint16]1)
    $bw.Write([uint16]32)
    $bw.Write([uint32]0)                 # BI_RGB
    $bw.Write([uint32]($w * $h * 4))
    $bw.Write([int32]0); $bw.Write([int32]0)
    $bw.Write([uint32]0); $bw.Write([uint32]0)

    # 像素：GDI 位图从下往上存
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $bd = $Bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $stride = $bd.Stride
        $buf = New-Object byte[] ($stride * $h)
        [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $buf, 0, $buf.Length)
        for ($y = $h - 1; $y -ge 0; $y--) {
            $bw.Write($buf, ($y * $stride), ($w * 4))
        }
    } finally {
        $Bitmap.UnlockBits($bd)
    }

    # AND 掩码：32bpp 下不参与透明判断，但格式要求必须存在，全 0
    $maskStride = [int]([Math]::Floor(($w + 31) / 32) * 4)
    $bw.Write((New-Object byte[] ($maskStride * $h)))

    $bw.Flush()
    $out = $ms.ToArray()
    $bw.Dispose(); $ms.Dispose()
    # 前置逗号：PowerShell 会把函数返回的数组"展开"成 Object[]，
    # 后面 $bw.Write($objArray) 会绑定到 Write(char)，只写进 1 个字节。
    # 必须原样返回 byte[]。
    return , $out
}

if (-not (Test-Path -LiteralPath $Png)) { throw "找不到：$Png" }

$src = [System.Drawing.Image]::FromFile((Resolve-Path $Png).Path)
try {
    if ($src.Width -ne $src.Height) { throw "源图必须是正方形，当前 $($src.Width)x$($src.Height)" }
    if ($src.Width -lt 256) { Write-Output ("[提示] 源图只有 " + $src.Width + "px，256 尺寸会被拉伸") }

    $frames = @()
    foreach ($s in ($Sizes | Sort-Object)) {
        $bmp = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.DrawImage($src, 0, 0, $s, $s)
        $g.Dispose()

        if ($s -ge 256) {
            $ms = New-Object System.IO.MemoryStream
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $data = $ms.ToArray()
            $ms.Dispose()
        } else {
            $data = ConvertTo-Dib -Bitmap $bmp
        }
        $bmp.Dispose()
        $frames += [pscustomobject]@{ Size = $s; Data = $data }
    }

    # ---- 写 ICO ----
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([uint16]0)                 # reserved
    $bw.Write([uint16]1)                 # type = icon
    $bw.Write([uint16]$frames.Count)

    $offset = 6 + 16 * $frames.Count
    foreach ($f in $frames) {
        $dim = if ($f.Size -ge 256) { 0 } else { $f.Size }   # 256 在目录里记作 0
        $bw.Write([byte]$dim)
        $bw.Write([byte]$dim)
        $bw.Write([byte]0)               # 调色板颜色数
        $bw.Write([byte]0)               # reserved
        $bw.Write([uint16]1)             # planes
        $bw.Write([uint16]32)            # bpp
        $bw.Write([uint32]$f.Data.Length)
        $bw.Write([uint32]$offset)
        $offset += $f.Data.Length
    }
    foreach ($f in $frames) { $bw.Write([byte[]]$f.Data) }
    $bw.Flush()

    # 校验：目录里声明的总长度必须和实际写出的字节数一致，否则生成的是个残废 ico
    $expected = $offset
    if ($ms.Length -ne $expected) {
        throw "ICO 写出长度异常：实际 $($ms.Length) 字节，应为 $expected 字节"
    }

    $target = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path (Get-Location).Path $Out }
    $dir = Split-Path -Parent $target
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllBytes($target, $ms.ToArray())
    $bw.Dispose(); $ms.Dispose()

    $fi = Get-Item -LiteralPath $target
    Write-Output ("已生成：" + $fi.FullName + "  " + $fi.Length + " 字节  尺寸：" + (($frames | ForEach-Object { $_.Size }) -join '/'))
} finally {
    $src.Dispose()
}
