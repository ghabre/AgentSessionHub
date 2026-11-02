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
rem cmd seeds %RANDOM% from the current second, so two launches in the same second (e.g. a
rem double-click on a single-click pin) got the same window name and stacked both tab pairs
rem in one window. Each launch now claims its name by creating a lock directory -- mkdir is
rem atomic, so a launch that computes a taken name bumps a counter and tries the next one.
rem Locks older than a day are pruned; the window name only has to be unique while it's open.
set "locks=%TEMP%\AgentSessionHub-windows"
if not exist "%locks%" mkdir "%locks%" 2>nul
forfiles /p "%locks%" /d -1 /c "cmd /c rd /q @path" >nul 2>&1
set "stamp=%DATE%%TIME%"
set "stamp=%stamp: =0%"
set "stamp=%stamp::=%"
set "stamp=%stamp:.=%"
set "stamp=%stamp:,=%"
set "stamp=%stamp:/=%"
set "stamp=%stamp:-=%"
set /a n=0
:claim
set /a n+=1
set "AGENT_SESSION_HUB_WINDOW=AgentSessionHub-%stamp%-%RANDOM%-%n%"
mkdir "%locks%\%AGENT_SESSION_HUB_WINDOW%" 2>nul || goto claim
"%terminal%" -w "%AGENT_SESSION_HUB_WINDOW%" new-tab --title "Codex" powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0recent-codex.ps1" ; new-tab --title "Claude" powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0recent-claude.ps1"
