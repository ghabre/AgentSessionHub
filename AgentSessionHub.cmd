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
rem A second launch within %window% seconds of the last one (a double-click on a single-click
rem pin, an impatient re-click) is ignored, so it can't open a second hub -- or, as before,
rem stack a second tab pair into the first one's window: cmd seeds %RANDOM% from the current
rem second, so same-second launches also computed the same window name.
rem
rem Each launch claims one lock directory per second for the next %window% seconds, in
rem increasing order, and gives up at the first one that already exists. mkdir is atomic and
rem any two launches less than %window% seconds apart share a second, so exactly one of them
rem gets through, even when both start in the same instant. Locks older than a day are pruned.
set "window=5"
set "locks=%TEMP%\AgentSessionHub-launches"
if not exist "%locks%" mkdir "%locks%" 2>nul
forfiles /p "%locks%" /d -1 /c "cmd /c rd /q @path" >nul 2>&1
set "now=%TIME: =0%"
set "day=%DATE: =0%"
set "day=%day:/=%"
set "day=%day:-=%"
set "day=%day:.=%"
rem The 1xx-100 form stops set /a reading 08 and 09 as invalid octal.
set /a "sec=(1%now:~0,2%-100)*3600 + (1%now:~3,2%-100)*60 + (1%now:~6,2%-100)"
set /a "last=sec+window-1"
for /l %%s in (%sec%,1,%last%) do (
    mkdir "%locks%\%day%-%%s" 2>nul || exit /b 0
)
rem No other launch can be running now, so the time alone names this hub's window.
set "AGENT_SESSION_HUB_WINDOW=AgentSessionHub-%day%-%now::=%"
set "AGENT_SESSION_HUB_WINDOW=%AGENT_SESSION_HUB_WINDOW:.=%"
set "AGENT_SESSION_HUB_WINDOW=%AGENT_SESSION_HUB_WINDOW:,=%"
"%terminal%" -w "%AGENT_SESSION_HUB_WINDOW%" new-tab --title "Codex" powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0recent-codex.ps1" ; new-tab --title "Claude" powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0recent-claude.ps1"
