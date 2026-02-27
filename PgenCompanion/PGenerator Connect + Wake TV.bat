@echo off
title PGenerator+ (Wake TV)
echo.
echo   Starting PGenerator+ with TV Wake...
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0Connect-PGenerator.ps1" -WakeTV
if errorlevel 1 pause
