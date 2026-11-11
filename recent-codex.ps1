# recent-codex.ps1
#
# Fuzzy-picker for Codex sessions running inside WSL. Lists top-level transcripts
# updated within the last 40 days; pick one to resume in a new Windows Terminal tab.
# Picking takes two clicks: the first left-click on a row only highlights it, a second
# click on that same row opens it (Enter opens the highlighted row straight away). This
# is deliberately NOT fzf's own double-click, which demands two fast clicks with no mouse
# drift -- here the two clicks can be any distance apart in time.
# The picker stays up for more picks; Esc reloads this script in-place; close the window to quit.
#
# The top row ("+ New session...") starts a fresh conversation: it opens a folder picker
# listing the project root itself followed by its immediate subfolders (default C:\G\code,
# override with $env:CODEX_NEW_ROOT or $env:AGENT_HUB_NEW_ROOT), and launches a new session
# in the folder you pick -- `codex` on enter/click, `claude` on Alt-C, or `opencode` on Alt-O.
#
# Transfer hotkeys resume a unique linked destination automatically, importing only
# unseen messages and tool notes. Multiple branches require a destination choice.
# A repeated transfer with no new material resumes without adding a prompt.
# Tab marks multiple sessions; Enter or a transfer key continues their combined
# conversation, reusing the existing result when known. Alt-F copies one or more
# selected chats as formatted HTML plus markdown (requires pandoc).
# Transfer state and immutable payloads live in the gitignored .history folder beside this script,
# separately for each backend/distro. Keep this directory to preserve synchronization.
#
# On startup it also snapshots the transcripts (~/.codex/sessions, session_index.jsonl,
# plus history.jsonl) to a .tar.gz under .\backups\codex, but only if the newest snapshot is
# more than 24 hours old, and
# it keeps the 10 most recent. They land on the Windows side on purpose: the originals only
# exist inside the WSL VHD. Override the location with $env:CODEX_BACKUP_DIR.
#
# Backend: $env:AGENT_HUB_BACKEND = 'wsl' (default) or 'windows'.
#   wsl     : Codex installed INSIDE WSL; the requirements below apply as written.
#   windows : Codex installed natively (data under %USERPROFILE%\.codex). The same helper
#             scripts run under Git for Windows' bash and Windows Python; fzf, pandoc and
#             claude come from the Windows PATH, and tabs open in PowerShell 7, whose
#             profile supplies per-shell tools such as fnm's codex. No WSL is used.
#
# Requirements (wsl backend):
#   - Windows with WSL2, and Codex installed INSIDE WSL (data under ~/.codex).
#   - Windows Terminal (wt.exe) -- used to open the resumed sessions as tabs.
#   - The Linux build of fzf installed in WSL (NOT fzf.exe -- the Windows build
#     mis-parses Windows Terminal mouse input). apt: `sudo apt install fzf`, or grab a
#     release binary into ~/.local/bin. It's found via the WSL login-shell PATH.
#   - `codex` reachable from the WSL login shell (bash -lic).
#   - `claude` / `opencode` likewise, but only if you use the Alt-C / Alt-O handoff.
#   - Python 3.8+ with SQLite for conversation handoffs and combining.
#   - `pandoc` in WSL, but only for the Alt-F clipboard export. apt: `sudo apt install pandoc`.
#
# Auto-detected (no per-machine editing needed): the default WSL distro and the fzf path.
# Overrides: set $env:WSL_DISTRO to force a distro, $env:WSL_USER to force the home user.
#
# Usage: run under Windows PowerShell, e.g. a shortcut with target:
#   powershell.exe -NoExit -ExecutionPolicy Bypass -File "C:\path\to\recent-codex.ps1"

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$script:recentScriptArgs = @($args)

# File.ReadLines refuses files another process holds open for writing, which native agents
# do with their live transcripts. Stream lines with read/write sharing instead.
Add-Type -TypeDefinition @'
public static class SharedFile {
    public static System.Collections.Generic.IEnumerable<string> ReadLines(string path) {
        using (var stream = new System.IO.FileStream(path, System.IO.FileMode.Open, System.IO.FileAccess.Read,
                                                     System.IO.FileShare.ReadWrite | System.IO.FileShare.Delete))
        using (var reader = new System.IO.StreamReader(stream)) {
            string line;
            while ((line = reader.ReadLine()) != null) { yield return line; }
        }
    }
}
'@

$backend = if ($env:AGENT_HUB_BACKEND) { $env:AGENT_HUB_BACKEND.ToLowerInvariant() } else { 'wsl' }
if ($backend -notin @('wsl', 'windows')) { throw "AGENT_HUB_BACKEND must be 'wsl' or 'windows', not '$backend'" }

. (Join-Path $PSScriptRoot 'hub-tools.ps1')
$availableTools = @(Get-HubAvailableTools)

$enabledTools = @(if ($env:AGENT_HUB_TOOLS) {
    $env:AGENT_HUB_TOOLS.ToLowerInvariant() -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
} else {
    'codex', 'claude', 'opencode'
}) | Where-Object { $_ -in $availableTools }
$claudeEnabled = 'claude' -in $enabledTools
$claudeWorkEnabled = 'claude-work' -in ($env:AGENT_HUB_TOOLS -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() }) -and 'claude' -in $availableTools -and (Test-HubClaudeWork)
$opencodeEnabled = 'opencode' -in $enabledTools

# C:\dir\sub -> /mnt/c/dir/sub in WSL, /c/dir/sub in Git Bash. One definition for every
# Windows path this script hands to the helper scripts (temp dir, new-session root, backup dir).
function ConvertTo-WslPath($winPath) {
    $mount = if ($backend -eq 'wsl') { '/mnt/' } else { '/' }
    $mount + ($winPath.Substring(0,1).ToLower()) + ($winPath.Substring(2) -replace '\\','/')
}

# The reverse, for paths the helper scripts print: WSL files are reached over \\wsl$.
function ConvertFrom-WslPath($path) {
    if ($backend -eq 'wsl') { return "\\wsl$\$distro" + ($path -replace '/','\') }
    if ($path -match '^/([a-zA-Z])(/.*)?$') { return $Matches[1].ToUpper() + ':' + ("$($Matches[2])" -replace '/','\') }
    return $path
}

# Keep concurrent picker instances from overwriting each other's list, selection,
# wrapper, and click-state files when the hub shortcut is opened more than once.
$tmpWin  = Join-Path $env:TEMP ("recent-codex-{0}" -f $PID)
New-Item -ItemType Directory -Path $tmpWin -Force | Out-Null
$tmpWsl  = ConvertTo-WslPath $tmpWin

if ($backend -eq 'wsl') {
    # Default WSL distro: $env:WSL_DISTRO override, else the registered default distro
    # (DefaultDistribution GUID -> DistributionName), else fall back to 'Ubuntu'.
    $distro = if ($env:WSL_DISTRO) { $env:WSL_DISTRO } else {
        try {
            $lxss    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
            $defGuid = (Get-ItemProperty $lxss -Name DefaultDistribution -ErrorAction Stop).DefaultDistribution
            (Get-ItemProperty "$lxss\$defGuid" -Name DistributionName -ErrorAction Stop).DistributionName
        } catch { 'Ubuntu' }
    }

    # Resolve paths in one login shell so profile-defined PATH and data overrides apply.
    # Written to a script file so wsl.exe never mangles quotes or `$` expansions.
    $probeShWin = Join-Path $tmpWin 'probe.sh'; $probeShWsl = "$tmpWsl/probe.sh"
    $probeSh = @'
#!/bin/sh
u=${WSL_USER:-$(id -un)}
h="/home/$u"
f=$(command -v fzf 2>/dev/null)
[ -n "$f" ] || f="$h/.local/bin/fzf"
d="${XDG_DATA_HOME:-$h/.local/share}/opencode"
if [ -n "$OPENCODE_DB" ]; then
    case "$OPENCODE_DB" in /*) db="$OPENCODE_DB" ;; *) db="$d/$OPENCODE_DB" ;; esac
else
    db="$d/opencode.db"
fi
printf '%s\n%s\n%s\n' "$u" "$f" "$db"
'@ -replace "`r`n","`n"
    [System.IO.File]::WriteAllText($probeShWin, $probeSh)
    $probe = @(wsl.exe -d $distro -- bash -li $probeShWsl 2>$null)
    $wslUser       = if ($env:WSL_USER) { $env:WSL_USER } elseif ($probe.Count -ge 1 -and $probe[0]) { "$($probe[0])".Trim() } else { (wsl -d $distro -- whoami).Trim() }
    $bashHome      = "/home/$wslUser"
    $fzfPath       = if ($probe.Count -ge 2 -and $probe[1]) { "$($probe[1])".Trim() } else { "$bashHome/.local/bin/fzf" }
    $opencodeDbWsl = if ($probe.Count -ge 3 -and $probe[2]) { "$($probe[2])".Trim() } else { "$bashHome/.local/share/opencode/opencode.db" }
    $codex         = "\\wsl$\$distro\home\$wslUser\.codex"
} else {
    $gitBash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
    if (-not (Test-Path $gitBash)) { throw "The windows backend needs Git for Windows: $gitBash not found" }
    $bashHome = ConvertTo-WslPath $HOME
    $codex   = Join-Path $HOME '.codex'
    $dataBase = if ($env:XDG_DATA_HOME) { ConvertTo-WslPath $env:XDG_DATA_HOME } else { "$bashHome/.local/share" }
    $opencodeData = "$dataBase/opencode"
    $opencodeDbWsl = if ($env:OPENCODE_DB) {
        $dbOverride = if ($env:OPENCODE_DB -match '^[A-Za-z]:\\') { ConvertTo-WslPath $env:OPENCODE_DB } else { $env:OPENCODE_DB -replace '\\','/' }
        if ($dbOverride.StartsWith('/')) { $dbOverride } else { "$opencodeData/$dbOverride" }
    } else { "$opencodeData/opencode.db" }
    # Tab commands run in PowerShell, where a bare 'bash' would be WSL's System32 bash.exe.
    $tabShell = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    # The title helper starts codex itself. Node version managers such as fnm put codex on a
    # per-shell PATH that this window may lack, so fall back to fnm's default alias.
    $codexCommand = (Get-Command codex.cmd -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $codexCommand -and (Test-Path "$env:APPDATA\fnm\aliases\default\codex.cmd")) { $codexCommand = "$env:APPDATA\fnm\aliases\default\codex.cmd" }
}

# Run a helper script in the backend's bash. Leave the output unpiped for fzf so the
# console stays attached (see the fzf notes below).
function Invoke-Bash {
    if ($backend -eq 'wsl') { wsl.exe -d $distro -- bash @args } else { & $gitBash @args }
}

# Commands run in Bash under WSL and PowerShell on Windows; each needs its own
# single-quote escaping before wt.exe receives the complete command string.
function New-BashCommand([string[]]$arguments) {
    $commandArgs = if ($backend -eq 'windows') { @($gitBash) + $arguments } else { $arguments }
    $quoted = foreach ($argument in $commandArgs) {
        $escaped = if ($backend -eq 'wsl') { $argument.Replace("'", "'\''") } else { $argument.Replace("'", "''") }
        "'$escaped'"
    }
    $prefix = if ($backend -eq 'wsl') { 'bash ' } else { '& ' }
    $prefix + ($quoted -join ' ')
}

function Invoke-Git {
    if ($backend -eq 'wsl') { wsl.exe -d $distro -- git @args } else { git @args }
}
$sessDir  = "$codex\sessions"
$indexFile = "$codex\session_index.jsonl"
$hubStateDir = Join-Path $env:LOCALAPPDATA 'AgentSessionHub'
$hiddenSessionsFile = Join-Path $hubStateDir 'hidden-codex-session-ids.txt'

# Locate wt.exe (may not be on PATH depending on launch context)
$wt = Get-Command wt.exe -ErrorAction SilentlyContinue
if ($wt) { $wt = $wt.Source } else { $wt = "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe" }
$wtWindow = if ($env:AGENT_SESSION_HUB_WINDOW) { $env:AGENT_SESSION_HUB_WINDOW } else { '0' }

# wt.exe splits its whole command line on ';' (titles and paths too), so a title such as
# "a; b" opens several broken tabs. '\;' is wt's literal semicolon.
function Open-WtTab($title, $cwd, $command) {
    if ($backend -eq 'wsl') {
        & $wt -w $wtWindow new-tab --title ($title -replace ';', '\;') `
            wsl.exe -d $distro --cd ($cwd -replace ';', '\;') -- bash -lic ($command -replace ';', '\;')
    } else {
        & $wt -w $wtWindow new-tab --title ($title -replace ';', '\;') -d ($cwd -replace ';', '\;') `
            $tabShell -NoLogo -Command ($command -replace ';', '\;')
    }
    Start-Sleep -Milliseconds 300   # let wt register each tab before the next
}

$hubTool = 'codex'
. (Join-Path $PSScriptRoot 'handoff-sync.ps1')

# Use the LINUX fzf inside WSL, not fzf.exe: the Windows build mis-parses Windows
# Terminal mouse sequences (wheel scrolls arrive as left-clicks), which made scrolling
# open sessions. The Linux build parses mouse input correctly, so the wheel scrolls
# and left-clicks stay left-clicks.
#
# CRITICAL plumbing detail: fzf must NOT be piped through wsl.exe's stdin/stdout.
# A redirected stream stops wsl.exe from relaying the console, so fzf renders once
# and then never sees keyboard/mouse/resize (it "freezes"). Instead the list and the
# pick travel via temp files and all console streams stay attached. A bash wrapper
# script (not bash -c "...") avoids wsl.exe mangling quoted arguments.
# Resolve fzf inside WSL: prefer whatever's on the login-shell PATH (apt installs it at
# /usr/bin/fzf), fall back to the per-user ~/.local/bin location. Works regardless of how
# fzf was installed. NOTE: it must be the Linux build, not fzf.exe (see below).
#
# The windows backend has no Linux fzf, so it uses fzf.exe from the PATH, through the
# fzf-win.sh wrapper written below.

# fzf-win.sh: the windows backend's stand-in for the Linux fzf, used by every picker below.
# fzf.exe's default full-screen renderer takes mouse input as console records, and the
# console keeps its own button state: the click that opens a row exits fzf on the PRESS,
# the release never reaches the console, and from then on every mouse move and wheel tick
# in the next picker carries a held left button -- fzf sees left-clicks and the click
# binds open whatever row is under the pointer. Any --height other than 100% selects the
# light renderer instead, which reads Windows Terminal's VT mouse reports directly, exactly
# like the Linux build under WSL, so presses and releases come from the terminal itself.
# -1 is the full window minus one line. That renderer maps click rows from the console
# cursor position, which is wrong below earlier output, hence homing and clearing first.
# fzf.exe runs bind commands through cmd unless told otherwise, and the click binds below
# are bash; it splits --with-shell on spaces, hence the space-free 8.3 path of Git's bash.
if ($backend -eq 'windows') {
    $fzfBash = (New-Object -ComObject Scripting.FileSystemObject).GetFile((Join-Path $env:ProgramFiles 'Git\usr\bin\bash.exe')).ShortPath -replace '\\','/'
    $fzfPath = "$tmpWsl/fzf-win.sh"
    $fzfWinSh = @"
#!/bin/bash
printf '\033[H\033[2J' >&2
exec fzf --height=-1 --with-shell='$fzfBash -c' "`$@"
"@ -replace "`r`n","`n"
    [System.IO.File]::WriteAllText((Join-Path $tmpWin 'fzf-win.sh'), $fzfWinSh)
}
$listWin = Join-Path $tmpWin 'list.txt';  $listWsl = "$tmpWsl/list.txt"
$pickWin = Join-Path $tmpWin 'pick.txt';  $pickWsl = "$tmpWsl/pick.txt"
$fzfShWin = Join-Path $tmpWin 'fzf.sh';   $fzfShWsl = "$tmpWsl/fzf.sh"
$showListWin = Join-Path $tmpWin 'show-list.txt'; $showListWsl = "$tmpWsl/show-list.txt"
$showPickWin = Join-Path $tmpWin 'show-pick.txt'; $showPickWsl = "$tmpWsl/show-pick.txt"
$showShWin = Join-Path $tmpWin 'show.sh'; $showShWsl = "$tmpWsl/show.sh"
# Click-to-highlight, click-again-to-open -- shared by both pickers below.
#
# Single source of truth for "which row is highlighted": fzf's own focus. The focus event
# fires only when the highlight actually moves (click, wheel, arrows, filtering) and is
# the ONLY writer of the state file, which therefore always mirrors the highlighted index.
# left-click just READS it: if the clicked row is already the highlighted one, open it;
# otherwise do nothing -- fzf has already moved the highlight to the clicked row by the
# time the bind runs, and focus records the new index. So the second click on a row opens
# it, and moving the highlight away (e.g. scrolling) makes the next click a highlight
# again. Unlike fzf's double-click there's no timing window and no mouse-drift limit.
#
# transform (not execute-silent) keeps the writes synchronous with fzf's event handling,
# so a fast click can't race a pending focus write. The file lives in the WSL-local /tmp
# (not $tmpWsl on /mnt/c) because it's written on every focus change and 9p is slow.
# Focus fires on start, so the per-process file cannot go stale within this picker.
$clickStateWsl = "/tmp/recent-codex-$PID-click.state"
$clickBinds = (@"
    --bind "focus:transform:echo {n} > $clickStateWsl" \
    --bind "left-click:transform:if [ \"\`$(cat $clickStateWsl 2>/dev/null)\" = \"{n}\" ]; then echo accept; fi" \
"@ -replace "`r`n","`n")

# --expect makes fzf print the pressed key as the FIRST line of the pick file (an empty
# first line for a plain Enter/click accept), so one picker can mean several things:
# open in codex, hand the session off to claude/opencode, copy it, or hide it from this picker.
$expectKeys = @($(if ($claudeEnabled) { 'alt-c' }), $(if ($claudeWorkEnabled) { 'alt-w' }), $(if ($opencodeEnabled) { 'alt-o' }), 'alt-f', 'alt-h', 'alt-s') -join ','
$headerActions = @('enter: open', 'tab: mark', $(if ($claudeEnabled) { 'alt-c: claude' }), $(if ($claudeWorkEnabled) { 'alt-w: claude-work' }), $(if ($opencodeEnabled) { 'alt-o: opencode' }), 'alt-f: copy', 'alt-h: hide', 'alt-s: show', 'esc: reload') -join ' | '
$fzfSh = @"
#!/bin/bash
# `$1 = list file (CRLF from PowerShell -- strip CRs), `$2 = pick output file
tr -d '\r' < "`$1" | "$fzfPath" \
    --with-nth=1 --delimiter=`$'\t' \
    --multi \
    --expect=$expectKeys \
$clickBinds
    --prompt='codex sessions> ' --reverse \
    --header='$headerActions' \
    > "`$2"
"@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($fzfShWin, $fzfSh)

$showSh = @"
#!/bin/bash
tr -d '\r' < "`$1" | "$fzfPath" \
    --with-nth=1 --delimiter=`$'\t' \
    --multi \
$clickBinds
    --prompt='hidden codex sessions> ' --reverse \
    --header='enter: show | tab: mark multiple | esc: cancel' \
    > "`$2"
"@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($showShWin, $showSh)

# scan.sh: enumerate top-level transcripts natively (find over \\wsl$ from Windows is
# slow, and wsl.exe mangles backslash escapes like \t when passed as arguments -- a
# script file keeps them intact). Approval reviewers and other internal agents are stored
# beside real sessions. Reject child metadata generically as well as both the older
# "subagent" and newer "guardian_review" labels, so internal UUIDs never become rows, and
# headless codex exec runs (source "exec") as well.
# Emits "epoch-mtime<TAB>linux-path".
$scanShWin = Join-Path $tmpWin 'scan.sh'; $scanShWsl = "$tmpWsl/scan.sh"
$scanSh = @"
#!/bin/bash
if [ "`$1" = all ]; then
    find "$bashHome/.codex/sessions" -name '*.jsonl' -printf '%T@\t%p\n' 2>/dev/null
else
    find "$bashHome/.codex/sessions" -name '*.jsonl' -mtime -40 -printf '%T@\t%p\n' 2>/dev/null
fi |
while IFS=`$'\t' read -r session_mtime session_path; do
    if ! head -n 1 "`$session_path" | grep -Eq '"parent_thread_id":|"source":(\{"subagent":|"exec")|"thread_source":"(subagent|guardian_review)"'; then
        printf '%s\t%s\n' "`$session_mtime" "`$session_path"
    fi
done |
    sort -rn
"@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($scanShWin, $scanSh)

# Current Codex stores user-assigned conversation names in state_*.sqlite. Read that
# store read-only so explicit renames take precedence over the legacy JSONL index and
# transcript-derived fallbacks. Keeping the query in a script file avoids cross-shell
# quoting problems between Windows PowerShell, wsl.exe, and Python.
$titleScanWin = Join-Path $tmpWin 'titles.py'; $titleScanWsl = "$tmpWsl/titles.py"
$titleScan = @'
import glob
import os
import sqlite3
import sys

databases = glob.glob(os.path.join(sys.argv[1], "state_*.sqlite"))
if databases:
    database = max(databases, key=os.path.getmtime)
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    for session_id, name in connection.execute(
        "SELECT id, name FROM threads WHERE name IS NOT NULL AND trim(name) <> ''"
    ):
        clean_name = name.replace("\t", " ").replace("\r", " ").replace("\n", " ")
        print(f"{session_id}\t{clean_name}")
'@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($titleScanWin, $titleScan)

# Perform the app-server handshake in Python on the backend's side. PowerShell's
# asynchronous reads from a redirected wsl.exe pipe can time out even though app-server
# answers immediately; a native pipe keeps the protocol deterministic and bounded. A reader
# thread (not select, which Windows only supports on sockets) bounds each wait.
# Args: thread id, name, then the app-server command (default: codex via the login shell).
$titleSetWin = Join-Path $tmpWin 'set-title.py'; $titleSetWsl = "$tmpWsl/set-title.py"
$titleSet = @'
import json
import queue
import subprocess
import sys
import threading
import time

process = subprocess.Popen(
    sys.argv[3:] or ["bash", "-lic", "codex app-server"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    text=True,
    encoding="utf-8",
    bufsize=1,
)
lines = queue.Queue()

def read_lines():
    for line in process.stdout:
        lines.put(line)
    lines.put(None)

threading.Thread(target=read_lines, daemon=True).start()

def send(message):
    process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
    process.stdin.flush()

def wait_for(response_id, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            line = lines.get(timeout=max(0, deadline - time.monotonic()))
        except queue.Empty:
            break
        if line is None:
            break
        try:
            response = json.loads(line)
        except json.JSONDecodeError:
            continue
        if response.get("id") == response_id:
            if response.get("error"):
                raise RuntimeError(response["error"].get("message", "app-server request failed"))
            return
    raise TimeoutError(f"timed out waiting for app-server response {response_id}")

try:
    send({"id": 1, "method": "initialize", "params": {
        "clientInfo": {"name": "agent-session-hub", "title": "Agent Session Hub", "version": "1"},
        "capabilities": None,
    }})
    wait_for(1)
    send({"method": "initialized"})
    send({"id": 2, "method": "thread/name/set", "params": {
        "threadId": sys.argv[1], "name": sys.argv[2],
    }})
    wait_for(2)
    # The response can precede the durable update notification. Keep app-server alive
    # long enough to commit the new name before terminating the helper process.
    time.sleep(1)
finally:
    process.terminate()
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        process.kill()
'@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($titleSetWin, $titleSet)

# --- New-session support -----------------------------------------------------------
# Root that the folder picker lists (immediate subfolders become new-session choices).
# Its first row can also create an initialized local Git project under this root.
# Override with $env:CODEX_NEW_ROOT or $env:AGENT_HUB_NEW_ROOT (a Windows path). WSL path derived like $tmpWsl.
$newRoot    = if ($env:CODEX_NEW_ROOT) { $env:CODEX_NEW_ROOT } elseif ($env:AGENT_HUB_NEW_ROOT) { $env:AGENT_HUB_NEW_ROOT } else { 'C:\G\code' }
$newRootWsl = ConvertTo-WslPath $newRoot
$dirListWin = Join-Path $tmpWin 'dirs.txt'; $dirListWsl = "$tmpWsl/dirs.txt"

# scandir.sh: list immediate subfolders of the root as "name<TAB>linux-path".
$scanDirShWin = Join-Path $tmpWin 'scandir.sh'; $scanDirShWsl = "$tmpWsl/scandir.sh"
$scanDirSh = @"
#!/bin/bash
find "$newRootWsl" -mindepth 1 -maxdepth 1 -type d -printf '%f\t%p\n' 2>/dev/null | sort -f
"@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($scanDirShWin, $scanDirSh)

# fzfdir.sh: same plumbing and same $clickBinds as fzf.sh, different prompt/header.
# `$3 is the tool being started ('codex' or 'claude') -- it only ever labels the prompt,
# so the same picker serves both.
$fzfDirShWin = Join-Path $tmpWin 'fzfdir.sh'; $fzfDirShWsl = "$tmpWsl/fzfdir.sh"
$fzfDirSh = @"
#!/bin/bash
tr -d '\r' < "`$1" | "$fzfPath" \
    --with-nth=1 --delimiter=`$'\t' \
$clickBinds
    --prompt="new `$3 session in> " --reverse \
    --header="click to highlight, click again to start a new `$3 session here | esc: cancel" \
    > "`$2"
"@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($fzfDirShWin, $fzfDirSh)
# -----------------------------------------------------------------------------------

# --- Transcript backup -------------------------------------------------------------
# The transcripts under ~/.codex/sessions are the main record of past conversations and
# they live inside the WSL VHD, so snapshots are written to the WINDOWS side: they then
# survive `wsl --unregister`, a VHD corruption, or a distro rebuild. ~1.7s and ~26MB per
# snapshot at 100MB of transcripts, so it runs inline at startup rather than in the
# background. Override the location with $env:CODEX_BACKUP_DIR.
$backupDir    = if ($env:CODEX_BACKUP_DIR) { $env:CODEX_BACKUP_DIR } else { Join-Path $PSScriptRoot 'backups\codex' }
$backupDirWsl = ConvertTo-WslPath $backupDir
$backupEvery  = 24   # hours between snapshots
$backupKeep   = 10   # snapshots retained; older ones are pruned

# backup.sh: throttle, snapshot, prune. All three decisions are driven by ONE source of
# truth -- the snapshot filenames themselves (codex-history-<stamp>.tar.gz). The stamp
# says when that snapshot was taken, so "is the newest one older than $backupEvery" and
# "which are the oldest to prune" are both answered by sorting the names; no sidecar
# timestamp file to drift out of sync, and the format sorts chronologically as text.
# mtime is deliberately NOT consulted: copying a backup would rewrite it, the name survives.
$backupShWin = Join-Path $tmpWin 'backup.sh'; $backupShWsl = "$tmpWsl/backup.sh"
$backupSh = @"
#!/bin/bash
# `$1 = backup dir (Linux path). Prints the snapshot it made, or nothing if none was due.
dir="`$1"
interval=`$(( $backupEvery * 3600 ))
mkdir -p "`$dir" 2>/dev/null || exit 0

newest=`$(ls -1 "`$dir"/codex-history-*.tar.gz 2>/dev/null | sort | tail -1)
if [ -n "`$newest" ]; then
    ts=`${newest##*/codex-history-}; ts=`${ts%.tar.gz}
    last=`$(date -d "`${ts:0:4}-`${ts:4:2}-`${ts:6:2} `${ts:9:2}:`${ts:11:2}:`${ts:13:2}" +%s 2>/dev/null)
    # Unparsable name (hand-renamed?) -> treat as no backup and take one; better an extra
    # snapshot than a skipped one.
    [ -n "`$last" ] && [ `$(( `$(date +%s) - last )) -lt "`$interval" ] && exit 0
fi

out="`$dir/codex-history-`$(date +%Y%m%d-%H%M%S).tar.gz"
cd "`$HOME/.codex" 2>/dev/null || exit 0
set -- sessions
[ -f session_index.jsonl ] && set -- "`$@" session_index.jsonl
[ -f history.jsonl ] && set -- "`$@" history.jsonl   # the prompt history, same category, tiny

# Write aside, then rename: the glob above only ever sees finished snapshots, so an
# interrupted run can't pass a truncated file off as recent and suppress the next 5h.
# tar exits 1 for warnings alone -- a live session appending to a .jsonl mid-read is
# expected here and yields a good-enough snapshot; only a fatal 2 aborts the rename.
tar --warning=no-file-changed -czf "`$out.part" "`$@" 2>/dev/null
[ `$? -ge 2 ] && { rm -f "`$out.part"; exit 0; }
mv -f "`$out.part" "`$out" || exit 0
echo "`$out"

# Prune oldest-first, keeping the newest $backupKeep.
ls -1 "`$dir"/codex-history-*.tar.gz 2>/dev/null | sort | head -n -$backupKeep | xargs -r rm -f
"@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($backupShWin, $backupSh)

# Runs once per launch; backup.sh itself decides whether one is actually due.
function Invoke-Backup {
    Write-Host "Checking transcript backup..." -NoNewline
    $made = @(Invoke-Bash $backupShWsl $backupDirWsl | Where-Object { $_ })
    Write-Host "`r                             `r" -NoNewline
    if ($made) {
        $f = Get-Item (Join-Path $backupDir (Split-Path $made[-1] -Leaf)) -ErrorAction SilentlyContinue
        if ($f) { Write-Host ("Backed up transcripts -> {0} ({1:N0} MB)" -f $f.Name, ($f.Length/1MB)) }
    }
}
# -----------------------------------------------------------------------------------

# Human-readable age: minutes under an hour, hours under 2 days, days under 2 weeks, then weeks
function Format-Age($lastWrite) {
    $span = (Get-Date) - $lastWrite
    if ($span.TotalHours -lt 1)  { return "{0}m" -f [int]$span.TotalMinutes }
    if ($span.TotalHours -lt 48) { return "{0}h" -f [int]$span.TotalHours }
    if ($span.TotalDays  -lt 14) { return "{0}d" -f [int]$span.TotalDays }
    return "{0}w" -f [int]($span.TotalDays / 7)
}

# Parsed-transcript cache: full read of every .jsonl over \\wsl$ costs ~10s,
# so keep {cwd,titles} per file and only re-parse when the mtime changes.
$cacheFile = Join-Path $env:TEMP 'recent-codex-cache-v4.json'
$cache = @{}
if (Test-Path $cacheFile) {
    try {
        (Get-Content $cacheFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object {
            $cache[$_.Name] = $_.Value
        }
    } catch {}
}

# Ignore host-injected XML-style records when deriving a title from user messages.
function Get-TitleCandidate($text) {
    if (-not ($text -is [string])) { return $null }
    $candidate = $text.Trim()
    if (-not $candidate) { return $null }
    if ($candidate -match '(?s)^<[^>\r\n]+>') { return $null }
    if ($candidate -match '(?is)^# AGENTS\.md instructions\b') { return $null }
    # Repair the common UTF-8-as-Windows-1252 corruption produced by older picker
    # versions (for example, "â€¢" -> "•" and "â€™" -> "’").
    if ($candidate -match '[\u00E2\u00C3\u00C2].') {
        try {
            $candidate = [System.Text.Encoding]::UTF8.GetString(
                [System.Text.Encoding]::GetEncoding(1252).GetBytes($candidate)
            )
        } catch {}
    }
    return $candidate
}

function Get-SafeTabTitle($title) {
    if (-not $title) { return $null }
    # Never give wt.exe an unbounded transcript as the --title argument.
    $safeTitle = $title.Trim()
    if ($safeTitle.Length -gt 80) { $safeTitle = $safeTitle.Substring(0, 80).TrimEnd() }
    return $safeTitle
}

# Give Codex's live thread store the same title shown by the picker. Current Codex reads
# dynamic terminal titles from that store (not session_index.jsonl), so use its supported
# app-server API rather than editing the SQLite database behind a running CLI.
function Set-CodexThreadTitle($id, $title) {
    if (-not $id -or -not $title -or $title -like 'Untitled session in *') { return }
    try {
        if ($backend -eq 'wsl') { & wsl.exe -d $distro -- python3 $titleSetWsl $id $title }
        elseif ($codexCommand) { & python $titleSetWin $id $title $codexCommand app-server }
        else { throw 'codex.cmd not found' }
        if ($LASTEXITCODE -ne 0) { throw "title helper exited with code $LASTEXITCODE" }
    } catch {
        Write-Host "Could not set Codex conversation title: $($_.Exception.Message)"
        Start-Sleep -Milliseconds 900
    }
}

function Get-HiddenSessionIds {
    $hidden = @{}
    if (Test-Path $hiddenSessionsFile) {
        try {
            foreach ($line in [SharedFile]::ReadLines($hiddenSessionsFile)) {
                $id = $line.Trim()
                if ($id -match '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') {
                    $hidden[$id.ToLowerInvariant()] = $true
                }
            }
        } catch {}
    }
    return $hidden
}

function Hide-Sessions($rows) {
    $hidden = Get-HiddenSessionIds
    $ids = @(foreach ($row in $rows) {
        $parts = $row -split "`t"
        $id = $parts[1]
        if ($id -and $id -ne '__NEW__' -and -not $hidden.ContainsKey($id.ToLowerInvariant())) { $id }
    })
    if (-not $ids) { return }
    New-Item -ItemType Directory -Path $hubStateDir -Force | Out-Null
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($hiddenSessionsFile, (($ids -join "`n") + "`n"), $utf8NoBom)
}

function Show-HiddenSessions {
    $rows = @(Get-Sessions 'hidden')
    if (-not $rows) {
        Write-Host "No hidden Codex conversations found."
        Start-Sleep -Milliseconds 900
        return
    }
    [System.IO.File]::WriteAllLines($showListWin, [string[]]$rows)
    Remove-Item $showPickWin -ErrorAction SilentlyContinue
    Invoke-Bash $showShWsl $showListWsl $showPickWsl
    $picked = @(if (Test-Path $showPickWin) { Get-Content $showPickWin | Where-Object { $_ } })
    if (-not $picked) { return }
    $selected = @{}
    foreach ($row in $picked) {
        $id = ($row -split "`t")[1]
        if ($id) { $selected[$id.ToLowerInvariant()] = $true }
    }
    if (-not (Test-Path $hiddenSessionsFile)) { return }
    $remaining = @(foreach ($line in [SharedFile]::ReadLines($hiddenSessionsFile)) {
        $id = $line.Trim()
        if (-not $id -or -not $selected.ContainsKey($id.ToLowerInvariant())) { $line }
    })
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($hiddenSessionsFile, [string[]]$remaining, $utf8NoBom)
}

function Get-Sessions($visibility = 'visible') {
    $hiddenIds = Get-HiddenSessionIds
    $emittedIds = @{}
    # Explicit names in Codex's current live store are authoritative. Failure to read
    # the store is non-fatal; older installs can still use the index/transcript paths.
    $liveTitles = @{}
    try {
        $(if ($backend -eq 'wsl') { wsl.exe -d $distro -- python3 $titleScanWsl "/home/$wslUser/.codex" }
          else { python $titleScanWin $codex }) |
            ForEach-Object {
                $nameParts = $_ -split "`t", 2
                if ($nameParts.Count -eq 2) {
                    $candidate = Get-TitleCandidate $nameParts[1]
                    if ($candidate) { $liveTitles[$nameParts[0]] = $candidate }
                }
            }
    } catch {}

    # sessionId -> title from Codex's index. Use the last entry if a title was updated.
    $titles = @{}
    if (Test-Path $indexFile) {
        foreach ($line in [SharedFile]::ReadLines($indexFile)) {
            if (-not $line.Trim()) { continue }
            try {
                $s = $line | ConvertFrom-Json
                if ($s.id -and $s.thread_name) { $titles[$s.id] = $s.thread_name }
            } catch {}
        }
    }

    # Gather top-level sessions updated within 40 days (excluding subagent sidechains),
    # enumerated natively inside WSL by scan.sh: "epoch-mtime<TAB>linux-path" per line.
    $scanMode = if ($visibility -eq 'hidden') { 'all' } else { 'recent' }
    Invoke-Bash $scanShWsl $scanMode |
        ForEach-Object {
            $epoch, $linuxPath = $_ -split "`t"
            $winPath   = ConvertFrom-WslPath $linuxPath
            $lastWrite = [DateTimeOffset]::FromUnixTimeSeconds([long][double]$epoch).LocalDateTime
            $base = [System.IO.Path]::GetFileNameWithoutExtension($linuxPath)
            $id = if ($base -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$') {
                $Matches[1]
            } else {
                $base
            }
            $normalizedId = $id.ToLowerInvariant()
            $isHidden = $hiddenIds.ContainsKey($normalizedId)
            if (($visibility -eq 'hidden') -ne $isHidden) { return }
            if ($emittedIds.ContainsKey($normalizedId)) { return }
            $emittedIds[$normalizedId] = $true

            # One pass over the transcript: cwd + fallback title from the first user turn.
            # Skipped entirely when the cached entry's mtime still matches.
            $mtime = $epoch
            $c = $cache[$winPath]
            if ($c -and "$($c.mtime)" -eq $mtime) {
                $cwd = $c.cwd; $fallback = $c.fallback
            } else {
                $cwd = $null; $fallback = $null; $transitionSource = $null; $transitionTitle = $null
                foreach ($line in [SharedFile]::ReadLines($winPath)) {
                    try { $d = $line | ConvertFrom-Json } catch { continue }
                    if (-not $cwd -and $d.type -eq 'session_meta') { $cwd = $d.payload.cwd }
                    if (-not $fallback -and $d.type -eq 'response_item' -and $d.payload.type -eq 'message' -and $d.payload.role -eq 'user') {
                        $text = Get-MessageText $d.payload
                        if ($text -and -not (Test-InjectedUserText $text)) {
                            $fallback = Get-TitleCandidate $text
                            if ($fallback -match '^\[Transitioned from (Claude|OpenCode); inherited title: (.*?)\]') {
                                $transitionSource = $Matches[1]; $transitionTitle = $Matches[2]
                            }
                        }
                    }
                    if ($cwd -and $fallback) { break }
                }
                $cache[$winPath] = @{ mtime = $mtime; cwd = $cwd; fallback = $fallback
                                      transitionSource = $transitionSource; transitionTitle = $transitionTitle }
            }
            if (-not $cwd) { return }

            # Title priority: current explicit name > legacy/derived names > placeholder.
            if ($c -and "$($c.mtime)" -eq $mtime) {
                $transitionSource = $c.transitionSource; $transitionTitle = $c.transitionTitle
            }
            $hasLiveTitle = $liveTitles.ContainsKey($id)
            $title = Get-TitleCandidate $(if ($hasLiveTitle) { $liveTitles[$id] } elseif ($transitionTitle) { $transitionTitle } else { $titles[$id] })
            $folder = (($cwd -replace '\\','/') -split '/' | Select-Object -Last 2) -join '/'
            if (-not $title) { $title = Get-TitleCandidate $(if ($fallback) { $fallback } else { "Untitled session in $folder" }) }
            $title = $title -replace '\\"','"'
            $title = $title -replace '\\[nrt]',' ' -replace '\s+',' '
            $handoffTitle = $title
            if ($transitionSource) { $title = "From ${transitionSource}: $title" }
            $tabTitle = Get-SafeTabTitle $title
            $displayTitle = $tabTitle
            if ($displayTitle.Length -gt 50) { $displayTitle = $displayTitle.Substring(0,50) }

            $age    = Format-Age $lastWrite
            $shortId = ($id -split '-')[-1]

            # Only col 1 is shown. The final hidden flag prevents resume from replacing
            # an explicit Codex rename with a transcript-derived fallback.
            "{0} - {1} - {2} ago [..-{3}]`t{4}`t{5}`t{6}`t{7}`t{8}`t{9}" -f $folder, $displayTitle, $age, $shortId, $id, $cwd, $winPath, $handoffTitle, $tabTitle, ([int]$hasLiveTitle)
        }

    try { $cache | ConvertTo-Json -Depth 3 | Set-Content $cacheFile } catch {}
}

# Keep the picker alive on a cached list: opening a tab leaves the same sessions on
# screen (no rescan, no reshuffle). Esc reloads the whole script so code changes are picked up; close the
# window to quit. Scan up front, then restart the script when Esc asks for it.
# Synthetic first row: picking it (id __NEW__) triggers the folder picker below --
# with codex on enter/click, or a transfer target on its hotkey, same as the session rows.
$newTargets = @($(if ($claudeEnabled) { 'alt-c: claude' }), $(if ($claudeWorkEnabled) { 'alt-w: claude-work' }), $(if ($opencodeEnabled) { 'alt-o: opencode' })) -join ' | '
$newRow = if ($newTargets) { "+ New session (choose folder)...  [enter: codex | $newTargets]`t__NEW__`t`t" } else { "+ New session (choose folder)...  [enter: codex]`t__NEW__`t`t" }

function Restart-Script {
    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    if (-not $scriptPath) { Write-Host "Cannot reload: script path is unknown"; Start-Sleep -Milliseconds 900; return }
    Write-Host "Reloading script..."
    # Re-detect CLIs so a tool installed since the hub launched appears.
    $env:AGENT_HUB_AVAILABLE_TOOLS = $null
    $reloadArgs = @($script:recentScriptArgs)
    & powershell.exe -NoExit -ExecutionPolicy Bypass -File $scriptPath @reloadArgs
    exit
}
function Update-List {
    Write-Host "Scanning sessions..." -NoNewline
    $s = Get-Sessions
    Write-Host "`r                       `r" -NoNewline
    $rows = @($newRow) + @($s)
    [System.IO.File]::WriteAllLines($listWin, [string[]]$rows)
    return $s
}

# Folder picker for a brand-new session: list $newRoot first, then its subfolders, and
# open the chosen one as a fresh session (no resume) in its own Windows Terminal tab.
# $tool ('codex', 'claude', 'opencode') is the ONLY difference between the flows -- it labels
# the picker and is the command the tab runs -- so all share this one function.
function Invoke-NewSession($tool) {
    $dirs = Invoke-Bash $scanDirShWsl
    $rootName = Split-Path ($newRoot.TrimEnd('\')) -Leaf
    $rootRow = "$rootName/ (project root)`t$newRootWsl`t$rootName"
    $createRow = "+ Create new project folder...`t__CREATE__"
    [System.IO.File]::WriteAllLines($dirListWin, [string[]](@($rootRow, $createRow) + @($dirs)))
    Remove-Item $pickWin -ErrorAction SilentlyContinue
    Invoke-Bash $fzfDirShWsl $dirListWsl $pickWsl $tool
    # @() must wrap the whole pipeline: Where-Object unwraps a single match back to a
    # scalar string, and $p[0] on a string yields its first CHARACTER -- which made
    # $path null, PowerShell dropped the arg, and wsl saw "--cd --" (Wsl/E_INVALIDARG).
    $p = @(if (Test-Path $pickWin) { Get-Content $pickWin | Where-Object { $_ } })
    if (-not $p) { return }   # Esc in the folder picker: cancel, back to the session list
    $cols = $p[0] -split "`t"
    $name = if ($cols.Count -gt 2 -and $cols[2]) { $cols[2] } else { $cols[0] }
    $path = $cols[1]
    # Windows tabs start in a Windows folder; WSL tabs take the Linux path as listed.
    if ($backend -eq 'windows' -and $path -and $path -ne '__CREATE__') { $path = ConvertFrom-WslPath $path }
    if ($path -eq '__CREATE__') {
        $name = (Read-Host "New project folder name under $newRoot").Trim()
        if (-not $name) { return }
        $baseName = ($name -split '\.')[0]
        if ($name -in @('.', '..') -or $name -match '[<>:"/\\|?*\x00-\x1F]' -or $name -match '[. ]$' -or
            $baseName -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
            Write-Host "Invalid folder name: $name"; Start-Sleep -Milliseconds 900; return
        }
        $newPathWin = Join-Path $newRoot $name
        if (Test-Path $newPathWin) {
            Write-Host "Folder already exists: $newPathWin"; Start-Sleep -Milliseconds 900; return
        }
        New-Item -ItemType Directory -Path $newPathWin | Out-Null
        $path = if ($backend -eq 'wsl') { ConvertTo-WslPath $newPathWin } else { $newPathWin }
        $instructions = @'
# Agent Instructions

Keep `AGENTS.md` and `CLAUDE.md` synchronized whenever either instruction file changes.

## Local Commit Policy

After every completed repository change, automatically create a local Git commit with a concise, meaningful message describing the result. Do not wait for a separate request. Keep commits focused, verify the staged diff, and never push to an origin or other remote unless the user explicitly requests it.
'@ -replace "`r`n","`n"
        [System.IO.File]::WriteAllText((Join-Path $newPathWin 'AGENTS.md'), $instructions)
        [System.IO.File]::WriteAllText((Join-Path $newPathWin 'CLAUDE.md'), $instructions)
        Invoke-Git -C $path init --initial-branch=main
        if ($LASTEXITCODE -ne 0) { Write-Host "Could not initialize Git in $newPathWin"; Start-Sleep -Milliseconds 900; return }
        Invoke-Git -C $path add AGENTS.md CLAUDE.md
        if ($LASTEXITCODE -ne 0) { Write-Host "Could not stage project instructions"; Start-Sleep -Milliseconds 900; return }
        Invoke-Git -C $path commit -m "Initialize project instructions"
        if ($LASTEXITCODE -ne 0) { Write-Host "Could not create the initial commit; check your Git user configuration"; Start-Sleep -Milliseconds 1200; return }
    }
    if (-not $path) { Write-Host "Could not parse folder pick: $($p[0])"; Start-Sleep -Milliseconds 800; return }
    $title = if ($tool -eq 'codex') { $name } else { "${tool}: $name" }
    $command = if ($tool -in @('claude', 'claude-work')) { New-HubClaudeCommand 'claude' $(if ($tool -eq 'claude-work') { 'work' } else { 'personal' }) } elseif ($tool -eq 'codex') { 'codex -c tui.fullscreen_transcript=false' } else { $tool }
    Open-WtTab $title $path $command
}

# Text of a transcript record, whatever content shape Codex used: a plain string, or a
# list of typed parts (`input_text`/`output_text`/`text`).
function Get-MessageText($payload) {
    $content = $(if ($null -ne $payload.content) { $payload.content } else { $payload.output })
    if ($content -is [string]) { return $content.Trim() }
    return ((@($content | ForEach-Object { $_.text } | Where-Object { $_ }) -join "`n").Trim())
}

# Codex injects AGENTS.md/instruction/context blocks as user turns; they are setup, not chat.
function Test-InjectedUserText($text) {
    return ($text -match '^\s*<(environment_context|user_instructions|skills_instructions|instructions)\b' -or
            $text -match '^\s*#\s+\S+\.md instructions\b')
}

# Read a transcript as an ordered list of chat messages: @{ Role='User'|'Codex'; Body=... }.
#
# Chat extraction for formatted clipboard exports. Transfers use handoff-sync.ps1.
#
# What survives: user messages and Codex user-facing messages, in order. What's dropped,
# deliberately: tool calls/outputs, reasoning, token counters, task state, and the context
# blocks Codex injects as user turns -- so what's left is the intent/decisions/dead-ends
# that only exist in the conversation.
#
# Read from `response_item` messages, not the `event_msg` chat events: those events were
# renamed (`user_message`/`agent_message` -> `item_completed`) in newer Codex builds, while
# response_item messages are the same shape in old and new transcripts.
function Get-ChatMessages($transcript) {
    $msgs = New-Object System.Collections.ArrayList
    foreach ($line in [SharedFile]::ReadLines($transcript)) {
        if (-not $line.Trim()) { continue }
        try { $d = $line | ConvertFrom-Json } catch { continue }
        if ($d.type -ne 'response_item' -or $d.payload.type -ne 'message') { continue }
        $role = "$($d.payload.role)"
        if ($role -ne 'user' -and $role -ne 'assistant') { continue }

        $body = Get-MessageText $d.payload
        if (-not $body) { continue }
        if ($role -eq 'user' -and (Test-InjectedUserText $body)) { continue }

        [void]$msgs.Add([pscustomobject]@{
            Role = $(if ($role -eq 'user') { 'User' } else { 'Codex' })
            Body = $body
        })
    }
    return $msgs
}

# Compact state pack for formatted clipboard exports; verify snapshots against live files.
function Get-HandoffStateMarkdown($transcript, $label) {
    $lastUser = $null; $lastAgent = $null
    $calls = New-Object System.Collections.ArrayList
    $files = New-Object System.Collections.ArrayList
    $snips = New-Object System.Collections.ArrayList

    foreach ($line in [SharedFile]::ReadLines($transcript)) {
        if (-not $line.Trim()) { continue }
        try { $d = $line | ConvertFrom-Json } catch { continue }
        if ($d.type -eq 'response_item' -and $d.payload.type -eq 'message') {
            $text = Get-MessageText $d.payload
            if ($text) {
                if ($d.payload.role -eq 'user' -and -not (Test-InjectedUserText $text)) { $lastUser = $text }
                elseif ($d.payload.role -eq 'assistant') { $lastAgent = $text }
            }
        }
        # Newer Codex builds report edits only as item_completed/FileChange events.
        if ($d.type -eq 'event_msg' -and $d.payload.type -eq 'item_completed' -and $d.payload.item.type -eq 'FileChange') {
            foreach ($f in $d.payload.item.changes.PSObject.Properties.Name) { [void]$files.Add($f) }
        }
        # Tool calls: `function_call`/`arguments` in older transcripts, `custom_tool_call`/`input` in newer.
        if ($d.type -eq 'response_item' -and $d.payload.type -in @('function_call', 'custom_tool_call')) {
            $name = "$($d.payload.name)"
            $args = "$(if ($d.payload.arguments) { $d.payload.arguments } else { $d.payload.input })"
            $detail = $args
            try {
                $a = $args | ConvertFrom-Json
                foreach ($k in @('cmd','command','path','file_path','workdir','query','pattern')) {
                    if ($a.PSObject.Properties.Name -contains $k -and $a.$k) { $detail = "$($a.$k)"; break }
                }
                foreach ($k in @('file_path','path')) {
                    if ($a.PSObject.Properties.Name -contains $k -and $a.$k) { [void]$files.Add("$($a.$k)") }
                }
            } catch {}
            if ($detail.Length -gt 220) { $detail = $detail.Substring(0,220) + ' ...' }
            if ($calls.Count -lt 30) { [void]$calls.Add("${name}: $detail") }
        }
        if ($d.type -eq 'response_item' -and $d.payload.type -in @('function_call_output', 'custom_tool_call_output')) {
            $output = (Get-MessageText $d.payload).Trim()
            if (-not $output) { continue }
            $interesting = $output -match '(?im)\b(error|failed|exception|traceback|denied|not found|cannot|unable|exit code [1-9])\b'
            if ($interesting -and $snips.Count -lt 8) {
                if ($output.Length -gt 700) { $output = $output.Substring(0,700) + ' ...' }
                [void]$snips.Add($output)
            }
        }
    }

    $out = New-Object System.Collections.ArrayList
    [void]$out.Add("## Handoff State Pack")
    [void]$out.Add("")
    [void]$out.Add("This is not a true resume. It is a compact recovery map extracted from the $label transcript. Verify live files before relying on any quoted content.")
    if ($lastUser) { [void]$out.Add(""); [void]$out.Add("### Last User Ask"); [void]$out.Add(""); [void]$out.Add((Limit-HandoffText $lastUser)) }
    if ($lastAgent) { [void]$out.Add(""); [void]$out.Add("### Last Assistant Message"); [void]$out.Add(""); [void]$out.Add((Limit-HandoffText $lastAgent)) }
    $uniqFiles = @($files | Where-Object { $_ } | Select-Object -Unique | Select-Object -First 30)
    if ($uniqFiles) { [void]$out.Add(""); [void]$out.Add("### Files Touched Or Mentioned By Tools"); [void]$out.Add(""); foreach ($f in $uniqFiles) { [void]$out.Add("- ``$f``") } }
    if ($calls.Count) { [void]$out.Add(""); [void]$out.Add("### Recent Tool/Command Calls"); [void]$out.Add(""); foreach ($c in @($calls | Select-Object -Last 30)) { [void]$out.Add("- $c") } }
    if ($snips.Count) { [void]$out.Add(""); [void]$out.Add("### Error/Failure Snippets"); [void]$out.Add(""); foreach ($s in $snips) { [void]$out.Add('```text'); [void]$out.Add($s); [void]$out.Add('```') } }
    [void]$out.Add(""); [void]$out.Add("## Chat Transcript")
    return ($out.ToArray() -join "`n")
}


function Limit-HandoffText($text, $max = 3000) {
    if (-not $text) { return $text }
    if ($text.Length -le $max) { return $text }
    return $text.Substring(0, $max) + " ...`n[truncated in state pack; read transcript below for full context]"
}
# Messages -> markdown. '## User' / '## Codex' is the canonical rendering: it IS the
# handoff, it IS the clipboard's plain-text flavour, and pandoc turns it into the HTML
# flavour -- so all three stay in step by construction.
function ConvertTo-ChatMarkdown($msgs) {
    $out = New-Object System.Collections.ArrayList
    foreach ($m in $msgs) {
        [void]$out.Add("")
        [void]$out.Add("## $($m.Role)")
        [void]$out.Add("")
        [void]$out.Add($m.Body)
    }
    return ($out.ToArray() -join "`n")
}


function Invoke-Handoff($tool, $id, $cwd, $transcript, $title) {
    Invoke-HubTransfer $tool @([pscustomobject]@{ Id = $id; Title = $title; Cwd = $cwd }) $cwd
}

# --- Alt-F: formatted chat export to the clipboard ---------------------------------
# Puts the chat on the clipboard in TWO flavours at once, so the paste target decides:
# rich HTML for Word/Outlook/OneNote/Slack, and the markdown itself as the plain-text
# fallback for a textarea or another AI chat. Both are rendered from the same markdown.
#
# Note on the ANSI/`script -qefc | aha` approach: that captures colour out of a LIVE pty.
# These rows are finished sessions stored as plain JSON on disk -- there is no scrollback
# to capture and not one escape byte to convert, and re-running a session to produce
# colour would cost Codex tokens. So the colour is applied here at render time instead.
Add-Type -AssemblyName System.Windows.Forms

# pandoc.sh: markdown -> html. --no-highlight keeps code blocks as plain <pre><code>;
# pandoc's highlighter emits class-based spans, and classes are exactly what the styling
# below can't rely on (see Add-InlineStyle).
#
# Pandoc's markdown is tuned for documents; a chat log is full of shell/PowerShell prose
# that it misreads. Each extension below is switched OFF for a failure actually observed
# exporting this project's own transcripts:
#   yaml_metadata_block   : the '---' rule under the preamble read as a YAML block start,
#                           and pandoc aborted with a parse error instead of exporting.
#   tex_math_dollars      : '$tmpWin ... $tmpWsl' read as TeX math -- a PowerShell chat is
#   tex_math_single_...   : nothing BUT $vars, so this mangled entire messages.
#   raw_tex               : same family; keeps stray backslashes literal.
#   raw_html              : chat about HTML quotes tags in prose; left on, pandoc passes
#                           them through and they RENDER in the paste. Off, they stay text.
#   citations             : '@codex' / '@ghabre' would be parsed as citation keys.
#   subscript/superscript : '~/.codex ... ~/.local' -- two paths on one line pair their
#                           tildes into a subscript and the text between them vanishes.
#   smart                 : keeps '--' as '--' rather than an en dash, so flags and
#                           commands quoted outside backticks survive the round trip.
# auto_identifiers stays ON: the <h2 id="user"> slugs are how speaker labels are found.
$pandocShWin = Join-Path $tmpWin 'pandoc.sh'; $pandocShWsl = "$tmpWsl/pandoc.sh"
$pandocSh = @"
#!/bin/bash
# `$1 = markdown in, `$2 = html out
pandoc -t html --no-highlight --wrap=none \
    -f markdown-yaml_metadata_block-raw_html-raw_tex-tex_math_dollars-tex_math_single_backslash-citations-subscript-superscript-smart \
    "`$1" -o "`$2"
"@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($pandocShWin, $pandocSh)
$exportMdWin   = Join-Path $tmpWin 'export.md';   $exportMdWsl   = "$tmpWsl/export.md"
$exportHtmlWin = Join-Path $tmpWin 'export.html'; $exportHtmlWsl = "$tmpWsl/export.html"

# Terminal look, light background: monospace throughout, colour-coded speaker labels.
#
# Two rules, both learned from what Word actually does with a paste:
#
# 1. Styles are INLINE, never a <style> block. Word and Outlook parse a stylesheet
#    erratically and Gmail strips it outright; a style attribute is honoured everywhere.
#    That rules out class-based styling, hence the tag rewriting below.
#
# 2. Character formatting (colour, font) must sit on the element that DIRECTLY contains
#    the text -- Word's HTML importer does not cascade it down from an ancestor the way a
#    browser does. Styling a wrapper <div> and letting the text inherit looks perfect in a
#    browser and pastes into Word with the font and colour silently dropped; only the
#    <pre> survived, because its shading applies to the paragraph holding the text. So
#    $cssText is repeated onto every text-bearing tag, and the speaker label carries its
#    colour on an inner <span> rather than on its <div>.
$fontStack = "Consolas,'Cascadia Mono','Courier New',monospace"
$cssText   = "font-family:$fontStack;font-size:13px;color:#1f2328;"
$cssCode   = "font-family:$fontStack;font-size:12.5px;"
# 'inherit' is avoided everywhere below for the same reason as rule 2: Word resolves it
# against its own defaults, not the ancestor we meant, and drops back to a proportional font.
$cssPre    = "background:#f6f8fa;border:1px solid #d0d7de;border-radius:6px;padding:10px;margin:0 0 12px 0;white-space:pre-wrap;line-height:1.45;$cssCode"
$cssTag    = [ordered]@{
    'p'          = "$cssText margin:0 0 10px 0;"
    'ul'         = "margin:0 0 10px 0;padding-left:22px;"
    'ol'         = "margin:0 0 10px 0;padding-left:22px;"
    'li'         = "$cssText margin:0 0 4px 0;"
    'h1'         = "font-family:$fontStack;color:#1f2328;font-size:16px;margin:0 0 10px 0;"
    'h2'         = "font-family:$fontStack;color:#1f2328;font-size:14px;margin:16px 0 8px 0;"
    'h3'         = "font-family:$fontStack;color:#1f2328;font-size:13px;margin:14px 0 6px 0;"
    'blockquote' = "margin:0 0 10px 0;padding-left:10px;border-left:3px solid #d0d7de;"
    'hr'         = "border:0;border-top:1px solid #d0d7de;margin:14px 0;"
    'table'      = "border-collapse:collapse;margin:0 0 10px 0;"
    'th'         = "$cssText border:1px solid #d0d7de;padding:4px 8px;text-align:left;"
    'td'         = "$cssText border:1px solid #d0d7de;padding:4px 8px;"
}

# Add style="..." to every <tag> pandoc emitted, preserving any attributes it already set.
function Add-InlineStyle($html, $tag, $css) {
    [regex]::Replace($html, "<$tag(?![a-z])([^>]*)>", { "<$tag$($args[0].Groups[1].Value) style=`"$css`">" })
}

# Markdown -> styled HTML fragment. Order matters: <pre> and the <code> inside it are
# styled first so the inline-code rule can then match only the <code> tags left over --
# a code pill's padding and border would look wrong wrapped around a whole code block.
function ConvertTo-StyledHtml($markdown) {
    [System.IO.File]::WriteAllText($exportMdWin, $markdown)
    Remove-Item $exportHtmlWin -ErrorAction SilentlyContinue
    Invoke-Bash $pandocShWsl $exportMdWsl $exportHtmlWsl | Out-Null
    if (-not (Test-Path $exportHtmlWin)) { return $null }
    $h = [System.IO.File]::ReadAllText($exportHtmlWin)

    # Speaker labels. pandoc slugs '## User' into <h2 id="user">, repeats as id="user-2"...
    # so the id is a reliable handle for "this h2 is a speaker" that no message body can
    # forge -- ids are generated, not authored.
    #
    # The colour goes on an inner <span>, not on the <div>: on the div, Word keeps the
    # spacing and throws the colour away (see rule 2 above), which is exactly how these
    # labels pasted out black.
    foreach ($sp in @(@{ n='user'; c='#1b7f3b' }, @{ n='codex'; c='#b45309' })) {
        $label = (Get-Culture).TextInfo.ToTitleCase($sp.n)
        $h = [regex]::Replace($h, "<h2 id=`"$($sp.n)(-\d+)?`">$label</h2>",
            "<div style=`"margin:16px 0 6px 0;`"><span style=`"font-family:$fontStack;font-size:13px;font-weight:bold;color:$($sp.c);`">$label</span></div>")
    }
    $h = Add-InlineStyle $h 'pre' $cssPre
    # <code> inside <pre> is the element actually holding the code text, so it needs the
    # font spelled out; it only has to shed the pill look the inline-code rule would give it.
    $h = [regex]::Replace($h, '(<pre[^>]*>)<code(?![a-z])([^>]*)>', "`$1<code`$2 style=`"background:none;border:0;padding:0;color:#1f2328;$cssCode`">")
    $h = [regex]::Replace($h, '<code(?![a-z])(?![^>]*style=)([^>]*)>', "<code`$1 style=`"background:#f6f8fa;border:1px solid #d0d7de;border-radius:4px;padding:0 3px;color:#1f2328;$cssCode`">")
    foreach ($t in $cssTag.Keys) { $h = Add-InlineStyle $h $t $cssTag[$t] }
    # The wrapper is for browsers and web editors, which DO cascade; Word ignores it and
    # reads the per-element styles above instead.
    return "<div style=`"font-family:$fontStack;font-size:13px;line-height:1.5;color:#1f2328;`">$h</div>"
}

# Escape every non-ASCII character as a numeric character reference.
#
# Not cosmetic -- it's a correctness fix. .NET Framework hands the HTML flavour to Windows
# in the system ANSI codepage, NOT UTF-8, so anything outside ASCII is written as a literal
# '?': the arrows, em dashes and box-drawing that fill these transcripts all arrived at the
# paste target as '?/?'. Entities keep the payload pure ASCII, which that encoding can't
# damage, and every HTML target decodes them back. It also makes the CF_HTML offsets exact,
# since one char is then one byte. (The plain-text flavour is unaffected: it goes over
# CF_UNICODETEXT, which .NET does handle as Unicode.)
function ConvertTo-AsciiHtml($s) {
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $s.Length; $i++) {
        $ch = $s[$i]
        if ([int]$ch -le 127) { [void]$sb.Append($ch); continue }
        # A surrogate pair (emoji) is ONE code point spread over two chars -- emit it as
        # one reference, or the paste target sees two broken halves.
        if ([char]::IsHighSurrogate($ch) -and ($i + 1) -lt $s.Length -and [char]::IsLowSurrogate($s[$i+1])) {
            [void]$sb.AppendFormat('&#x{0:X};', [char]::ConvertToUtf32($ch, $s[$i+1])); $i++
        } else {
            [void]$sb.AppendFormat('&#x{0:X};', [int]$ch)
        }
    }
    return $sb.ToString()
}

# Wrap a fragment in the CF_HTML descriptor Windows requires. .NET does NOT add this --
# Clipboard.SetText(html, TextDataFormat.Html) hands the raw string over and rich targets
# then reject it. The four offsets are BYTE counts into the payload, and the header is
# fixed-width (D10) so measuring it before filling it in is safe.
function New-CfHtml($fragment) {
    $fragment = ConvertTo-AsciiHtml $fragment
    $pre = "<html><body><!--StartFragment-->"; $post = "<!--EndFragment--></body></html>"
    $hdr = "Version:0.9`r`nStartHTML:{0:D10}`r`nEndHTML:{1:D10}`r`nStartFragment:{2:D10}`r`nEndFragment:{3:D10}`r`n"
    $b   = [System.Text.Encoding]::UTF8
    $sH  = $b.GetByteCount(($hdr -f 0,0,0,0))
    $sF  = $sH + $b.GetByteCount($pre)
    $eF  = $sF + $b.GetByteCount($fragment)
    $eH  = $eF + $b.GetByteCount($post)
    ($hdr -f $sH,$eH,$sF,$eF) + $pre + $fragment + $post
}

# Alt-F: copy this conversation to the clipboard, formatted.
function Invoke-CopyExport($id, $cwd, $transcript) {
    if (-not $transcript -or -not (Test-Path $transcript)) {
        Write-Host "No transcript found for $id"; Start-Sleep -Milliseconds 900; return
    }
    Write-Host "Formatting chat for the clipboard..." -NoNewline
    $msgs = @(Get-ChatMessages $transcript)
    if (-not $msgs) {
        Write-Host "`r                                    `r" -NoNewline
        Write-Host "Nothing to copy: no chat messages in $id"; Start-Sleep -Milliseconds 900; return
    }
    # One markdown document: it is both the plain-text flavour and pandoc's input.
    $md = (@(
        "# Codex chat"
        ""
        "- Session: ``$id``"
        "- Folder: ``$cwd``"
        "- Exported: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        ""
        "Includes a compact state pack plus chat transcript. Tool outputs may be abbreviated."
        ""
        "---"
    ) -join "`n") + "`n" + (Get-HandoffStateMarkdown $transcript 'Codex') + "`n" + (ConvertTo-ChatMarkdown $msgs) + "`n"

    $frag = ConvertTo-StyledHtml $md
    Write-Host "`r                                    `r" -NoNewline
    if (-not $frag) { Write-Host "pandoc failed -- is it installed for the $backend backend?"; Start-Sleep -Milliseconds 1200; return }

    $obj = New-Object System.Windows.Forms.DataObject
    $obj.SetData([System.Windows.Forms.DataFormats]::Html, (New-CfHtml $frag))
    $obj.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $md)
    # $true = keep it on the clipboard after this process exits.
    [System.Windows.Forms.Clipboard]::SetDataObject($obj, $true)
    Write-Host ("Copied {0} messages -- formatted (HTML + markdown)" -f $msgs.Count)
    Start-Sleep -Milliseconds 700
}
# -----------------------------------------------------------------------------------

# --- Combined clipboard export and transfer entry points ----------------------------

# Render the marked sessions as one markdown body of '# Thread N' sections. Returns
# @{ Body=<markdown>; Count=<threads with chat> }, or $null if none had any messages.
function Build-CombinedThreads($items) {
    $body = New-Object System.Collections.ArrayList
    $n = 0
    foreach ($it in $items) {
        if (-not $it.Tr -or -not (Test-Path $it.Tr)) { continue }
        $msgs = @(Get-ChatMessages $it.Tr)
        if (-not $msgs) { continue }
        $n++
        $folder = (($it.Cwd -replace '\\','/') -split '/' | Select-Object -Last 2) -join '/'
        [void]$body.Add("")
        [void]$body.Add("# Thread $n -- $folder")
        [void]$body.Add("")
        [void]$body.Add("- Session id: ``$($it.Id)``")
        [void]$body.Add("- Working dir: ``$($it.Cwd)``")
        [void]$body.Add("")
        [void]$body.Add("---")
        [void]$body.Add((Get-HandoffStateMarkdown $it.Tr 'Codex'))
        [void]$body.Add((ConvertTo-ChatMarkdown $msgs))
    }
    if ($n -eq 0) { return $null }
    return @{ Body = ($body.ToArray() -join "`n"); Count = $n }
}


# Pick the folder the combined session runs in. The marked sessions may span different
# repos, so choose among THEIR own cwds (not the whole new-session root): one distinct cwd
# -> use it silently; several -> the folder picker, listing just those. $null = cancelled.
function Select-CombinedCwd($items) {
    $cwds = @($items | Select-Object -ExpandProperty Cwd -Unique)
    if ($cwds.Count -le 1) { return $cwds[0] }
    $rows = $cwds | ForEach-Object {
        $folder = (($_ -replace '\\','/') -split '/' | Select-Object -Last 2) -join '/'
        "{0}`t{1}" -f $folder, $_
    }
    [System.IO.File]::WriteAllLines($dirListWin, [string[]]@($rows))
    Remove-Item $pickWin -ErrorAction SilentlyContinue
    Invoke-Bash $fzfDirShWsl $dirListWsl $pickWsl 'combined'
    $p = @(if (Test-Path $pickWin) { Get-Content $pickWin | Where-Object { $_ } })
    if (-not $p) { return $null }
    ($p[0] -split "`t")[1]
}

# Reuse the shared transfer planner for combined sessions.
function Invoke-CombineSession($items, $tool) {
    Invoke-HubTransfer $tool $items $items[0].Cwd
}

# alt-f on 2+ marked rows: one combined formatted copy to the clipboard (opens nothing).
function Invoke-CombineCopy($items) {
    Write-Host "Formatting combined chats for the clipboard..." -NoNewline
    $r = Build-CombinedThreads $items
    if (-not $r) {
        Write-Host "`r                                            `r" -NoNewline
        Write-Host "Nothing to copy: no chat messages in the marked sessions"; Start-Sleep -Milliseconds 900; return
    }
    $head = @(
        "# Combined Codex chats"
        ""
        "- Threads: $($r.Count)"
        "- Exported: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        ""
        "Includes a compact state pack plus chat transcript. Tool outputs may be abbreviated."
        ""
        "==="
    ) -join "`n"
    $md   = $head + "`n" + $r.Body + "`n"
    $frag = ConvertTo-StyledHtml $md
    Write-Host "`r                                            `r" -NoNewline
    if (-not $frag) { Write-Host "pandoc failed -- is it installed for the $backend backend?"; Start-Sleep -Milliseconds 1200; return }

    $obj = New-Object System.Windows.Forms.DataObject
    $obj.SetData([System.Windows.Forms.DataFormats]::Html, (New-CfHtml $frag))
    $obj.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $md)
    [System.Windows.Forms.Clipboard]::SetDataObject($obj, $true)
    Write-Host ("Copied {0} threads -- formatted (HTML + markdown)" -f $r.Count)
    Start-Sleep -Milliseconds 700
}
# -----------------------------------------------------------------------------------

Invoke-Backup   # no-op unless the newest snapshot is older than $backupEvery hours

$sessions = Update-List
if (-not $sessions) { Write-Host "No past Codex sessions found under $sessDir -- use the top row to start a new one." }

while ($true) {
    # fzf (Linux, via WSL): list in via file, pick out via file, console untouched so
    # keyboard/mouse/resize all reach fzf. Wheel scrolls, a second click on the
    # highlighted row (or Enter) opens.
    Remove-Item $pickWin -ErrorAction SilentlyContinue
    Invoke-Bash $fzfShWsl $listWsl $pickWsl

    # --expect puts the pressed key on line 1 ('' for Enter/click, 'alt-c', 'alt-f',
    # 'alt-h', or 'alt-s') and
    # the picks after it. Read the lines raw -- a normal accept leaves line 1 BLANK, so
    # blanks can only be filtered out once the key has been taken off the front.
    $out    = @(if (Test-Path $pickWin) { Get-Content $pickWin })
    $key    = if ($out.Count) { $out[0].Trim() } else { '' }
    $picked = @($out | Select-Object -Skip 1 | Where-Object { $_ })
    if ($key -eq 'alt-s') {
        Show-HiddenSessions
        $sessions = Update-List
        continue
    }
    # Esc (or no match) -> empty pick: reload the full script so edits are picked up.
    if (-not $picked) { Restart-Script }

    if ($key -eq 'alt-h') {
        Hide-Sessions $picked
        $sessions = Update-List
        continue
    }

    # Open each pick as its own tab in the correct folder, resumed.
    # bash -lic loads the login profile so PATH includes codex.
    # For the keys that launch something, the pressed key chooses the tool once, here;
    # everything below just uses $tool. (Alt-F launches nothing and ignores it.)
    $tool = if ($key -eq 'alt-w') { 'claude-work' } elseif ($key -eq 'alt-c') { 'claude' } elseif ($key -eq 'alt-o') { 'opencode' } else { 'codex' }

    # Tab-marking 2+ real session rows means "combine", not "open each": merge their
    # transcripts into one handoff and seed a single new session (enter/transfer key), or one
    # combined clipboard copy (alt-f). The __NEW__ row can't be combined, so drop it first.
    $realItems = @(foreach ($row in $picked) {
        $p = $row -split "`t"
        if ($p[1] -ne '__NEW__') { [pscustomobject]@{ Id = $p[1]; Cwd = $p[2]; Tr = $p[3] } }
    })
    if ($realItems.Count -ge 2) {
        if ($key -eq 'alt-f') { Invoke-CombineCopy $realItems }
        else                  { Invoke-CombineSession $realItems $tool }
        continue
    }

    foreach ($row in $picked) {
        $parts = $row -split "`t"
        $id    = $parts[1]
        $cwd   = $parts[2]
        $tr    = $parts[3]
        if ($key -eq 'alt-f') {   # copy to clipboard, open nothing
            if ($id -eq '__NEW__') { Write-Host "Nothing to copy: that row starts a new session."; Start-Sleep -Milliseconds 900; continue }
            Invoke-CopyExport $id $cwd $tr; continue
        }
        if ($id -eq '__NEW__')  { Invoke-NewSession $tool; continue }   # top row: start fresh
        $title = $parts[4]
        $codexTitle = $parts[5]
        $hasLiveTitle = $parts[6] -eq '1'
        if ($tool -ne 'codex') { Invoke-Handoff $tool $id $cwd $tr $title; continue } # port to claude/opencode
        $tabTitle = if ($codexTitle) { "codex: $codexTitle" } else { "codex: $id" }
        if (-not $hasLiveTitle) { Set-CodexThreadTitle $id $codexTitle }
        Open-WtTab $tabTitle $cwd "codex -c tui.fullscreen_transcript=false resume $id"
    }
}
