@echo off
setlocal EnableExtensions
chcp 65001 >nul
title Windows 中文输入法 Description 修改工具

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%Set-ChineseImeAlias.ps1"

rem 旧版控制台的输出区域不做字体回退：字体不含中文字形时中文显示为 ?，
rem 先把当前窗口字体切换为新宋体（仅影响当前窗口）
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -FixConsoleFontOnly >nul 2>&1

rem 提权重入时携带参数，不再重复询问：Set-ChineseImeAlias.bat <1|2> <run|dry>
if not "%~1"=="" (
    set "OP=%~1"
    set "MODE=%~2"
    goto :BUILD
)

:MENU
echo.
echo ==========================================
echo   Windows 中文输入法 Description 修改工具
echo ==========================================
echo   1. 修改输入法 Description（默认）
echo   2. 从备份恢复（列出 backup 目录中的备份）
echo   Q. 退出
echo.
set /p "OP=请选择 [1/2/Q]（直接回车=1）: "
if "%OP%"=="" set "OP=1"
if /i "%OP%"=="Q" goto :END
if /i "%OP%"=="QUIT" goto :END
if not "%OP%"=="1" if not "%OP%"=="2" (
    echo 无效的选择：%OP%
    goto :MENU
)

echo.
set /p "DRY=是否以 DryRun 模拟运行（不写入注册表）？[Y/N]（直接回车=N）: "
set "MODE=run"
if /i "%DRY%"=="Y" set "MODE=dry"
if /i "%DRY%"=="YES" set "MODE=dry"

:BUILD
set "MODEARG="
if "%OP%"=="2" set "MODEARG=-RestoreMenu"
set "DRYARG="
if "%MODE%"=="dry" set "DRYARG=-DryRun"

rem 实际写入注册表需要管理员权限；DryRun 只读，不需要提权
if not "%DRYARG%"=="" goto :RUNPS
net session >nul 2>&1
if not errorlevel 1 goto :RUNPS
echo.
echo 正在请求管理员权限...
powershell -NoProfile -Command "Start-Process cmd -Verb RunAs -ArgumentList '/c \"\"%~f0\" \"%OP%\" \"%MODE%\"\"'"
goto :EOF

:RUNPS
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %MODEARG% %DRYARG%

echo.
pause

:END
endlocal
