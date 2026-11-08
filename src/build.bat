@echo off
rem ============================================================
rem  本地构建 CC-DEL.exe（Windows）
rem  依赖：Go 1.20+；windres 可选，仅用于重新生成图标资源
rem  产物：..\CC-DEL.exe
rem ============================================================
setlocal
cd /d "%~dp0"

if not exist CC-DEL.ps1 goto noscript
if not exist launcher.go goto noscript

rem --- 找 windres：msys64 的两处常见位置，然后看 PATH ---
set "WR="
if exist "C:\msys64\usr\bin\windres.exe"        goto use_msys
if exist "C:\msys64\mingw64\bin\windres.exe"    goto use_mingw
where windres >nul 2>&1
if not errorlevel 1 goto use_path
goto noicon

:use_msys
set "WR=C:\msys64\usr\bin\windres.exe"
goto doicon

:use_mingw
set "WR=C:\msys64\mingw64\bin\windres.exe"
goto doicon

:use_path
set "WR=windres"
goto doicon

:doicon
if not exist logo.ico goto noicon
echo [1/2] 编译图标资源 rsrc.syso ...
"%WR%" -O coff -F pe-x86-64 -o rsrc.syso rsrc.rc
if errorlevel 1 echo [警告] 图标资源编译失败，沿用已有的 rsrc.syso
goto build

:noicon
if exist rsrc.syso (
    echo [1/2] 未找到 windres，沿用已提交的 rsrc.syso
) else (
    echo [1/2] 无可用图标资源，本次构建的 exe 不带图标
)

:build
echo [2/2] 编译 CC-DEL.exe ...
set "GOFLAGS=-mod=mod"
set "GOPROXY=off"
set "CGO_ENABLED=0"

rem 必须用包模式（.）：单文件模式会忽略 rsrc.syso，图标就进不去
go build -trimpath -ldflags "-H windowsgui -s -w" -o ..\CC-DEL.exe .
if errorlevel 1 goto fail

for %%F in (..\CC-DEL.exe) do echo [完成] %%~fF  %%~zF 字节
exit /b 0

:fail
echo [失败] go build 未通过，请检查上面的报错
exit /b 1

:noscript
echo [错误] 当前目录缺少 CC-DEL.ps1 或 launcher.go
exit /b 1
