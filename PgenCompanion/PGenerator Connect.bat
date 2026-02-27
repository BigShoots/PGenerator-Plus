@echo off
title PGenerator+ Companion
echo.
echo   Starting PGenerator+ Companion...
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0Connect-PGenerator.ps1" %*
if errorlevel 1 pause
