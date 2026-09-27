@echo off
REM DropSwift server - run manually on Windows.
REM Double-click this file to start sharing your Desktop\DropSwift folder.
REM Phone and PC must be on the same Wi-Fi.

cd /d "%~dp0"

REM Make sure the auto-discovery + QR code libraries are installed (one-time, harmless if already there).
python -m pip install --quiet zeroconf qrcode

set SHARE_DIR=%USERPROFILE%\Desktop\DropSwift
if not exist "%SHARE_DIR%" mkdir "%SHARE_DIR%"

echo Starting DropSwift server, sharing %SHARE_DIR% on port 8080 ...
python server.py --dir "%SHARE_DIR%" --port 8080

pause
