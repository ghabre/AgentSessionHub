@echo off
rem Agent Session Hub: opens both session pickers as tabs in one Windows Terminal window.
wt.exe -w 0 new-tab --title "Agent Session Hub - Codex" powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0recent-codex.ps1" ; new-tab --title "Agent Session Hub - Claude" powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0recent-claude.ps1"
