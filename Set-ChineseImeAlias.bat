@echo off
setlocal EnableExtensions
title IME Description Alias Tool

rem IMPORTANT: keep this .bat pure ASCII. cmd.exe mis-parses multibyte
rem characters in batch files on some Windows builds (chcp 65001 does NOT
rem reliably fix the batch parser's byte-offset bug), which caused
rem "'xxx' is not recognized as an internal or external command" errors.
rem All user-facing Chinese text lives in the .ps1 file instead.

set "PS1=%~dp0Set-ChineseImeAlias.ps1"

rem Re-entry after UAC elevation carries the choices as args: <1|2> <run|dry>
if not "%~1"=="" goto :RUN

rem Show the menu in PowerShell (Unicode-safe). Exit code mapping:
rem   0 = quit, 11 = modify+dryrun, 12 = modify+run,
rem   21 = restore+dryrun, 22 = restore+run
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -LauncherMenu
set "RC=%errorlevel%"
if "%RC%"=="0" goto :END
if "%RC%"=="11" (set "OP=1"&set "MODE=dry")
if "%RC%"=="12" (set "OP=1"&set "MODE=run")
if "%RC%"=="21" (set "OP=2"&set "MODE=dry")
if "%RC%"=="22" (set "OP=2"&set "MODE=run")
if not defined OP (
    echo.
    pause
    goto :END
)

:RUN
if not "%~1"=="" (
    set "OP=%~1"
    set "MODE=%~2"
)
set "MODEARG="
if "%OP%"=="2" set "MODEARG=-RestoreMenu"
set "DRYARG="
if "%MODE%"=="dry" set "DRYARG=-DryRun"

rem Writing the registry needs admin; DryRun is read-only, no elevation.
if not "%DRYARG%"=="" goto :RUNPS
net session >nul 2>&1
if not errorlevel 1 goto :RUNPS
powershell -NoProfile -Command "Start-Process cmd -Verb RunAs -ArgumentList '/c \"\"%~f0\" \"%OP%\" \"%MODE%\"\"'"
goto :EOF

:RUNPS
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %MODEARG% %DRYARG%
echo.
pause

:END
endlocal
