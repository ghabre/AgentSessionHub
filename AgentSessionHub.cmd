@echo off
rem Agent Session Hub: opens both session pickers as tabs in one Windows Terminal window.
rem Fall back to separate PowerShell windows when Windows Terminal is not installed
rem or its wt.exe App Execution Alias is disabled.
where wt.exe >nul 2>&1
if errorlevel 1 goto powershell_fallback

wt.exe -w 0 new-tab --title "Agent Session Hub - Codex" powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0recent-codex.ps1" ; new-tab --title "Agent Session Hub - Claude" powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0recent-claude.ps1"
exit /b %errorlevel%

:powershell_fallback
start "Agent Session Hub - Codex" powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0recent-codex.ps1"
start "Agent Session Hub - Claude" powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0recent-claude.ps1"
