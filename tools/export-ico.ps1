# ============================================================
#  从任意 exe / dll 里把图标组原样导成 .ico（不缩放、不重绘）
#
#  为什么不用 Icon 构造函数 / ExtractIconEx：
#    它们最多给你 32 或 48 像素，256 会糊，而且只返回"一张图"。
#  这里直接读 PE 的 RT_GROUP_ICON，把它的每一帧 RT_ICON 原始数据
#  原封不动拼成一个标准 .ico —— 16/32/48/256 各用各的原图，
#  资源管理器在每种视图下都是清晰的。
#
#  用法：
#    pwsh -File tools/export-ico.ps1 -Source C:\Windows\...\powershell.exe -List
#    pwsh -File tools/export-ico.ps1 -Source ... -Out src\logo.ico
#    pwsh -File tools/export-ico.ps1 -Source ... -Out x.ico -Group 1
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [string]$Out = "",
    [int]$Group = 0,
    [switch]$List
)

if (-not (Test-Path -LiteralPath $Source)) { throw "找不到：$Source" }
$Source = (Resolve-Path -LiteralPath $Source).Path

if (-not ('CCDELIco.Extractor' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

namespace CCDELIco
{
    public static class Extractor
    {
        private const uint LOAD_LIBRARY_AS_DATAFILE = 0x00000002;
        private const int RT_ICON = 3;
        private const int RT_GROUP_ICON = 14;

        private delegate bool EnumProc(IntPtr h, IntPtr type, IntPtr name, IntPtr param);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibraryExW(string file, IntPtr reserved, uint flags);
        [DllImport("kernel32.dll")]
        private static extern bool FreeLibrary(IntPtr h);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern bool EnumResourceNamesW(IntPtr h, IntPtr type, EnumProc cb, IntPtr param);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindResourceW(IntPtr h, IntPtr name, IntPtr type);
        [DllImport("kernel32.dll")]
        private static extern IntPtr LoadResource(IntPtr h, IntPtr res);
        [DllImport("kernel32.dll")]
        private static extern IntPtr LockResource(IntPtr data);
        [DllImport("kernel32.dll")]
        private static extern uint SizeofResource(IntPtr h, IntPtr res);

        private static byte[] Read(IntPtr h, IntPtr name, int type)
        {
            IntPtr res = FindResourceW(h, name, (IntPtr)type);
            if (res == IntPtr.Zero) return null;
            uint size = SizeofResource(h, res);
            if (size == 0) return null;
            IntPtr p = LockResource(LoadResource(h, res));
            if (p == IntPtr.Zero) return null;
            byte[] buf = new byte[size];
            Marshal.Copy(p, buf, 0, (int)size);
            return buf;
        }

        /// 枚举所有图标组，返回每组的原始 GRPICONDIR 数据。
        /// 必须在 EnumResourceNames 回调里立刻把数据拷出来：资源名指针
        /// 只在回调期间有效，存下来下次再用会读到垃圾（表现为"读取失败"）。
        private static List<byte[]> LoadGroups(IntPtr h)
        {
            List<byte[]> groups = new List<byte[]>();
            EnumResourceNamesW(h, (IntPtr)RT_GROUP_ICON, delegate (IntPtr m, IntPtr t, IntPtr name, IntPtr p)
            {
                byte[] blob = Read(m, name, RT_GROUP_ICON);
                if (blob != null) groups.Add(blob);
                return true;
            }, IntPtr.Zero);
            return groups;
        }

        /// 返回每个图标组的帧数描述，例如 "组0: 16x16/32x32/48x48/256x256"
        public static string[] Describe(string path)
        {
            IntPtr h = LoadLibraryExW(path, IntPtr.Zero, LOAD_LIBRARY_AS_DATAFILE);
            if (h == IntPtr.Zero) throw new Exception("无法加载：" + path);
            try
            {
                List<byte[]> groups = LoadGroups(h);
                string[] result = new string[groups.Count];
                for (int g = 0; g < groups.Count; g++)
                {
                    byte[] grp = groups[g];
                    int count = BitConverter.ToUInt16(grp, 4);
                    List<string> frames = new List<string>();
                    for (int i = 0; i < count; i++)
                    {
                        int off = 6 + i * 14;
                        int w = grp[off] == 0 ? 256 : grp[off];
                        int hh = grp[off + 1] == 0 ? 256 : grp[off + 1];
                        int bpp = BitConverter.ToUInt16(grp, off + 6);
                        frames.Add(w + "x" + hh + "@" + bpp);
                    }
                    result[g] = "组" + g + "（" + count + " 帧）: " + string.Join(" / ", frames.ToArray());
                }
                return result;
            }
            finally { FreeLibrary(h); }
        }

        /// 把第 index 个图标组导出成标准 .ico 字节流
        public static byte[] Export(string path, int index)
        {
            IntPtr h = LoadLibraryExW(path, IntPtr.Zero, LOAD_LIBRARY_AS_DATAFILE);
            if (h == IntPtr.Zero) throw new Exception("无法加载：" + path);
            try
            {
                List<byte[]> groups = LoadGroups(h);
                if (groups.Count == 0) throw new Exception("这个文件里没有 RT_GROUP_ICON（没有图标资源）");
                if (index < 0 || index >= groups.Count) index = 0;

                byte[] grp = groups[index];
                int count = BitConverter.ToUInt16(grp, 4);
                List<byte[]> heads = new List<byte[]>();
                List<byte[]> data = new List<byte[]>();

                for (int i = 0; i < count; i++)
                {
                    int off = 6 + i * 14;
                    byte[] head = new byte[8];
                    Array.Copy(grp, off, head, 0, 8);      // bWidth..wBitCount
                    ushort id = BitConverter.ToUInt16(grp, off + 12);
                    byte[] frame = Read(h, (IntPtr)id, RT_ICON);
                    if (frame == null) throw new Exception("第 " + i + " 帧（id=" + id + "）读取失败");
                    heads.Add(head);
                    data.Add(frame);
                }

                MemoryStream ms = new MemoryStream();
                BinaryWriter bw = new BinaryWriter(ms);
                bw.Write((ushort)0);            // idReserved
                bw.Write((ushort)1);            // idType = icon
                bw.Write((ushort)count);
                int offset = 6 + count * 16;
                for (int i = 0; i < count; i++)
                {
                    bw.Write(heads[i]);                     // 8 字节：宽/高/色数/保留/平面/位深
                    bw.Write((uint)data[i].Length);         // dwBytesInRes
                    bw.Write((uint)offset);                 // dwImageOffset
                    offset += data[i].Length;
                }
                for (int i = 0; i < count; i++) bw.Write(data[i]);
                bw.Flush();
                byte[] ico = ms.ToArray();
                bw.Dispose(); ms.Dispose();
                return ico;
            }
            finally { FreeLibrary(h); }
        }
    }
}
'@
}

$info = [CCDELIco.Extractor]::Describe($Source)
if ($info.Count -eq 0) {
    Write-Output ("$Source 里没有任何图标组")
    exit 1
}

Write-Output ("来源: " + (Split-Path -Leaf $Source))
foreach ($line in $info) { Write-Output ("  " + $line) }

if ($List -or -not $Out) { exit 0 }

$bytes = [CCDELIco.Extractor]::Export($Source, $Group)
if ($null -eq $bytes -or $bytes.Length -lt 22) { throw "导出失败：拿到的图标数据为空" }

$target = $Out
if (-not [System.IO.Path]::IsPathRooted($target)) { $target = Join-Path (Get-Location).Path $target }
$target = [System.IO.Path]::GetFullPath($target)
$dir = Split-Path -Parent $target
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[System.IO.File]::WriteAllBytes($target, $bytes)
Write-Output ("已导出: " + $target + "（" + $bytes.Length + " 字节）")
