@echo off
rem Agent Session Hub: opens Herdr when available, plus both session pickers as tabs.
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
set "distro_switch="
if defined WSL_DISTRO set distro_switch=-d "%WSL_DISTRO%"
wsl.exe %distro_switch% -- bash -lic "command -v herdr >/dev/null 2>&1"
if errorlevel 1 goto launch_without_herdr

"%terminal%" -w "%AGENT_SESSION_HUB_WINDOW%" new-tab --title "Herdr" wsl.exe %distro_switch% -- bash -lic "exec herdr" ; new-tab --title "Codex" powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0recent-codex.ps1" ; new-tab --title "Claude" powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0recent-claude.ps1"
exit /b 0

:launch_without_herdr
"%terminal%" -w "%AGENT_SESSION_HUB_WINDOW%" new-tab --title "Codex" powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0recent-codex.ps1" ; new-tab --title "Claude" powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0recent-claude.ps1"
