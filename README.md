<p align="center">
  <img src="docs/logo.png" width="96" height="96" alt="CC-DEL logo">
</p>

<h1 align="center">CC-DEL</h1>

<p align="center">
  <strong>Windows 强制删除工具 · 单文件 · 免安装</strong>
</p>

<p align="center">
  先把占用者找出来，再动手删。<br>
  删不掉的文件，九成不是「没有权限」，<br>
  而是「有人正拿着它」——或者它的名字根本不合法。
</p>

<p align="center">
  <sub>Windows 10 / 11 · 64 位 · 仅依赖系统自带组件</sub>
</p>

<p align="center">
  <a href="https://github.com/pcoof/CC-DEL/actions/workflows/build.yml"><img src="https://github.com/pcoof/CC-DEL/actions/workflows/build.yml/badge.svg" alt="build"></a>
  <a href="https://github.com/pcoof/CC-DEL/releases"><img src="https://img.shields.io/github/v/release/pcoof/CC-DEL?color=4c1" alt="release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/pcoof/CC-DEL?color=8250df" alt="license"></a>
</p>

<p align="center">
  <img src="docs/screenshot.png" width="760" alt="CC-DEL 主界面">
</p>

---

## 这东西解决什么

资源管理器说「文件正在使用中」，你打开任务管理器翻了一圈，也不知道是谁在用。
更烦的是结束了进程、改了权限、清了只读，它还是一句 `拒绝访问`。

CC-DEL 把这件事拆成两条线索：

| 线索 | 现象 | 处理方式 |
| --- | --- | --- |
| **句柄占用** | 进程开着这个文件的句柄 | 结束进程，句柄随之释放，立刻能删 |
| **映像锁定** | DLL 被加载进了进程，**没有句柄** | 结束进程也未必释放，通常只能等重启 |

第二条是关键。被 `LoadLibrary` 加载的 DLL 不持有文件句柄，所以任务管理器、`handle.exe`、
甚至系统自带的 Restart Manager 都查不到它——但文件照样删不掉。
CC-DEL 会遍历所有进程的**模块列表**，把「谁把它加载进去了」直接点出来。

## 功能

- **渐进式删除**，只在前一步失败时才动下一步，绝不无脑改权限：
  1. 直接删（`.NET` / Win32）
  2. 清属性（只读 / 隐藏 / 系统）
  3. 解除占用（Restart Manager → 逐个结束持有者）
  4. 修权限（`takeown` + `icacls`，仅在必要时）
  5. 强力兜底（`robocopy` 空目录镜像 / `cmd del`）
  6. 还是不行 → 登记**重启后自动删除**（`PendingFileRenameOperations`）
- **只解除占用**：只结束占用进程，不删文件、不改权限，保留现场自己判断。
- **右键菜单带图标**：文件和文件夹右键「添加到强制删除列表」，毫秒级入队后拉起界面。
- **保留名文件**：`nul`、`con`、`aux`、`com1`… 这类 Windows 拒绝创建也拒绝删除的名字，
  走 `\\?\` 扩展路径按字面处理，删得掉。
- **超长路径 / 目录树**：超过 260 字符照样处理，目录里的 DLL 被锁也能递归查到。
- **单实例**：重复双击只激活已有窗口，不会开一堆。
- **自带自检**：`CC-DEL.exe -SelfTest` 跑 19 项回归测试，全绿才算能用。

## 快速开始

### 1. 下载

到 [Releases](https://github.com/pcoof/CC-DEL/releases) 下载 `CC-DEL.exe`，放到任意目录，双击即可。

单文件、免安装、不需要 .NET 运行时——脚本和图标都内嵌在 exe 里，首次运行会释放到
`%LOCALAPPDATA%\CC-DEL\`，之后复用。

### 2. 装右键菜单（可选）

界面右上角点「右键菜单」，或者命令行：

```bat
CC-DEL.exe -Install
```

装好后在文件 / 文件夹上右键，会看到带图标的 **添加到强制删除列表**：

```
右键 → 添加到强制删除列表   ← 图标取自 CC-DEL.exe 自身资源
```

> 想换成自己电脑上的路径，重新安装一次即可；换路径后菜单里的命令和图标会一起更新。
> 卸载：`CC-DEL.exe -Uninstall`

### 3. 用

把文件/文件夹拖进列表（或右键加入）→ 勾选需要的选项 → 点「开始执行删除」。

- 只想知道谁锁着它 → 选中后点右侧 **解除占用**（或 `-Probe`），不删任何东西。
- 提示需要重启才能删 → 同意登记，下次开机会被系统清除。

## 命令行

| 参数 | 作用 |
| --- | --- |
| *(无参数)* | 打开图形界面 |
| `-Add "路径"` | 加入待删列表；界面没开就顺手拉起（右键菜单用的就是它） |
| `-Install` | 安装右键菜单（写 `HKCU`，免管理员） |
| `-Uninstall` | 移除右键菜单 |
| `-SelfTest` | 跑 19 项自检并输出结果 |
| `-Probe "路径"` | **只查不删**，回答「到底谁锁着它」，区分句柄占用 / 映像锁定 |
| `-Pending "路径"` | 登记为重启后删除，立即返回 |

```bat
CC-DEL.exe -Probe "C:\Program Files\Windhawk\temp\windhawk.dll"
CC-DEL.exe -Pending "C:\Windows\System32\drivers\xxx.sys"
```

## 为什么它能删掉别人删不掉的东西

**Restart Manager 只认句柄。** 系统给的 `RmRegisterResources` + `RmGetList` 能查到
「谁开着这个文件的句柄」，但目录里的 DLL 被加载进进程时，它查不到——这正好是最常见的
「未检测到占用进程」却删不掉的场景。CC-DEL 因此额外遍历进程模块表：

```text
[12:03:41] 🔒 映像锁定：wslservice(34988) 已加载 windhawk.dll（无文件句柄）
```

**改权限是最后手段，不是第一步。** 很多工具一上来就 `takeown`，结果是文件归你了、
ACL 也被改花了，文件还是删不掉。CC-DEL 只在解占用之后仍然失败时才碰 ACL。

**延迟删除比硬删可靠。** 映像锁定的 DLL 只有重启才能释放，于是把目标登记到
`PendingFileRenameOperations`，由系统在下次开机、加载任何驱动之前清除：

```text
\??\C:\path\to\file.dll   (REG_MULTI_SZ，两项一组，第二项为空串 = 删除)
```

**保留名必须走扩展路径。** `C:\x\nul` 直接交给 Win32 会被解析成设备 `\\.\NUL`，
`Test-Path` 返回 False、`File.Exists('\\?\C:\x\nul')` 反而返回 True。
CC-DEL 全程用 `\\?\` 前缀按字面处理，`nul` 这种名字才删得掉。

## 从源码构建

需要 Go 1.20+（图标资源已随仓库提交，没有 `windres` 也能构建）。

```bat
cd src
build.bat
```

产物：仓库根目录的 `CC-DEL.exe`（约 2.1 MB）。

手动构建：

```bat
windres -O coff -F pe-x86-64 -o rsrc.syso rsrc.rc
go build -trimpath -ldflags "-H windowsgui -s -w" -o ..\CC-DEL.exe .
```

> `-H windowsgui` 去掉控制台子系统，启动全程不闪黑窗。
> 必须用**包模式** `go build .`——单文件模式（`go build launcher.go`）会忽略 `rsrc.syso`，
> 编出来的 exe **既没有图标、又会带一个控制台黑窗**，而且不报任何错。
>
> 另外：`src/` 目录里只能有一个 `.syso`。每个 `.syso` 都带一个 `.rsrc` 段，
> 多一个（比如备份的 `rsrc0.syso`）就会报 `too many .rsrc sections` 直接编不过。

### 换图标

`logo.ico` 里备了 16 / 32 / 48 三个尺寸——**不能只放一个 256×256**：
资源管理器列表视图、标题栏、任务栏都用小尺寸，只给大图系统会自己缩，糊得厉害，
个别位置干脆显示空白。

有 PNG 设计稿就用脚本转：

```powershell
pwsh -File tools/make-ico.ps1 -Png my-logo.png -Out src/logo.ico
cd src
windres -O coff -F pe-x86-64 -o rsrc.syso rsrc.rc   # 换了 ico 必须重编资源
build.bat
```

脚本一次生成 16/24/32/48/64/128/256 七档（256 用 PNG 压缩，其余用 BMP），
`tools/check-ico.ps1` 可以回读检查每一档是不是都在。

编完想确认图标真进 exe 了：

```powershell
pwsh -File tools/check-icon.ps1 -Exe CC-DEL.exe
# RT_GROUP_ICON（图标组）: 1
# 子系统: Windows GUI（不弹控制台）
# 结论: 图标资源正常
```

它会同时看 PE 里的 `RT_GROUP_ICON` 和子系统标记——「没图标」和「带黑窗」这两个症状
都能一次性查出来。

### 目录结构

```text
CC-DEL/
├── src/
│   ├── CC-DEL.ps1      PowerShell 5.1 + WinForms 主程序（界面 + 删除引擎）
│   ├── launcher.go     Go 宿主：内嵌脚本/图标、无窗口启动、单实例、-Add 快速路径
│   ├── logo.ico        程序与右键菜单图标
│   ├── rsrc.rc         图标资源描述
│   ├── rsrc.syso       预编译的 COFF 资源（让 CI 不需要 windres）
│   └── build.bat       本地一键构建
├── tools/
│   ├── screenshot.ps1  生成 README 截图
│   ├── make-ico.ps1    PNG → 多尺寸 ico
│   └── check-icon.ps1  检查 exe 的图标资源与子系统（防「没图标 / 带黑窗」）
├── docs/
│   ├── logo.png
│   └── screenshot.png
└── .github/workflows/build.yml
```

### 为什么还要个 Go 宿主

界面本身是 PowerShell + WinForms 写的——改起来快、不用编译、系统自带。
但直接跑 `.ps1` 会带一个 `powershell.exe` 的控制台窗口，任务栏图标也是 PowerShell 的。

Go 宿主负责三件事：

1. 用 `CREATE_NO_WINDOW` 拉起 `powershell.exe`，**根本不创建控制台**，所以不会闪黑窗；
2. `SetCurrentProcessExplicitAppUserModelID` + 注册 `HKCU\Software\Classes\AppUserModelId\...`
   的 `IconUri`，任务栏才显示 CC-DEL 自己的图标；
3. 右键菜单 `-Add` 走快速路径：直接写队列文件，毫秒级返回，不起进程。

## 常见问题

**删完还要重启，是不是没成功？**
不是。被加载进进程的 DLL 在本机运行期间无法释放，登记重启删除是唯一正确的做法，
系统会开机时清理掉。这也是「安全模式删」的自动化版本。

**「解除占用」会把我的程序关掉吗？**
会结束持有该文件的进程。所以默认**不自动**做——只有你点了按钮、或删除失败且勾选了
「删除失败时解除占用」才会动。

**杀毒软件报毒？**
单文件、无签名、会结束进程、会改注册表——启发式引擎容易起疑。
源码全在这里，`CC-DEL.ps1` 直接读就行；不放心可以自己构建。

**会不会误删？**
删除前有二次确认（可关）；`C:\`、`C:\Windows`、`C:\Users` 等系统路径有硬保护，直接拒绝；
`-Probe` 永远只读。但**强制删除本质就是不可逆的**，重要数据请先备份。

**在别的机器上能用吗？**
Windows 10 / 11 64 位，只需系统自带的 Windows PowerShell 5.1。

**自己编出来的 exe 没有图标，还带个黑窗？**
两个症状一个原因：用了单文件模式 `go build launcher.go`。那种编法**不会**链接
`rsrc.syso`（图标进不去），也**不会**带上 `-H windowsgui`（于是有控制台）。
用 `cd src` + `build.bat`，或者照上面「手动构建」那两行敲。

如果 `go build .` 直接报 `too many .rsrc sections`：`src/` 里躺了不止一个 `.syso`，
把备份的那份删掉，只留 `rsrc.syso`。

**图标换了但 exe 上没变？**
`rsrc.syso` 是 `logo.ico` 的预编译副本，改 ico 之后必须重新跑一次 `windres`，
否则 exe 里还是旧图标。`build.bat` 在有 windres 时会自动重编。

## 免责声明

本工具按「强力删除」设计，删除操作不可撤销。请在明确知道自己在删什么的前提下使用，
因误删造成的数据丢失由使用者自行承担。

## License

[MIT](LICENSE)
