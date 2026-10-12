@echo off
chcp 65001 >nul
title UsbNetFix - USB tethering network name fixer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0UsbNetFix.ps1" %*
set RC=%ERRORLEVEL%
if not "%RC%"=="0" (
  echo.
  echo [UsbNetFix] exited with code %RC%
  pause
)
exit /b %RC%
