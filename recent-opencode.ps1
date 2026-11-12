# recent-opencode.ps1
#
# Fuzzy-picker for OpenCode sessions. Lists top-level sessions from opencode.db updated
# within the last 40 days -- across every project -- and resumes one in a new Windows
# Terminal tab. Picking takes two clicks: the first left-click on a row only highlights
# it, a second click on that same row opens it (Enter opens the highlighted row straight
# away). This is deliberately NOT fzf's own double-click, which demands two fast clicks
# with no mouse drift -- here the two clicks can be any distance apart in time.
# The picker stays up for more picks; Esc reloads this script in-place; close the window to quit.
#
# The top row ("+ New session...") starts a fresh conversation: it opens a folder picker
# listing the project root itself followed by its immediate subfolders (default C:\G\code,
# override with $env:OPENCODE_NEW_ROOT or $env:AGENT_HUB_NEW_ROOT), and launches a new
# session in the folder you pick -- `opencode` on enter/click, `codex` on Alt-X, or
# `claude` on Alt-C.
#
# Transfer hotkeys resume a unique linked destination automatically, importing only
# unseen messages and tool notes. Multiple branches require a destination choice.
# A repeated transfer with no new material resumes without adding a prompt.
# Tab marks multiple sessions; Enter or a transfer key continues their combined
# conversation, reusing the existing result when known.
# Transfer state and immutable payloads live in the gitignored .history folder beside this script,
# separately for each backend/distro. Keep this directory to preserve synchronization.
#
# On startup it also snapshots opencode.db to a .tar.gz under .\backups\opencode, but only
# if the newest snapshot is more than 24 hours old, and it keeps the 10 most recent. They
# land on the Windows side on purpose: the original only exists inside the WSL VHD. The
# snapshot uses SQLite's online backup API, so a running OpenCode instance cannot corrupt
# it. Override the location with $env:OPENCODE_BACKUP_DIR.
#
# Backend: $env:AGENT_HUB_BACKEND = 'wsl' (default) or 'windows'.
#   wsl     : OpenCode installed INSIDE WSL; the requirements below apply as written.
#   windows : OpenCode installed natively (data under %LOCALAPPDATA%\opencode or the
#             directory `opencode debug paths` reports). The same helper scripts run under
#             Git for Windows' bash; fzf, Python and the other CLIs come from the
#             Windows PATH, and tabs open in PowerShell 7, whose profile supplies per-shell
#             tools such as fnm's codex. No WSL is used.
#
# Requirements (wsl backend):
#   - Windows with WSL2, and OpenCode installed INSIDE WSL (data under ~/.local/share/opencode).
#   - Windows Terminal (wt.exe) -- used to open the resumed sessions as tabs.
#   - The Linux build of fzf installed in WSL (NOT fzf.exe -- the Windows build
#     mis-parses Windows Terminal mouse input). apt: `sudo apt install fzf`, or grab a
#     release binary into ~/.local/bin. It's found via the WSL login-shell PATH.
#   - Python 3.8+ -- reads opencode.db and tracks conversation handoffs. apt: `sudo apt install python3`.
#   - `opencode` reachable from the WSL login shell (bash -lic).
#   - `codex` / `claude` likewise, but only if you use the Alt-X / Alt-C handoff.
#
# Auto-detected (no per-machine editing needed): the default WSL distro, the fzf path, and
# the OpenCode data directory and database (respecting OPENCODE_DB and XDG_DATA_HOME).
# Overrides: set $env:WSL_DISTRO to force a distro, $env:WSL_USER to force the home user.
#
# Usage: run under Windows PowerShell, e.g. a shortcut with target:
#   powershell.exe -NoExit -ExecutionPolicy Bypass -File "C:\path\to\recent-opencode.ps1"

param([switch]$Run)
# The outer invocation is only this loop. Esc makes the picker exit with 75 and it is rerun in a
# fresh scope of the same process, so reloads neither stack processes nor read stale variables.
if (-not $Run) { do { & $PSCommandPath -Run @args } while ($LASTEXITCODE -eq 75); exit $LASTEXITCODE }

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

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
$codexEnabled = 'codex' -in $enabledTools
$claudeEnabled = 'claude' -in $enabledTools   # alt-c opens Claude in the active account (Alt-A in the Claude picker)
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
$tmpWin  = Join-Path $env:TEMP ("recent-opencode-{0}" -f $PID)
New-Item -ItemType Directory -Path $tmpWin -Force | Out-Null
# Nothing runs when a tab is closed, so each launch removes the folders of pickers that are gone.
Get-ChildItem $env:TEMP -Directory | Where-Object { $_.Name -match '^recent-opencode-(\d+)$' -and -not (Get-Process -Id $Matches[1] -ErrorAction SilentlyContinue) } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
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
printf '%s\n%s\n%s\n%s\n' "$u" "$f" "$d" "$db"
'@ -replace "`r`n","`n"
    [System.IO.File]::WriteAllText($probeShWin, $probeSh)
    $probe = @(wsl.exe -d $distro -- bash -li $probeShWsl 2>$null)
    $wslUser       = if ($env:WSL_USER) { $env:WSL_USER } elseif ($probe.Count -ge 1 -and $probe[0]) { "$($probe[0])".Trim() } else { (wsl -d $distro -- whoami).Trim() }
    $bashHome      = "/home/$wslUser"
    $fzfPath       = if ($probe.Count -ge 2 -and $probe[1]) { "$($probe[1])".Trim() } else { "$bashHome/.local/bin/fzf" }
    $opencodeData  = if ($probe.Count -ge 3 -and $probe[2]) { "$($probe[2])".Trim() } else { "$bashHome/.local/share/opencode" }
    $opencodeDbWsl = if ($probe.Count -ge 4 -and $probe[3]) { "$($probe[3])".Trim() } else { "$opencodeData/opencode.db" }
} else {
    $gitBash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
    if (-not (Test-Path $gitBash)) { throw "The windows backend needs Git for Windows: $gitBash not found" }
    $bashHome = ConvertTo-WslPath $HOME
    $dataBase = if ($env:XDG_DATA_HOME) { ConvertTo-WslPath $env:XDG_DATA_HOME } else { "$bashHome/.local/share" }
    $opencodeData = "$dataBase/opencode"
    $opencodeDbWsl = if ($env:OPENCODE_DB) {
        $dbOverride = if ($env:OPENCODE_DB -match '^[A-Za-z]:\\') { ConvertTo-WslPath $env:OPENCODE_DB } else { $env:OPENCODE_DB -replace '\\','/' }
        if ($dbOverride.StartsWith('/')) { $dbOverride } else { "$opencodeData/$dbOverride" }
    } else { "$opencodeData/opencode.db" }
    # Tab commands run in PowerShell, where a bare 'bash' would be WSL's System32 bash.exe.
    $tabShell = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
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

$hubStateDir = Join-Path $env:LOCALAPPDATA 'AgentSessionHub'
$hiddenSessionsFile = Join-Path $hubStateDir 'hidden-opencode-session-ids.txt'

# Locate wt.exe (may not be on PATH depending on launch context)
$wt = Get-Command wt.exe -ErrorAction SilentlyContinue
if ($wt) { $wt = $wt.Source } else { $wt = "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe" }
$wtWindow = if ($env:AGENT_SESSION_HUB_WINDOW) { $env:AGENT_SESSION_HUB_WINDOW } else { '0' }

# wt.exe splits its whole command line on ';' (titles and paths too), so a title such as
# "a; b" opens several broken tabs. '\;' is wt's literal semicolon.
# $color, when given, is the tab color: Claude tabs carry their account's.
function Open-WtTab($title, $cwd, $command, $color) {
    # Windows PowerShell 5 passes embedded double quotes to wt.exe unescaped, merging arguments.
    $title = $title -replace '"', "'"
    $colorArgs = @(if ($color) { '--tabColor', $color })
    if ($backend -eq 'wsl') {
        & $wt -w $wtWindow new-tab --title ($title -replace ';', '\;') @colorArgs `
            wsl.exe -d $distro --cd ($cwd -replace ';', '\;') -- bash -lic ($command -replace ';', '\;')
    } else {
        & $wt -w $wtWindow new-tab --title ($title -replace ';', '\;') @colorArgs -d ($cwd -replace ';', '\;') `
            $tabShell -NoLogo -Command ($command -replace ';', '\;')
    }
    Start-Sleep -Milliseconds 300   # let wt register each tab before the next
}

$hubTool = 'opencode'
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
$clickStateWsl = "/tmp/recent-opencode-$PID-click.state"
$clickBinds = (@"
    --bind "focus:transform:echo {n} > $clickStateWsl" \
    --bind "left-click:transform:if [ \"\`$(cat $clickStateWsl 2>/dev/null)\" = \"{n}\" ]; then echo accept; fi" \
"@ -replace "`r`n","`n")

# --expect makes fzf print the pressed key as the FIRST line of the pick file (an empty
# first line for a plain Enter/click accept), so one picker can mean several things:
# open in opencode, hand the session off to codex/claude, copy it, or hide it from this picker.
$expectKeys = @($(if ($codexEnabled) { 'alt-x' }), $(if ($claudeEnabled) { 'alt-c' }), 'alt-h', 'alt-s') -join ','
$headerActions = @('enter: open', 'tab: mark', $(if ($codexEnabled) { 'alt-x: codex' }), $(if ($claudeEnabled) { 'alt-c: claude' }), 'alt-h: hide', 'alt-s: show', 'alt-p: preview', 'esc: reload') -join ' | '
$fzfSh = @"
#!/bin/bash
# `$1 = list file (CRLF from PowerShell -- strip CRs), `$2 = pick output file
tr -d '\r' < "`$1" | "$fzfPath" \
    --with-nth=1 --delimiter=`$'\t' \
    --multi \
    --expect=$expectKeys \
$clickBinds
$(Get-HubPreviewOptions "$opencodeDbWsl")
    --prompt='opencode sessions> ' --reverse \
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
    --prompt='hidden opencode sessions> ' --reverse \
    --header='enter: show | tab: mark multiple | esc: cancel' \
    > "`$2"
"@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($showShWin, $showSh)

# py.sh: run Python 3 in whichever backend is in use. Reading and snapshotting
# opencode.db needs a real SQLite driver; the CLI itself only lists one project at a
# time, so the picker cannot lean on it for the cross-project session list.
$pyShWin = Join-Path $tmpWin 'py.sh'; $pyShWsl = "$tmpWsl/py.sh"
$pySh = @"
#!/bin/bash
for p in python3 python; do
    if command -v "`$p" >/dev/null 2>&1; then exec "`$p" "`$@"; fi
done
echo "Python 3 is required for OpenCode session support." >&2
exit 127
"@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($pyShWin, $pySh)

# scan-sessions.py: enumerate top-level sessions from opencode.db. One database holds
# every project, so this is the only way to list them together; the CLI's `session list`
# is scoped to the current project. parent_id IS NULL excludes subagent/child sessions,
# time_archived IS NULL excludes archived rows. The 40-day window matches the other
# pickers. Emits:
#   epoch<TAB>id<TAB>directory<TAB>title<TAB>transition-source<TAB>inherited-title<TAB>fallback
# The fallback is the first real user message, used when OpenCode has not titled a
# session yet. A handoff prompt is recognised so the picker can keep showing the title
# the conversation had in its previous CLI.
$scanPyWin = Join-Path $tmpWin 'scan-sessions.py'; $scanPyWsl = "$tmpWsl/scan-sessions.py"
$scanPy = @'
import json, os, re, sqlite3, sys, time

db = sys.argv[1]
mode = sys.argv[2] if len(sys.argv) > 2 else 'recent'
days = int(sys.argv[3]) if len(sys.argv) > 3 else 40
if not os.path.isfile(db):
    sys.exit(0)

conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
conn.row_factory = sqlite3.Row
cutoff = int((time.time() - days * 86400) * 1000)
sql = ("SELECT id, directory, title, time_updated FROM session_v2 "
       "WHERE parent_id IS NULL AND time_archived IS NULL")
params = []
if mode != 'all':
    sql += " AND time_updated >= ?"
    params.append(cutoff)
sql += " ORDER BY time_updated DESC"

def collapse(text):
    text = (text or '').replace('\t', ' ').replace('\r', ' ').replace('\n', ' ')
    return re.sub(r'\s+', ' ', text).strip()

for row in conn.execute(sql, params):
    sid = row['id']
    directory = row['directory'] or ''
    title = collapse(row['title'])
    fallback = transition_source = transition_title = ''
    for (data,) in conn.execute(
            "SELECT data FROM session_message WHERE session_id = ? AND type = 'user' ORDER BY seq ASC LIMIT 5",
            (sid,)):
        try:
            msg = json.loads(data)
        except Exception:
            continue
        text = msg.get('text') or ''
        if not text:
            continue
        m = re.search(r'\[(?:Transitioned|Continued) from (Claude|Codex|OpenCode)(?:; inherited title: ([^\]]*))?\]', text)
        if m:
            if not transition_source:
                transition_source = m.group(1) or ''
                transition_title = collapse(m.group(2))
            continue
        cleaned = re.sub(r'(?s)<system-reminder>.*?</system-reminder>', '', text).strip()
        if not cleaned:
            continue
        if re.match(r'^<[^>\r\n]+>', cleaned):
            continue
        if cleaned.lower().startswith('# agents.md instructions'):
            continue
        if not fallback:
            fallback = cleaned
    print('\t'.join([str(int((row['time_updated'] or 0) // 1000)), sid, directory,
                     title, transition_source, transition_title, collapse(fallback)]))
'@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($scanPyWin, $scanPy)

# --- New-session support -----------------------------------------------------------
# Root that the folder picker lists (immediate subfolders become new-session choices).
# Its first row can also create an initialized local Git project under this root.
# Override with $env:OPENCODE_NEW_ROOT or $env:AGENT_HUB_NEW_ROOT (a Windows path). WSL path derived like $tmpWsl.
$newRoot    = if ($env:OPENCODE_NEW_ROOT) { $env:OPENCODE_NEW_ROOT } elseif ($env:AGENT_HUB_NEW_ROOT) { $env:AGENT_HUB_NEW_ROOT } else { 'C:\G\code' }
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
# `$3 is the tool being started ('opencode', 'codex' or 'claude') -- it only ever labels
# the prompt, so the same picker serves all three.
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


# --- Database backup ---------------------------------------------------------------
# opencode.db is the only record of past sessions and it lives inside the WSL VHD, so
# snapshots are written to the WINDOWS side: they then survive `wsl --unregister`, a VHD
# corruption, or a distro rebuild. A ~14MB database gzips to a few MB, so it runs inline
# at startup rather than in the background. Override the location with $env:OPENCODE_BACKUP_DIR.
$backupDir    = if ($env:OPENCODE_BACKUP_DIR) { $env:OPENCODE_BACKUP_DIR } else { Join-Path $PSScriptRoot 'backups\opencode' }
$backupDirWsl = ConvertTo-WslPath $backupDir
$backupEvery  = 24   # hours between snapshots
$backupKeep   = 10   # snapshots retained; older ones are pruned

# backup-db.py: a consistent snapshot through SQLite's online backup API. A plain `cp`
# while OpenCode is writing can capture a torn database or miss the WAL.
$backupPyWin = Join-Path $tmpWin 'backup-db.py'; $backupPyWsl = "$tmpWsl/backup-db.py"
$backupPy = @'
import sqlite3, sys

src, dst = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
out = sqlite3.connect(dst)
with out:
    conn.backup(out)
out.close()
conn.close()
'@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($backupPyWin, $backupPy)

# backup.sh: throttle, snapshot, prune. All three decisions are driven by ONE source of
# truth -- the snapshot filenames themselves (opencode-history-<stamp>.tar.gz). The stamp
# says when that snapshot was taken, so "is the newest one older than $backupEvery" and
# "which are the oldest to prune" are both answered by sorting the names; no sidecar
# timestamp file to drift out of sync, and the format sorts chronologically as text.
# mtime is deliberately NOT consulted: copying a backup would rewrite it, the name survives.
$backupShWin = Join-Path $tmpWin 'backup.sh'; $backupShWsl = "$tmpWsl/backup.sh"
$backupSh = @"
#!/bin/bash
# `$1 = backup dir (Linux path), `$2 = opencode.db (Linux path), `$3 = Python wrapper.
dir="`$1"; db="`$2"; py="`$3"
interval=`$(( $backupEvery * 3600 ))
# Click-state files of pickers long gone; a live picker rewrites its own on every focus change.
find /tmp -maxdepth 1 -name 'recent-opencode-*-click.state' -mtime +7 -delete 2>/dev/null
mkdir -p "`$dir" 2>/dev/null || exit 0

newest=`$(ls -1 "`$dir"/opencode-history-*.tar.gz 2>/dev/null | sort | tail -1)
if [ -n "`$newest" ]; then
    ts=`${newest##*/opencode-history-}; ts=`${ts%.tar.gz}
    last=`$(date -d "`${ts:0:4}-`${ts:4:2}-`${ts:6:2} `${ts:9:2}:`${ts:11:2}:`${ts:13:2}" +%s 2>/dev/null)
    # Unparsable name (hand-renamed?) -> treat as no backup and take one; better an extra
    # snapshot than a skipped one.
    [ -n "`$last" ] && [ `$(( `$(date +%s) - last )) -lt "`$interval" ] && exit 0
fi

work=`$(mktemp -d "`${TMPDIR:-/tmp}/opencode-backup.XXXXXX") || exit 0
trap 'rm -rf "`$work"' EXIT
"`$py" "$backupPyWsl" "`$db" "`$work/opencode.db" || exit 0
[ -s "`$work/opencode.db" ] || exit 0

out="`$dir/opencode-history-`$(date +%Y%m%d-%H%M%S).tar.gz"
# Write aside, then rename: the glob above only ever sees finished snapshots, so an
# interrupted run can't pass a truncated file off as recent and suppress the next day.
tar -czf "`$out.part" -C "`$work" opencode.db 2>/dev/null
[ `$? -ge 2 ] && { rm -f "`$out.part"; exit 0; }
mv -f "`$out.part" "`$out" || exit 0
echo "`$out"

# Prune oldest-first, keeping the newest $backupKeep.
ls -1 "`$dir"/opencode-history-*.tar.gz 2>/dev/null | sort | head -n -$backupKeep | xargs -r rm -f
"@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($backupShWin, $backupSh)

# Runs once per launch; backup.sh itself decides whether one is actually due.
function Invoke-Backup {
    Write-Host "Checking OpenCode database backup..." -NoNewline
    $made = @(Invoke-Bash $backupShWsl $backupDirWsl $opencodeDbWsl $pyShWsl | Where-Object { $_ })
    Write-Host "`r                                       `r" -NoNewline
    if ($made) {
        $f = Get-Item (Join-Path $backupDir (Split-Path $made[-1] -Leaf)) -ErrorAction SilentlyContinue
        if ($f) { Write-Host ("Backed up OpenCode database -> {0} ({1:N1} MB)" -f $f.Name, ($f.Length/1MB)) }
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

# Ignore host-injected XML-style records when deriving a title from user messages.
function Get-TitleCandidate($text) {
    if (-not ($text -is [string])) { return $null }
    $candidate = $text.Trim()
    if (-not $candidate) { return $null }
    if ($candidate -match '(?s)^<[^>\r\n]+>') { return $null }
    if ($candidate -match '(?is)^# AGENTS\.md instructions\b') { return $null }
    return $candidate
}

function Get-HiddenSessionIds {
    $hidden = @{}
    if (Test-Path $hiddenSessionsFile) {
        try {
            foreach ($line in [SharedFile]::ReadLines($hiddenSessionsFile)) {
                $id = $line.Trim()
                if ($id -match '^ses_[A-Za-z0-9]+$') {
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
        if ($id -match '^ses_[A-Za-z0-9]+$' -and -not $hidden.ContainsKey($id.ToLowerInvariant())) { $id }
    })
    if (-not $ids) { return }
    New-Item -ItemType Directory -Path $hubStateDir -Force | Out-Null
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($hiddenSessionsFile, (($ids -join "`n") + "`n"), $utf8NoBom)
}

function Show-HiddenSessions {
    $rows = @(Get-Sessions 'hidden')
    if (-not $rows) {
        Write-Host "No hidden OpenCode conversations found."
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
    # scan-sessions.py emits one row per top-level OpenCode session:
    #   epoch<TAB>id<TAB>directory<TAB>title<TAB>transition-source<TAB>inherited-title<TAB>fallback
    $scanMode = if ($visibility -eq 'hidden') { 'all' } else { 'recent' }
    Invoke-Bash $pyShWsl $scanPyWsl $opencodeDbWsl $scanMode 40 |
        ForEach-Object {
            $parts = $_ -split "`t"
            if ($parts.Count -lt 7) { return }
            $epoch, $id, $cwd, $dbTitle, $transitionSource, $transitionTitle, $fallback = $parts
            if (-not $id) { return }
            $isHidden = $hiddenIds.ContainsKey($id.ToLowerInvariant())
            if (($visibility -eq 'hidden') -ne $isHidden) { return }

            # Native Windows cwds arrive JSON-escaped (C:\\dir); WSL paths have no backslashes.
            $cwd = "$cwd" -replace '\\\\','\'
            if (-not $cwd) { return }
            $lastWrite = [DateTimeOffset]::FromUnixTimeSeconds([long]$epoch).LocalDateTime
            $folder = (($cwd -replace '\\','/') -split '/' | Select-Object -Last 2) -join '/'

            # Title priority: the title the conversation had before a handoff here (so the
            # same thread keeps its name across CLIs) > OpenCode's own title > first user
            # message > a placeholder. $handoffTitle is what the next handoff records.
            $handoffTitle = if ($transitionTitle) { $transitionTitle }
                            elseif ($dbTitle) { $dbTitle }
                            elseif ($fallback) { $fallback }
                            else { "Untitled session in $folder" }
            $handoffTitle = Get-TitleCandidate $handoffTitle
            if (-not $handoffTitle) { $handoffTitle = "Untitled session in $folder" }
            $title = $handoffTitle
            if ($transitionSource) { $title = "From ${transitionSource}: $title" }
            if ($title.Length -gt 50) { $title = $title.Substring(0,50) }

            $age    = Format-Age $lastWrite
            $shortId = ($id -replace '^ses_','')
            if ($shortId.Length -gt 8) { $shortId = $shortId.Substring($shortId.Length - 8) }

            # display <TAB> id <TAB> cwd <TAB> id (the chat is in the DB, not a file; only
            # col 1 is shown thanks to --with-nth=1) <TAB> handoff title
            "{0} - {1} - {2} ago [..-{3}]`t{4}`t{5}`t{6}`t{7}" -f $folder, $title, $age, $shortId, $id, $cwd, $id, $handoffTitle
        }
}

# Keep the picker alive on a cached list: opening a tab leaves the same sessions on
# screen (no rescan, no reshuffle). Esc reloads the whole script so code changes are picked up; close the
# window to quit. Scan up front, then restart the script when Esc asks for it.
# Synthetic first row: picking it (id __NEW__) triggers the folder picker below --
# with opencode on enter/click, or a transfer target on its hotkey, same as the session rows.
$newTargets = @($(if ($codexEnabled) { 'alt-x: codex' }), $(if ($claudeEnabled) { 'alt-c: claude' })) -join ' | '
$newRow = if ($newTargets) { "+ New session (choose folder)...  [enter: opencode | $newTargets]`t__NEW__`t`t" } else { "+ New session (choose folder)...  [enter: opencode]`t__NEW__`t`t" }

function Restart-Script {
    Write-Host "Reloading script..."
    # Re-detect CLIs so a tool installed since the hub launched appears.
    $env:AGENT_HUB_AVAILABLE_TOOLS = $null
    exit 75   # the loop at the top of this script reruns it
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
# $tool ('claude', 'codex', 'opencode') is the ONLY difference between the flows -- it labels
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
    $account = if ($tool -eq 'claude') { Get-HubClaudeActiveAccount }
    $title = if ($tool -eq 'opencode') { $name } else { "${tool}: $name" }
    $command = if ($tool -eq 'claude') { New-HubClaudeCommand 'claude' $account } elseif ($tool -eq 'codex') { 'codex -c tui.fullscreen_transcript=false' } else { $tool }
    Open-WtTab $title $path $command $account.Color
}

function Invoke-Handoff($tool, $id, $cwd, $title) {
    Invoke-HubTransfer $tool @([pscustomobject]@{ Id = $id; Title = $title; Cwd = $cwd }) $cwd
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

Invoke-Backup   # no-op unless the newest snapshot is older than $backupEvery hours

$sessions = Update-List
if (-not $sessions) { Write-Host "No past sessions found in $opencodeDbWsl -- use the top row to start a new one." }

while ($true) {
    # fzf (Linux, via WSL): list in via file, pick out via file, console untouched so
    # keyboard/mouse/resize all reach fzf. Wheel scrolls, a second click on the
    # highlighted row (or Enter) opens.
    Remove-Item $pickWin -ErrorAction SilentlyContinue
    Invoke-Bash $fzfShWsl $listWsl $pickWsl

    # --expect puts the pressed key on line 1 ('' for Enter/click, 'alt-x', 'alt-c',
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
    # bash -lic loads the login profile so PATH includes opencode.
    # For the keys that launch something, the pressed key chooses the tool once, here;
    # everything below just uses $tool.
    $tool = if ($key -eq 'alt-x') { 'codex' } elseif ($key -eq 'alt-c') { 'claude' } else { 'opencode' }

    # Tab-marking 2+ real session rows means "combine", not "open each": merge their
    # chats into one handoff and seed a single new session (enter/transfer key). The __NEW__ row can't be combined, so drop it first.
    $items = @(foreach ($row in $picked) {
        $p = $row -split "`t"
        [pscustomobject]@{ Id = $p[1]; Cwd = $p[2]; Title = $p[4] }
    })
    $realItems = @($items | Where-Object { $_.Id -ne '__NEW__' })
    if ($realItems.Count -ge 2) {
        Invoke-CombineSession $realItems $tool
        continue
    }

    foreach ($it in $items) {
        if ($it.Id -eq '__NEW__') { Invoke-NewSession $tool; continue }   # top row: start fresh
        if ($tool -ne 'opencode') { Invoke-Handoff $tool $it.Id $it.Cwd $it.Title; continue }
        $tabTitle = if ($it.Title) { "opencode: $($it.Title)" } else { "opencode: $($it.Id)" }
        Open-WtTab $tabTitle $it.Cwd "opencode --session $($it.Id)"
    }
}
