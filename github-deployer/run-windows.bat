@echo off
setlocal
if not exist "%~dp0runtime\python.exe" (
  echo The bundled Python runtime is missing.
  echo Extract the complete PGenerator GitHub Deployer ZIP and try again.
  pause
  exit /b 1
)

"%~dp0runtime\python.exe" -X utf8 "%~dp0server.py" %*
if errorlevel 1 (
  echo.
  echo The PGenerator GitHub deployer could not start.
  pause
)
