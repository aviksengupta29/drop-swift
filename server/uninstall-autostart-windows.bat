@echo off
REM DropSwift - remove auto-start on Windows.
REM Stops the background server and removes the logon task.
REM (Your shared folder and files are left untouched.)

schtasks /End /TN "DropSwift" 2>nul
schtasks /Delete /F /TN "DropSwift"

echo DropSwift auto-start removed.
pause
