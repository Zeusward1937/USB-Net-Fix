@echo off
rem ===========================================================================
rem  UsbNetFix launcher.
rem
rem  It elevates itself on purpose.  The saved-network database under
rem  HKLM\...\NetworkList is owned by SYSTEM and only grants access to
rem  BUILTIN\Administrators and the netprofm service account - a standard user
rem  cannot even READ it.  Without elevation the control panel would report
rem  "administrator rights required" for almost everything.
rem
rem  If the user declines the UAC prompt, it falls back to a normal run so the
rem  informational commands still work.
rem ===========================================================================
chcp 65001 >nul
title UsbNetFix
cd /d "%~dp0"

if not exist "%~dp0UsbNetFix.ps1" (
  echo [UsbNetFix] cannot find UsbNetFix.ps1 next to this launcher.
  echo            expected: %~dp0UsbNetFix.ps1
  echo.
  pause
  exit /b 1
)

net session >nul 2>&1
if %ERRORLEVEL% EQU 0 goto :run

echo Requesting administrator rights...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-elevated.ps1" %*
if %ERRORLEVEL% EQU 0 exit /b 0

echo.
echo [UsbNetFix] continuing without administrator rights.
echo            Commands that need HKLM access will say so.
echo.
:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0UsbNetFix.ps1" %*
set RC=%ERRORLEVEL%
if not "%RC%"=="0" (
  echo.
  echo [UsbNetFix] exited with code %RC%
)
echo.
pause >nul
exit /b %RC%
