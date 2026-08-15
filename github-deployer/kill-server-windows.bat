@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0kill-server-windows.ps1"
if errorlevel 1 (
  echo.
  pause
)
