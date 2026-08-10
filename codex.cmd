@echo off
rem Launches recent-codex.ps1 from whatever folder this file sits in (%~dp0),
rem so the whole folder can be moved without editing any paths.
powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0recent-codex.ps1" %*
