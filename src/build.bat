@echo off
rem ============================================================
rem  Build CC-DEL.exe on Windows (local one-click build)
rem  Requires: Go 1.20+  ; windres optional (only rebuilds icon resource)
rem  Output  : ..\CC-DEL.exe
rem
rem  NOTE: keep this file pure ASCII. A .bat holding Chinese text breaks
rem  under cmd.exe whenever the console codepage does not match the file
rem  encoding (chcp 65001 vs 936), and it fails silently: part of a "rem"
rem  line gets executed as a command. Chinese docs live in README.md.
rem ============================================================
setlocal
cd /d "%~dp0"

if not exist CC-DEL.ps1 goto noscript
if not exist launcher.go goto noscript

rem --- Guard: exactly one .syso is allowed in src\ ---
rem Every .syso carries one .rsrc section and the linker accepts only one.
rem A second copy fails the link with "too many .rsrc sections", which
rem tempts you into "go build launcher.go" - that silently drops the icon
rem AND the -H windowsgui flag, producing an exe with no icon and a console.
set "SYSO_COUNT=0"
for %%F in (*.syso) do set /a SYSO_COUNT+=1
if %SYSO_COUNT% GTR 1 goto toomany

rem --- locate windres: two usual msys64 spots, then PATH ---
set "WR="
if exist "C:\msys64\usr\bin\windres.exe"     goto use_msys
if exist "C:\msys64\mingw64\bin\windres.exe" goto use_mingw
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
echo [1/2] compiling icon resource rsrc.syso ...
"%WR%" -O coff -F pe-x86-64 -o rsrc.syso rsrc.rc
if errorlevel 1 echo [warn] windres failed, keeping the existing rsrc.syso
goto build

:noicon
if exist rsrc.syso (
    echo [1/2] windres not found, reusing committed rsrc.syso
) else (
    echo [1/2] no icon resource available, this build has NO icon
)

:build
echo [2/2] building CC-DEL.exe ...
set "GOFLAGS=-mod=mod"
set "GOPROXY=off"
set "CGO_ENABLED=0"

rem Package mode (.) is mandatory: single-file mode ignores rsrc.syso
go build -trimpath -ldflags "-H windowsgui -s -w" -o ..\CC-DEL.exe .
if errorlevel 1 goto fail

for %%F in (..\CC-DEL.exe) do echo [done] %%~fF  %%~zF bytes
exit /b 0

:fail
echo [failed] go build returned an error, see the output above
exit /b 1

:toomany
echo [error] %SYSO_COUNT% .syso files found in here.
echo         Each one carries a .rsrc section and only one is allowed;
echo         the link fails with "too many .rsrc sections".
echo         Keep rsrc.syso only and delete the others such as rsrc0.syso.
exit /b 1

:noscript
echo [error] CC-DEL.ps1 or launcher.go is missing in this folder
exit /b 1
