@echo off
rem Opens both recent-session pickers as tabs in one Windows Terminal window.
wt.exe -w 0 new-tab --title "Codex History" powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0recent-codex.ps1" ; new-tab --title "Claude History" powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0recent-claude.ps1"
