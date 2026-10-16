@echo off
chcp 65001 >nul
title UsbNetFix release verification
cd /d "%~dp0"
echo ============================================================
echo  UsbNetFix - release verification
echo ============================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify-release.ps1"
echo.
pause >nul
