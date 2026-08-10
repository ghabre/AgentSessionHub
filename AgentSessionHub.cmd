@echo off
rem Agent Session Hub: opens both session pickers as tabs in one Windows Terminal window.
set "terminal=wt.exe"
where wt.exe >nul 2>&1
if not errorlevel 1 goto launch

rem The WindowsApps directory may not be on PATH even when Terminal is installed.
set "terminal=%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe"
if exist "%terminal%" goto launch

echo Windows Terminal is required but could not be found.
echo Install Windows Terminal or enable its wt.exe App Execution Alias.
pause
exit /b 1

:launch
"%terminal%" -w 0 new-tab --title "Agent Session Hub - Codex" powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0recent-codex.ps1" ; new-tab --title "Agent Session Hub - Claude" powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0recent-claude.ps1"
