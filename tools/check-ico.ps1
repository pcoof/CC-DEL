# 把 ico 里的每个尺寸都导出来看看，确认图标本身是什么、格式能不能被 .NET 接受
param([string]$Ico, [string]$OutDir = "$env:TEMP\ico_frames")
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path -LiteralPath $Ico)) { throw "找不到：$Ico" }
# 注意：.NET 的文件 API 用的是进程工作目录，不是 PowerShell 的当前路径，
# 相对路径必须先 Resolve-Path 成绝对路径，否则会去错目录找文件。
$Ico = (Resolve-Path -LiteralPath $Ico).Path
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

$bytes = [System.IO.File]::ReadAllBytes($Ico)
$count = [BitConverter]::ToUInt16($bytes, 4)
Write-Output ("ICO 条目数: " + $count + "，文件 " + $bytes.Length + " 字节")

for ($i = 0; $i -lt $count; $i++) {
    $off = 6 + $i * 16
    $w = $bytes[$off]; if ($w -eq 0) { $w = 256 }
    $h = $bytes[$off + 1]; if ($h -eq 0) { $h = 256 }
    $bpp = [BitConverter]::ToUInt16($bytes, $off + 6)
    $size = [BitConverter]::ToUInt32($bytes, $off + 8)
    $pos = [BitConverter]::ToUInt32($bytes, $off + 12)
    $isPng = ($bytes[$pos] -eq 0x89 -and $bytes[$pos + 1] -eq 0x50)
    Write-Output ("  #$i  ${w}x${h}  ${bpp}bpp  ${size}字节  偏移=$pos  " + $(if ($isPng) { 'PNG压缩' } else { 'BMP(DIB)' }))

    # 单独抠出来存成 png 方便肉眼看
    try {
        if ($isPng) {
            $ms = New-Object System.IO.MemoryStream(,$bytes[$pos..($pos + $size - 1)])
            $img = [System.Drawing.Image]::FromStream($ms)
            $img.Save((Join-Path $OutDir ("frame_${w}x${h}.png")), [System.Drawing.Imaging.ImageFormat]::Png)
            $img.Dispose(); $ms.Dispose()
        }
    } catch { Write-Output ("    抠图失败：" + $_.Exception.Message) }
}

# System.Drawing.Icon 能不能吃下整个文件（程序运行时要靠它设窗口/任务栏图标）
try {
    $icon = New-Object System.Drawing.Icon($Ico)
    $bmp = $icon.ToBitmap()
    Write-Output ("System.Drawing.Icon 加载成功，默认取到 " + $bmp.Width + "x" + $bmp.Height)
    $bmp.Save((Join-Path $OutDir 'dotnet_default.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose(); $icon.Dispose()
} catch {
    Write-Output ("System.Drawing.Icon 加载失败：" + $_.Exception.Message)
}
Write-Output ("导出目录：" + $OutDir)
