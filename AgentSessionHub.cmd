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
set "AGENT_SESSION_HUB_WINDOW=AgentSessionHub-%RANDOM%-%RANDOM%"
"%terminal%" -w "%AGENT_SESSION_HUB_WINDOW%" new-tab --title "Codex" powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0recent-codex.ps1" ; new-tab --title "Claude" powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0recent-claude.ps1"
