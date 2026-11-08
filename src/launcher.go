// CC-DEL launcher —— 单文件 exe 宿主
//
// 职责：
//  1. 把内嵌的 CC-DEL.ps1 释放到 %LOCALAPPDATA%\CC-DEL\（内容不变则复用）
//  2. 用 CREATE_NO_WINDOW 拉起 powershell，保证 GUI 启动全程不闪黑窗
//  3. 右键菜单 -Add 走快速路径：直接写队列文件，毫秒级、不起进程
//  4. 已有窗口时再次双击 exe -> 激活原窗口，不重复开
//
// 编译：go build -ldflags "-H windowsgui -s -w -trimpath" -o CC-DEL.exe .
package main

import (
	"bytes"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

//go:embed CC-DEL.ps1
var embedded []byte

// 图标也内嵌一份：界面进程是 powershell.exe，拿不到 CC-DEL.exe 的资源，
// 只能由宿主把 ico 落到磁盘再通过 WINDEL_ICON 告诉脚本。
//
//go:embed logo.ico
var iconData []byte

const (
	appName        = "CC-DEL"
	appTitle       = "CC-DEL 强制删除工具"
	mutexName      = `Local\CCDEL_Gui`
	synchronize    = 0x00100000
	createNoWindow = 0x08000000
	swRestore      = 9
	mbIconError    = 0x00000010
)

var (
	k32          = syscall.NewLazyDLL("kernel32.dll")
	u32          = syscall.NewLazyDLL("user32.dll")
	pOpenMutex   = k32.NewProc("OpenMutexW")
	pCloseHandle = k32.NewProc("CloseHandle")
	pFindWindow  = u32.NewProc("FindWindowW")
	pShowWindow  = u32.NewProc("ShowWindow")
	pSetFgWindow = u32.NewProc("SetForegroundWindow")
	pIsIconic    = u32.NewProc("IsIconic")
	pMessageBox  = u32.NewProc("MessageBoxW")
)

// version 由构建时注入：-ldflags "-X main.version=2026.11.08"
var version = "dev"

func main() {
	migrateLegacy()
	appendLog("🚀 CC-DEL " + version)
	args := os.Args[1:]
	var addPath string
	var forceNew bool
	var rest []string

	for i := 0; i < len(args); i++ {
		switch strings.ToLower(args[i]) {
		case "-add", "/add":
			if i+1 < len(args) {
				addPath = args[i+1]
				i++
			}
		case "-forcenew", "/forcenew":
			forceNew = true
		default:
			rest = append(rest, args[i])
		}
	}

	script, err := resolveScript()
	if err != nil {
		msgBox("无法准备运行环境：\r\n"+err.Error(), appName, mbIconError)
		os.Exit(1)
	}

	// 右键菜单：已有窗口就只写队列（毫秒级返回），否则写队列并冷启动界面
	if addPath != "" {
		added := addToQueue(addPath)
		if !added {
			return
		}
		if guiRunning() {
			return
		}
		launchGui(script, false)
		return
	}

	// 无参数：显示界面 / 激活已有窗口
	if len(rest) == 0 {
		if forceNew {
			// 提权重启：等旧实例释放单实例锁，否则新窗口会因抢锁失败直接退出
			waitGuiGone(3 * time.Second)
			launchGui(script, false)
			return
		}
		if guiRunning() {
			activateExisting()
			return
		}
		launchGui(script, false)
		return
	}

	// -Install / -Uninstall / -SelfTest 等：前台执行，保留控制台输出
	os.Exit(runConsole(script, rest))
}

// ---------------- 运行环境 ----------------

func exeDir() string {
	p, err := os.Executable()
	if err != nil {
		return ""
	}
	if r, err := filepath.EvalSymlinks(p); err == nil {
		p = r
	}
	return filepath.Dir(p)
}

func dataRoot() string {
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		base = os.TempDir()
	}
	return filepath.Join(base, appName)
}

// resolveScript 优先用 exe 同目录的 CC-DEL.ps1（便于直接改脚本调试），
// 否则把内嵌脚本释放到 %LOCALAPPDATA%\CC-DEL\，内容未变则跳过写入。
func resolveScript() (string, error) {
	if d := exeDir(); d != "" {
		cand := filepath.Join(d, "CC-DEL.ps1")
		if fi, err := os.Stat(cand); err == nil && !fi.IsDir() && fi.Size() > 512 {
			return cand, nil
		}
	}

	root := dataRoot()
	if err := os.MkdirAll(root, 0o755); err != nil {
		return "", err
	}
	dst := filepath.Join(root, "CC-DEL.ps1")
	marker := filepath.Join(root, "script.sha256")

	sum := sha256.Sum256(embedded)
	want := hex.EncodeToString(sum[:])
	have := ""
	if b, err := os.ReadFile(marker); err == nil {
		have = strings.TrimSpace(string(b))
	}

	if have != want {
		if err := os.WriteFile(dst, embedded, 0o644); err != nil {
			return "", err
		}
		_ = os.WriteFile(marker, []byte(want), 0o644)
	} else if _, err := os.Stat(dst); err != nil {
		if err := os.WriteFile(dst, embedded, 0o644); err != nil {
			return "", err
		}
	}
	return dst, nil
}

func psExe() string {
	if r := os.Getenv("SystemRoot"); r != "" {
		p := filepath.Join(r, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return "powershell.exe"
}

func hostEnv() []string {
	exe := filepath.Join(exeDir(), appName+".exe")
	icon := ensureIcon()
	out := make([]string, 0, len(os.Environ())+2)
	for _, e := range os.Environ() {
		up := strings.ToUpper(e)
		if strings.HasPrefix(up, "WINDEL_HOST_EXE=") || strings.HasPrefix(up, "WINDEL_ICON=") {
			continue
		}
		out = append(out, e)
	}
	out = append(out, "WINDEL_HOST_EXE="+exe)
	if icon != "" {
		out = append(out, "WINDEL_ICON="+icon)
	}
	return out
}

// ensureIcon 把内嵌图标释放到数据目录，内容未变则复用。
func ensureIcon() string {
	root := dataRoot()
	if err := os.MkdirAll(root, 0o755); err != nil {
		return ""
	}
	dst := filepath.Join(root, "CC-DEL.ico")
	if b, err := os.ReadFile(dst); err == nil && bytes.Equal(b, iconData) {
		return dst
	}
	if err := os.WriteFile(dst, iconData, 0o644); err != nil {
		return ""
	}
	return dst
}

// ---------------- 进程与窗口 ----------------

func guiRunning() bool {
	name, err := syscall.UTF16PtrFromString(mutexName)
	if err != nil {
		return false
	}
	h, _, _ := pOpenMutex.Call(synchronize, 0, uintptr(unsafe.Pointer(name)))
	if h == 0 {
		return false
	}
	pCloseHandle.Call(h)
	return true
}

// waitGuiGone 轮询等待单实例锁被释放（提权重启时旧实例正在关闭）。
func waitGuiGone(timeout time.Duration) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if !guiRunning() {
			return
		}
		time.Sleep(60 * time.Millisecond)
	}
}

func activateExisting() {
	t, err := syscall.UTF16PtrFromString(appTitle)
	if err != nil {
		return
	}
	h, _, _ := pFindWindow.Call(0, uintptr(unsafe.Pointer(t)))
	if h == 0 {
		return
	}
	if iconic, _, _ := pIsIconic.Call(h); iconic != 0 {
		pShowWindow.Call(h, swRestore)
	}
	pSetFgWindow.Call(h)
}

func msgBox(text, title string, flags uintptr) {
	t, err1 := syscall.UTF16PtrFromString(text)
	c, err2 := syscall.UTF16PtrFromString(title)
	if err1 != nil || err2 != nil {
		return
	}
	pMessageBox.Call(0, uintptr(unsafe.Pointer(t)), uintptr(unsafe.Pointer(c)), flags)
}

// launchGui 以无控制台方式拉起界面进程。
// CREATE_NO_WINDOW 是关键：进程完全不创建控制台，不会出现黑窗一闪。
func launchGui(script string, wait bool) {
	cmd := exec.Command(psExe(),
		"-NoProfile", "-ExecutionPolicy", "Bypass", "-STA",
		"-File", script)
	cmd.Dir = filepath.Dir(script)
	cmd.Env = hostEnv()
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNoWindow}
	if wait {
		err := cmd.Run()
		if err != nil {
			appendLog("❌ 前台执行失败：" + err.Error())
		}
		return
	}
	if err := cmd.Start(); err != nil {
		appendLog("❌ 启动界面失败：" + err.Error())
		return
	}
	appendLog("🪟 界面进程已拉起 pid=" + strconv.Itoa(cmd.Process.Pid) + " 脚本=" + script)
}

// runConsole 用于 -Install / -Uninstall / -SelfTest。
// winexe 进程没有控制台，且 cmd/PowerShell 对 GUI 子系统程序不会等待，
// 因此这里捕获子进程输出，结束后用对话框呈现，保证结果一定看得到。
func runConsole(script string, args []string) int {
	argv := []string{"-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-File", script}
	argv = append(argv, args...)
	cmd := exec.Command(psExe(), argv...)
	cmd.Dir = filepath.Dir(script)
	cmd.Env = hostEnv()

	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf

	err := cmd.Run()
	code := 0
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	} else if err != nil {
		msgBox("无法启动 PowerShell：\r\n"+err.Error(), appName, mbIconError)
		return 1
	}

	out := strings.TrimSpace(buf.String())
	quiet := false
	for _, a := range args {
		switch strings.ToLower(a) {
		case "-selftest", "/selftest", "-probe", "/probe", "-pending", "/pending":
			quiet = true
		}
	}
	if quiet {
		// 自检输出较长，直接回写标准输出，交给调用方重定向保存
		_, _ = os.Stdout.WriteString(out + "\r\n")
		return code
	}
	if out != "" {
		showResult(out)
	}
	return code
}

func showResult(s string) {
	const maxLen = 1400
	if len(s) > maxLen {
		s = "……（输出过长，已截断）……\r\n" + s[len(s)-maxLen:]
	}
	msgBox(s, appName, 0x00000040) // MB_ICONINFORMATION
}

// ---------------- 队列（与脚本内 Add-QueuePath 保持一致） ----------------

func queueFile() string { return filepath.Join(dataRoot(), "queue.txt") }
func logFile() string   { return filepath.Join(dataRoot(), appName+".log") }

// migrateLegacy 把旧版（WinDel 目录）的待删队列搬到 CC-DEL 目录。
// 改名不该让用户已经攒好的列表凭空消失；只在目标不存在时搬一次，不覆盖。
func migrateLegacy() {
	if _, err := os.Stat(queueFile()); err == nil {
		return
	}
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		return
	}
	b, err := os.ReadFile(filepath.Join(base, "WinDel", "queue.txt"))
	if err != nil {
		return
	}
	if os.MkdirAll(dataRoot(), 0o755) != nil {
		return
	}
	_ = os.WriteFile(queueFile(), b, 0o644)
}

func readQueue() []string {
	b, err := os.ReadFile(queueFile())
	if err != nil {
		return nil
	}
	s := strings.TrimPrefix(string(b), "\ufeff")
	out := make([]string, 0, 8)
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimRight(line, "\r")
		if strings.TrimSpace(line) != "" {
			out = append(out, line)
		}
	}
	return out
}

func writeQueue(items []string) error {
	var sb strings.Builder
	for _, it := range items {
		sb.WriteString(it)
		sb.WriteString("\r\n")
	}
	return os.WriteFile(queueFile(), []byte(sb.String()), 0o644)
}

func appendLog(msg string) {
	if err := os.MkdirAll(dataRoot(), 0o755); err != nil {
		return
	}
	f, err := os.OpenFile(logFile(), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = f.WriteString("[" + time.Now().Format("15:04:05") + "] " + msg + "\r\n")
}

// normalize 与脚本里的一致：去引号、去尾部反斜杠，但盘符根（C:\）保留。
func normalize(p string) string {
	p = strings.TrimSpace(strings.Trim(strings.TrimSpace(p), `"`))
	if p == "" {
		return ""
	}
	if len(p) == 3 && p[1] == ':' && (p[2] == '\\' || p[2] == '/') {
		return p
	}
	if len(p) == 2 && p[1] == ':' {
		return p
	}
	return strings.TrimRight(p, `\`)
}

var reservedNames = map[string]bool{
	"con": true, "prn": true, "aux": true, "nul": true, "ncl": true,
	"com1": true, "com2": true, "com3": true, "com4": true, "com5": true,
	"com6": true, "com7": true, "com8": true, "com9": true,
	"lpt1": true, "lpt2": true, "lpt3": true, "lpt4": true, "lpt5": true,
	"lpt6": true, "lpt7": true, "lpt8": true, "lpt9": true,
}

// isReservedName 判断文件名是否属于 Windows 保留设备名（扩展名不参与判断）。
func isReservedName(name string) bool {
	base := name
	if i := strings.Index(base, "."); i >= 0 {
		base = base[:i]
	}
	base = strings.TrimRight(base, " ")
	return reservedNames[strings.ToLower(base)]
}

func extendedPath(p string) string {
	if strings.HasPrefix(p, `\\?\`) {
		return p
	}
	if strings.HasPrefix(p, `\\`) {
		return `\\?\UNC\` + p[2:]
	}
	// 绝对路径直接加前缀，绝不调用 filepath.Abs：
	// Windows 的规范化（GetFullPathName）会把 C:\x\nul 改写成 \\.\nul 设备路径，
	// 再拼上 \\?\ 就成了非法的 \\?\\\.\nul。保留名必须原样送到 \\?\ 手里。
	if !filepath.IsAbs(p) {
		if abs, err := filepath.Abs(p); err == nil && !strings.HasPrefix(abs, `\\.\`) {
			p = abs
		}
	}
	return `\\?\` + p
}

// statPath 判断路径是否存在。
// 保留名必须先走 \\?\：不带前缀时 Windows 会把它解析成设备，
// 连"根本不存在"的 C:\xxx\nul 也会返回成功，等于放过一个假路径。
func statPath(p string) (os.FileInfo, error) {
	if isReservedName(filepath.Base(p)) {
		return os.Stat(extendedPath(p))
	}
	if fi, err := os.Stat(p); err == nil {
		return fi, nil
	}
	return os.Stat(extendedPath(p))
}

func addToQueue(raw string) bool {
	p := normalize(raw)
	if p == "" {
		return false
	}
	if _, err := statPath(p); err != nil {
		appendLog("⚠️ 路径不存在，已忽略：" + p)
		return false
	}
	items := readQueue()
	for _, it := range items {
		if strings.EqualFold(it, p) {
			appendLog("ℹ️ 已在列表中：" + p)
			return false
		}
	}
	items = append(items, p)
	if err := writeQueue(items); err != nil {
		appendLog("❌ 写入队列失败：" + err.Error())
		return false
	}
	if isReservedName(filepath.Base(p)) {
		appendLog("🧩 保留名文件（按字面路径处理）：" + p)
	}
	appendLog("➕ 加入列表：" + p)
	return true
}
