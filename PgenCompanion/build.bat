@echo off
REM Build Pgen Companion into a standalone Windows executable.
REM Requires Python 3.10+ and pip.
REM
REM Usage: build.bat
REM Output: dist\PgenCompanion\PgenCompanion.exe

echo === Installing dependencies ===
pip install -r requirements.txt

echo === Building executable ===
pyinstaller --noconfirm --onedir --windowed ^
    --name "PgenCompanion" ^
    --icon "..\Pgenerator.ico" ^
    --add-data "pgen_client.py;." ^
    pgen_companion.py

echo === Done ===
echo Output: dist\PgenCompanion\PgenCompanion.exe
pause
