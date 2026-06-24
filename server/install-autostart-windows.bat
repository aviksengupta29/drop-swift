@echo off
REM DropSwift - install auto-start on Windows.
REM Run this ONCE (right-click -> Run as administrator is NOT required).
REM After this, the DropSwift server starts automatically every time you log in,
REM so the iPhone app can always find this PC. Files land in Desktop\DropSwift.

cd /d "%~dp0"

REM Ensure the auto-discovery library is present.
python -m pip install --quiet zeroconf

set SHARE_DIR=%USERPROFILE%\Desktop\DropSwift
if not exist "%SHARE_DIR%" mkdir "%SHARE_DIR%"

REM Find pythonw.exe (runs with no console window) if available, else python.exe.
for /f "delims=" %%i in ('where pythonw 2^>nul') do set PYW=%%i
if "%PYW%"=="" for /f "delims=" %%i in ('where python 2^>nul') do set PYW=%%i

REM Create a scheduled task that runs at every logon for the current user.
schtasks /Create /F /SC ONLOGON /TN "DropSwift" ^
  /TR "\"%PYW%\" \"%~dp0server.py\" --dir \"%SHARE_DIR%\" --port 8080"

REM Start it now too.
schtasks /Run /TN "DropSwift"

echo.
echo ============================================================
echo  DropSwift auto-start installed and running.
echo    Shared folder: %SHARE_DIR%
echo    Port         : 8080
echo  The DropSwift app should now find this PC automatically.
echo.
echo  To remove it later, run: uninstall-autostart-windows.bat
echo ============================================================
echo.
echo  If the app cannot connect, allow Python through Windows
echo  Defender Firewall (Private networks) when prompted.
pause
