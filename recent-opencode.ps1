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
# Alt-X / Alt-C on a session row continues that conversation in CODEX / CLAUDE instead,
# in the same folder: the session is exported to a chat-only markdown handoff (tool calls,
# tool output and internal reasoning stripped -- the target re-reads the live files itself)
# and the target opens with that handoff as its first prompt. This path never invokes the
# OpenCode model or its API, so it still works when the OpenCode quota is exhausted. When
# earlier handoffs already link the conversation to target sessions, the hotkey first
# offers to resume the newest of them with only the messages since its last handoff, or to
# start a new one.
#
# Alt-F on a session row copies that conversation to the clipboard, formatted: the same
# chat-only export, rendered to HTML (monospace, colour-coded speaker labels) and put on
# the clipboard alongside the markdown as a plain-text fallback -- so Word/Outlook/Slack
# paste it formatted while a plain textarea gets the markdown. Opens nothing. Needs pandoc
# in WSL. (Terminal ANSI colour can't be recovered here: a finished session is plain JSON
# in opencode.db, with no scrollback and no escape codes to convert.)
#
# Tab marks a row (fzf multi-select). Mark 2+ session rows and press Enter (or Alt-X /
# Alt-C) and it does NOT open each: it merges their chats into ONE chat-only handoff and
# starts a single new opencode/codex/claude session seeded with it, for one interrelated
# discussion across the threads. The new session runs in a folder chosen from the marked
# sessions' own working dirs -- picked automatically when they share one, otherwise a small
# folder picker among them. Alt-F on 2+ marked rows copies one combined formatted export.
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
#             Git for Windows' bash; fzf, pandoc, Python and the other CLIs come from the
#             Windows PATH, and tabs open in PowerShell 7, whose profile supplies per-shell
#             tools such as fnm's codex. No WSL is used.
#
# Requirements (wsl backend):
#   - Windows with WSL2, and OpenCode installed INSIDE WSL (data under ~/.local/share/opencode).
#   - Windows Terminal (wt.exe) -- used to open the resumed sessions as tabs.
#   - The Linux build of fzf installed in WSL (NOT fzf.exe -- the Windows build
#     mis-parses Windows Terminal mouse input). apt: `sudo apt install fzf`, or grab a
#     release binary into ~/.local/bin. It's found via the WSL login-shell PATH.
#   - Python 3 -- used to read opencode.db read-only and to snapshot it. apt: `sudo apt install python3`.
#   - `opencode` reachable from the WSL login shell (bash -lic).
#   - `codex` / `claude` likewise, but only if you use the Alt-X / Alt-C handoff.
#   - `pandoc` in WSL, but only for the Alt-F clipboard export. apt: `sudo apt install pandoc`.
#
# Auto-detected (no per-machine editing needed): the default WSL distro, the fzf path, and
# the OpenCode data directory and database (respecting OPENCODE_DB and XDG_DATA_HOME).
# Overrides: set $env:WSL_DISTRO to force a distro, $env:WSL_USER to force the home user.
#
# Usage: run under Windows PowerShell, e.g. a shortcut with target:
#   powershell.exe -NoExit -ExecutionPolicy Bypass -File "C:\path\to\recent-opencode.ps1"

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

$enabledTools = @(if ($env:AGENT_HUB_TOOLS) {
    $env:AGENT_HUB_TOOLS.ToLowerInvariant() -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
} else {
    'codex', 'claude', 'opencode'
})
$codexEnabled = 'codex' -in $enabledTools
$claudeEnabled = 'claude' -in $enabledTools
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

    # Resolve the WSL user, fzf path, and OpenCode paths in one non-interactive sh call
    # (~200ms) instead of spawning several `bash -lic` login shells (~700-1200ms each).
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
    $probe = @(wsl.exe -d $distro -- sh $probeShWsl 2>$null)
    $wslUser       = if ($env:WSL_USER) { $env:WSL_USER } elseif ($probe.Count -ge 1 -and $probe[0]) { "$($probe[0])".Trim() } else { (wsl -d $distro -- whoami).Trim() }
    $bashHome      = "/home/$wslUser"
    $fzfPath       = if ($probe.Count -ge 2 -and $probe[1]) { "$($probe[1])".Trim() } else { "$bashHome/.local/bin/fzf" }
    $opencodeData  = if ($probe.Count -ge 3 -and $probe[2]) { "$($probe[2])".Trim() } else { "$bashHome/.local/share/opencode" }
    $opencodeDbWsl = if ($probe.Count -ge 4 -and $probe[3]) { "$($probe[3])".Trim() } else { "$opencodeData/opencode.db" }
    $bashCommand   = 'bash'
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
    $bashCommand = "& '$gitBash'"
    $tabShell = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
}
# Run a helper script in the backend's bash. Leave the output unpiped for fzf so the
# console stays attached (see the fzf notes below).
function Invoke-Bash {
    if ($backend -eq 'wsl') { wsl.exe -d $distro -- bash @args } else { & $gitBash @args }
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
$expectKeys = @($(if ($codexEnabled) { 'alt-x' }), $(if ($claudeEnabled) { 'alt-c' }), 'alt-f', 'alt-h', 'alt-s') -join ','
$headerActions = @('enter: open', 'tab: mark', $(if ($codexEnabled) { 'alt-x: codex' }), $(if ($claudeEnabled) { 'alt-c: claude' }), 'alt-f: copy', 'alt-h: hide', 'alt-s: show', 'esc: reload') -join ' | '
$fzfSh = @"
#!/bin/bash
# `$1 = list file (CRLF from PowerShell -- strip CRs), `$2 = pick output file
tr -d '\r' < "`$1" | "$fzfPath" \
    --with-nth=1 --delimiter=`$'\t' \
    --multi \
    --expect=$expectKeys \
$clickBinds
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

# --- Handoff support (Codex & Claude) ----------------------------------------------
# Alt-X on a row continues that conversation in codex, Alt-C in claude, in the same
# repo/folder. NOTHING here goes through OpenCode's model or API: opencode.db is read
# read-only, the export below is done locally, and the tab launches the target directly --
# so the handoff still works with the OpenCode quota exhausted.
#
# Handoffs live in the WSL-local /tmp (reachable from Windows via \\wsl$): agents read it
# from inside WSL, and keeping it out of the repo means no stray file to commit. The
# windows backend uses %TEMP% and hands agents the path with forward slashes, which they
# read fine and which keeps the 'recent-opencode-handoff/<id>-' link pattern identical.
if ($backend -eq 'wsl') {
    $handoffWsl = '/tmp/recent-opencode-handoff'
    $handoffWin = "\\wsl$\$distro\tmp\recent-opencode-handoff"
} else {
    $handoffWin = Join-Path $env:TEMP 'recent-opencode-handoff'
    $handoffWsl = $handoffWin -replace '\\','/'
}
New-Item -ItemType Directory -Path $handoffWin -Force | Out-Null

# export-session.py: read one session's messages from opencode.db directly (~8ms) and
# emit only the compact fields Get-ChatMessages / Get-HandoffStateMarkdown use, without
# booting the OpenCode runtime or sending megabytes of raw tool output through ConvertFrom-Json.
$exportPyWin = Join-Path $tmpWin 'export-session.py'; $exportPyWsl = "$tmpWsl/export-session.py"
$exportPy = @'
import json, os, re, sqlite3, sys

db, sid, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
if not os.path.isfile(db):
    sys.exit(1)

err_pat = re.compile(r'(?im)^(error|failed|exception|traceback|.*\b(denied|not found|cannot|unable)\b)')
stat_pat = re.compile(r'(?i)error|fail|abort|cancel')

conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
messages = []
for msg_type, data in conn.execute(
        "SELECT type, data FROM session_message WHERE session_id = ? ORDER BY seq ASC",
        (sid,)):
    if msg_type not in ("user", "assistant"):
        continue
    try:
        msg = json.loads(data)
    except Exception:
        continue
    if not isinstance(msg, dict):
        continue
    created = (msg.get("time") or {}).get("created")
    if msg_type == "user":
        messages.append({"type": "user", "time": {"created": created}, "text": msg.get("text") or ""})
        continue
    blocks = []
    for b in msg.get("content") or []:
        if not isinstance(b, dict):
            continue
        btype = b.get("type")
        if btype == "text":
            blocks.append({"type": "text", "text": b.get("text") or ""})
        elif btype == "tool":
            st = b.get("state") or {}
            inp = st.get("input") if isinstance(st.get("input"), dict) else {}
            slim_in = {k: inp[k] for k in ("file_path", "path", "notebook_path", "url", "pattern", "glob", "command") if inp.get(k)}
            txt = "\n".join(c.get("text", "") for c in (st.get("content") or []) if isinstance(c, dict) and c.get("type") == "text").strip()
            status = str(st.get("status") or "")
            keep = bool(txt) and (bool(stat_pat.search(status)) or bool(err_pat.search(txt)))
            slim_content = [{"type": "text", "text": txt[:700] + (" ..." if len(txt) > 700 else "")}] if keep else []
            blocks.append({"type": "tool", "name": b.get("name") or "", "state": {"status": status, "input": slim_in, "content": slim_content}})
    messages.append({"type": "assistant", "time": {"created": created}, "content": blocks})

with open(out_path, "w", encoding="utf-8", newline="\n") as f:
    json.dump({"messages": messages}, f)
'@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($exportPyWin, $exportPy)
$exportJsonWin = Join-Path $tmpWin 'export.json'; $exportJsonWsl = "$tmpWsl/export.json"

# claude.sh / codex.sh: the prompt lives in a script file, not in the wt/wsl command line --
# wt treats ';' as its own separator and re-quotes nested arguments, which mangles prose.
# Here the only argument that has to survive is a path.
$claudeShWin = Join-Path $tmpWin 'claude.sh'; $claudeShWsl = "$tmpWsl/claude.sh"
$claudeSh = @"
#!/bin/bash
# `$1 = handoff markdown path, `$2 = claude session to resume with it (none: start a new one).
if [ -n "`$2" ]; then
    exec claude --resume "`$2" "[Continued from OpenCode] Read `$1 -- the conversation continued in OpenCode after you last saw it. It holds a compact state pack and only the chat messages since then. Tool outputs and quoted file contents may be stale, so re-read live files from disk before relying on them. Tell me what changed and what you plan to do next."
fi
transition_title=`$(sed -n 's/^- Conversation title: //p' "`$1" | head -n 1)
claude "[Transitioned from OpenCode; inherited title: `$transition_title] Read `$1 -- it is a chat handoff, not a true session resume. It starts with a compact state pack, then the chat transcript. Reconstruct the prior work from the state pack first: current objective, decisions, files touched or mentioned, commands/tests run, failures, and likely next action. Then read the transcript for nuance. Tool outputs and quoted file contents may be stale or abbreviated, so re-read live files from disk before relying on them. Start by telling me your understanding of the state and what you plan to do next."
"@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($claudeShWin, $claudeSh)

$codexShWin = Join-Path $tmpWin 'codex.sh'; $codexShWsl = "$tmpWsl/codex.sh"
$codexSh = @"
#!/bin/bash
# `$1 = handoff markdown path, `$2 = codex session to resume with it (none: start a new one).
if [ -n "`$2" ]; then
    exec codex -c tui.fullscreen_transcript=false resume "`$2" "[Continued from OpenCode] Read `$1 -- the conversation continued in OpenCode after you last saw it. It holds a compact state pack and only the chat messages since then. Tool outputs and quoted file contents may be stale, so re-read live files from disk before relying on them. Tell me what changed and what you plan to do next."
fi
transition_title=`$(sed -n 's/^- Conversation title: //p' "`$1" | head -n 1)
codex -c tui.fullscreen_transcript=false "[Transitioned from OpenCode; inherited title: `$transition_title] Read `$1 -- it is a chat handoff, not a true session resume. It starts with a compact state pack, then the chat transcript. Reconstruct the prior work from the state pack first: current objective, decisions, files touched or mentioned, commands/tests run, failures, and likely next action. Then read the transcript for nuance. Tool outputs and quoted file contents may be stale or abbreviated, so re-read live files from disk before relying on them. Start by telling me your understanding of the state and what you plan to do next."
"@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($codexShWin, $codexSh)

# links-claude.sh: claude sessions seeded or resumed from this OpenCode session's handoffs.
# Handoff file names start with this session id and end with the export time, so the
# transcripts alone hold the links and the newest export stamp tells which messages the
# claude side has already seen. A backgrounded Claude session continues under a new id, so
# follow continued-in records to the live transcript. Emits
# "mtime<TAB>id<TAB>cwd<TAB>last-export-stamp<TAB>title", newest first.
$linksClaudeShWin = Join-Path $tmpWin 'links-claude.sh'; $linksClaudeShWsl = "$tmpWsl/links-claude.sh"
$linksClaudeSh = @"
#!/bin/bash
# `$1 = opencode session id
src="`$1"; projects="$bashHome/.claude/projects"
grep -arlF --include='*.jsonl' "recent-opencode-handoff/`$src-" "`$projects" 2>/dev/null | grep -v '/subagents/' |
while read -r f; do
    head -n 1 "`$f" | grep -aEq '"parent_thread_id":|"source":\{"subagent":|"thread_source":"(subagent|guardian_review)"' && continue
    while next=`$(grep -am1 -oE '"continuedInSessionId":"[0-9a-f-]{36}"' "`$f" | cut -d'"' -f4); [ -n "`$next" ] && [ -f "`$(dirname "`$f")/`$next.jsonl" ]; do
        f="`$(dirname "`$f")/`$next.jsonl"
    done
    stamp=`$(grep -aohE "recent-opencode-handoff/`$src-[0-9]{8}-[0-9]{6}" "`$f" | grep -aoE '[0-9]{8}-[0-9]{6}`$' | sort | tail -n 1)
    [ -n "`$stamp" ] || continue
    title=`$(grep -aoE '"customTitle":"[^"]*"' "`$f" | tail -n 1 | cut -d'"' -f4)
    [ -n "`$title" ] || title=`$(grep -aoE '"aiTitle":"[^"]*"' "`$f" | tail -n 1 | cut -d'"' -f4)
    [ -n "`$title" ] || title=`$(grep -am1 -oE 'inherited title: [^]]*' "`$f" | cut -c18-)
    cwd=`$(grep -aoE '"relocatedCwd":"[^"]*"' "`$f" | tail -n 1 | cut -d'"' -f4)
    [ -n "`$cwd" ] || cwd=`$(grep -am1 -oE '"cwd":"[^"]*"' "`$f" | cut -d'"' -f4)
    printf '%s\t%s\t%s\t%s\t%s\n' "`$(stat -c %Y "`$f")" "`$(basename "`$f" .jsonl)" "`$cwd" "`$stamp" "`$title"
done | sort -rn
"@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($linksClaudeShWin, $linksClaudeSh)

# links-codex.sh: codex sessions seeded or resumed from this OpenCode session's handoffs.
# Same contract and output as links-claude.sh, over ~/.codex/sessions.
$linksCodexShWin = Join-Path $tmpWin 'links-codex.sh'; $linksCodexShWsl = "$tmpWsl/links-codex.sh"
$linksCodexSh = @"
#!/bin/bash
# `$1 = opencode session id
src="`$1"; sessions="$bashHome/.codex/sessions"
grep -arlF --include='*.jsonl' "recent-opencode-handoff/`$src-" "`$sessions" 2>/dev/null |
while read -r f; do
    head -n 1 "`$f" | grep -aEq '"parent_thread_id":|"source":\{"subagent":|"thread_source":"(subagent|guardian_review)"' && continue
    stamp=`$(grep -aohE "recent-opencode-handoff/`$src-[0-9]{8}-[0-9]{6}" "`$f" | grep -aoE '[0-9]{8}-[0-9]{6}`$' | sort | tail -n 1)
    [ -n "`$stamp" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "`$(stat -c %Y "`$f")" "`$(basename "`$f" .jsonl | grep -aoE '[0-9a-f-]{36}`$')" \
        "`$(grep -am1 -oE '"cwd":"[^"]*"' "`$f" | cut -d'"' -f4)" "`$stamp" "`$(grep -am1 -oE 'inherited title: [^]]*' "`$f" | cut -c18-)"
done | sort -rn
"@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($linksCodexShWin, $linksCodexSh)

$linkPickShWin = Join-Path $tmpWin 'link-pick.sh'; $linkPickShWsl = "$tmpWsl/link-pick.sh"
$linkPickSh = @"
#!/bin/bash
tr -d '\r' < "`$1" | "$fzfPath" \
    --with-nth=1 --delimiter=`$'\t' \
$clickBinds
    --prompt="continue in `$3> " --reverse \
    --header="resume a `$3 session linked by earlier handoffs, or start a new one | esc: cancel" \
    > "`$2"
"@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($linkPickShWin, $linkPickSh)

# combo.sh: seed a BRAND-NEW session (claude, codex, or opencode) with a handoff merged from several
# past sessions -- the "combine" flow. Same reason as codex.sh for living in a script file:
# the only argument that must survive wt/wsl re-quoting is a path; the long prompt is baked
# in here. `$1 = tool (claude|codex|opencode), `$2 = combined handoff markdown path.
$comboShWin = Join-Path $tmpWin 'combo.sh'; $comboShWsl = "$tmpWsl/combo.sh"
$comboSh = @"
#!/bin/bash
# `$1 = tool (claude|codex|opencode), `$2 = combined handoff markdown path.
prompt="Read `$2 -- it is a COMBINED chat handoff, not a true session resume. Each # Thread section starts with a compact state pack, then that thread transcript. Reconstruct the related work across all threads first: current objectives, decisions, files touched or mentioned, commands/tests run, failures, and likely next action. Then read the transcripts for nuance. Tool outputs and quoted file contents may be stale or abbreviated, so re-read live files from disk before relying on them. Start by summarising each thread, how they connect, and what you plan to do next."
if [ "`$1" = codex ]; then
    codex -c tui.fullscreen_transcript=false "`$prompt"
elif [ "`$1" = opencode ]; then
    opencode --prompt "`$prompt"
else
    claude "`$prompt"
fi
"@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($comboShWin, $comboSh)
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
    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    if (-not $scriptPath) { Write-Host "Cannot reload: script path is unknown"; Start-Sleep -Milliseconds 900; return }
    Write-Host "Reloading script..."
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
    $title = if ($tool -eq 'opencode') { $name } else { "${tool}: $name" }
    Open-WtTab $title $path $(if ($tool -eq 'codex') { 'codex -c tui.fullscreen_transcript=false' } else { $tool })
}

# Read one OpenCode session as chat messages: @{ Role='User'|'OpenCode'; Body=... }.
#
# opencode.db stores each message's payload as JSON. export-session.py reads the rows
# directly in ~8ms and emits the same message structure `opencode session export` uses,
# without starting the OpenCode CLI. It is loaded once per flow and shared by the handoff,
# clipboard and combine paths, so all three can never drift apart on what counts as a message.
#
# What survives: user and assistant prose, in order. What's dropped, deliberately --
#   tool blocks            : stale snapshots; a reader/agent re-reads the live files
#   reasoning              : internal model reasoning, not decisions
#   synthetic / system     : harness instructions the user never typed
#   idle / model-switched  : bookkeeping records, not conversation
# $since keeps only messages created after it (the delta for a resumed handoff).
function Get-OpenCodeExport($id) {
    Remove-Item $exportJsonWin -ErrorAction SilentlyContinue
    Invoke-Bash $pyShWsl $exportPyWsl $opencodeDbWsl $id $exportJsonWsl | Out-Null
    if (-not (Test-Path $exportJsonWin)) { return $null }
    try { return (Get-Content $exportJsonWin -Raw | ConvertFrom-Json) } catch { return $null }
}

function Test-MessageAfter($message, $since) {
    if (-not $since) { return $true }
    $created = $message.time.created
    if (-not $created) { return $true }
    return ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$created) -gt $since)
}

function Get-MessageText($message) {
    if ($message.type -eq 'user') { return "$($message.text)" }
    if ($message.type -eq 'assistant') {
        return (@($message.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { "$($_.text)" }) -join "`n`n")
    }
    return ''
}

function Get-ChatMessages($export, $since) {
    $msgs = New-Object System.Collections.ArrayList
    if (-not $export) { return $msgs }
    foreach ($m in @($export.messages)) {
        if ($m.type -ne 'user' -and $m.type -ne 'assistant') { continue }
        if (-not (Test-MessageAfter $m $since)) { continue }
        $body = (Get-MessageText $m).Trim()
        # Harness-injected blocks the user never wrote.
        $body = [regex]::Replace($body, '(?s)<system-reminder>.*?</system-reminder>', '')
        $body = [regex]::Replace($body, '(?s)<local-command-(stdout|stderr)>.*?</local-command-\1>', '')
        $body = $body.Trim()
        if (-not $body) { continue }
        [void]$msgs.Add([pscustomobject]@{
            Role = $(if ($m.type -eq 'user') { 'User' } else { 'OpenCode' })
            Body = $body
        })
    }
    return $msgs
}

# Compact state pack from OpenCode tool calls and recent chat. This is not a substitute
# for reading live files; it is a recovery map for a new agent session.
function Get-HandoffStateMarkdown($export, $label, $since) {
    $lastUser = $null; $lastAssistant = $null
    $calls = New-Object System.Collections.ArrayList
    $files = New-Object System.Collections.ArrayList
    $snips = New-Object System.Collections.ArrayList

    if ($export) {
        foreach ($m in @($export.messages)) {
            if (-not (Test-MessageAfter $m $since)) { continue }
            $body = (Get-MessageText $m).Trim()
            $body = [regex]::Replace($body, '(?s)<system-reminder>.*?</system-reminder>', '')
            $body = [regex]::Replace($body, '(?s)<local-command-(stdout|stderr)>.*?</local-command-\1>', '')
            $body = $body.Trim()
            if ($body) {
                if ($m.type -eq 'user') { $lastUser = $body }
                elseif ($m.type -eq 'assistant') { $lastAssistant = $body }
            }

            if ($m.type -ne 'assistant') { continue }
            foreach ($b in @($m.content | Where-Object { $_.type -eq 'tool' })) {
                $name = "$($b.name)"; $input = $b.state.input; $detail = $null
                foreach ($k in @('file_path','path','notebook_path','url','pattern','glob','command')) {
                    if ($input -and $input.PSObject.Properties.Name -contains $k -and $input.$k) { $detail = "$($input.$k)"; break }
                }
                $summary = if ($detail) { "${name}: $detail" } else { $name }
                if ($calls.Count -lt 30) { [void]$calls.Add($summary) }
                foreach ($k in @('file_path','path','notebook_path')) {
                    if ($input -and $input.PSObject.Properties.Name -contains $k -and $input.$k) { [void]$files.Add("$($input.$k)") }
                }

                $content = (@($b.state.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { "$($_.text)" }) -join "`n").Trim()
                if (-not $content) { continue }
                $failed = "$($b.state.status)" -match '(?i)error|fail|abort|cancel'
                $interesting = $failed -or $content -match '(?im)^(error|failed|exception|traceback|.*\b(denied|not found|cannot|unable)\b)'
                if ($interesting -and $snips.Count -lt 8) {
                    if ($content.Length -gt 700) { $content = $content.Substring(0,700) + ' ...' }
                    [void]$snips.Add($content)
                }
            }
        }
    }

    $out = New-Object System.Collections.ArrayList
    [void]$out.Add("## Handoff State Pack")
    [void]$out.Add("")
    [void]$out.Add("This is not a true resume. It is a compact recovery map extracted from the $label session. Verify live files before relying on any quoted content.")
    if ($lastUser) { [void]$out.Add(""); [void]$out.Add("### Last User Ask"); [void]$out.Add(""); [void]$out.Add((Limit-HandoffText $lastUser)) }
    if ($lastAssistant) { [void]$out.Add(""); [void]$out.Add("### Last Assistant Message"); [void]$out.Add(""); [void]$out.Add((Limit-HandoffText $lastAssistant)) }
    $uniqFiles = @($files | Where-Object { $_ } | Select-Object -Unique | Select-Object -First 30)
    if ($uniqFiles) { [void]$out.Add(""); [void]$out.Add("### Files Touched Or Mentioned By Tools"); [void]$out.Add(""); foreach ($f in $uniqFiles) { [void]$out.Add("- ``$f``") } }
    if ($calls.Count) { [void]$out.Add(""); [void]$out.Add("### Recent Tool/Command Calls"); [void]$out.Add(""); foreach ($c in @($calls | Select-Object -Last 30)) { [void]$out.Add("- $c") } }
    if ($snips.Count) { [void]$out.Add(""); [void]$out.Add("### Error/Failure Snippets"); [void]$out.Add(""); foreach ($s in $snips) { [void]$out.Add('```text'); [void]$out.Add($s); [void]$out.Add('```') } }
    [void]$out.Add(""); [void]$out.Add("## Chat Transcript")
    return ($out.ToArray() -join "`n")
}

function New-HandoffFileName($prefix) {
    $safe = $prefix -replace '[^A-Za-z0-9._-]', '_'
    return ("{0}-{1}.md" -f $safe, (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

function Limit-HandoffText($text, $max = 3000) {
    if (-not $text) { return $text }
    if ($text.Length -le $max) { return $text }
    return $text.Substring(0, $max) + " ...`n[truncated in state pack; read transcript below for full context]"
}
# Messages -> markdown. '## User' / '## OpenCode' is the canonical rendering: it IS the
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

# Export a session as a chat-only markdown handoff and return its WSL path, or $null when
# there are no messages (after $since, when given).
function New-Handoff($id, $cwd, $title, $since) {
    $export = Get-OpenCodeExport $id
    $msgs = @(Get-ChatMessages $export $since)
    if (-not $msgs) { return $null }
    $safeTitle = "$title" -replace '[\r\n\]]', ' '

    $head = @(
        "# Handoff from an OpenCode session"
        ""
        "- Session id: ``$id``"
        "- Repo / working dir: ``$cwd`` (you are running in it now)"
        "- Conversation title: $safeTitle"
        "- Exported: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        "- Source session: ``$id`` in ``opencode.db``"
        $(if ($since) { "- Only messages after $($since.ToString('yyyy-MM-dd HH:mm:ss')), the previous handoff to you" })
        ""
        "Includes a compact state pack plus chat transcript. Tool outputs may be abbreviated."
        "Anything quoted from a file is a snapshot from when it was written -- read"
        "the file from disk instead of trusting it."
        ""
        "---"
    ) -join "`n"

    # LF, not WriteAllLines' CRLF: this is read inside WSL, and message bodies already
    # carry LF -- mixing the two would leave stray CRs mid-document.
    $fileName = New-HandoffFileName $id
    $fileWin = Join-Path $handoffWin $fileName
    [System.IO.File]::WriteAllText($fileWin, $head + "`n" + (Get-HandoffStateMarkdown $export 'OpenCode' $since) + "`n" + (ConvertTo-ChatMarkdown $msgs) + "`n")
    return "$handoffWsl/$fileName"
}

# Where a transfer hotkey continues: a target session linked by earlier handoffs (newest
# first, so Enter resumes it) or a new one. Returns @{ Id; Cwd; Title; Since } -- Id $null
# for a new session -- or $null when cancelled.
function Select-HandoffTarget($id, $tool) {
    # Native Windows cwds arrive JSON-escaped (C:\\dir).
    $links = @($(if ($tool -eq 'codex') {
        Invoke-Bash $linksCodexShWsl $id
    } else {
        Invoke-Bash $linksClaudeShWsl $id
    }) | Where-Object { $_ } | ForEach-Object { $_ -replace '\\\\','\' })
    $new = [pscustomobject]@{ Id = $null }
    if (-not $links) { return $new }
    $rows = @(foreach ($link in $links) {
        $mtime, $linkId, $linkCwd, $stamp, $linkTitle = $link -split "`t"
        $folder = (($linkCwd -replace '\\','/') -split '/' | Select-Object -Last 2) -join '/'
        $age = Format-Age ([DateTimeOffset]::FromUnixTimeSeconds([long]$mtime).LocalDateTime)
        "resume ${tool}: {0} - {1} - {2} ago [..-{3}]`t{4}" -f $folder, $(if ($linkTitle) { $linkTitle } else { 'untitled' }), $age, ($linkId -split '-')[-1], $link
    }) + "+ new $tool session with the full handoff`t__NEW__"
    [System.IO.File]::WriteAllLines($dirListWin, [string[]]$rows)
    Remove-Item $pickWin -ErrorAction SilentlyContinue
    Invoke-Bash $linkPickShWsl $dirListWsl $pickWsl $tool
    $p = @(if (Test-Path $pickWin) { Get-Content $pickWin | Where-Object { $_ } })
    if (-not $p) { return $null }
    $link = $p[0].Substring($p[0].IndexOf("`t") + 1)
    if ($link -eq '__NEW__') { return $new }
    $mtime, $linkId, $linkCwd, $stamp, $linkTitle = $link -split "`t"
    # Handoff names carry the local export time; this session's messages after it are new there.
    $since = if ($stamp) { [DateTimeOffset][datetime]::ParseExact($stamp, 'yyyyMMdd-HHmmss', $null) }
    return [pscustomobject]@{ Id = $linkId; Cwd = $linkCwd; Title = $linkTitle; Since = $since }
}

# A transfer hotkey: continue this conversation in the target, seeded with the handoff -- a new
# session in the same folder, or a linked one resumed in its own folder with the messages since.
function Invoke-Handoff($tool, $id, $cwd, $title) {
    $target = Select-HandoffTarget $id $tool
    if (-not $target) { return }
    Write-Host "Exporting chat for $tool..." -NoNewline
    $handoff = New-Handoff $id $cwd $title $target.Since
    Write-Host "`r                           `r" -NoNewline
    if ($target.Id) {
        $linkTitle = if ($target.Title) { $target.Title } else { $target.Id }
        $command = if ($tool -eq 'codex') {
            if ($handoff) { "$bashCommand $codexShWsl $handoff $($target.Id)" } else { "codex -c tui.fullscreen_transcript=false resume $($target.Id)" }
        } else {
            if ($handoff) { "$bashCommand $claudeShWsl $handoff $($target.Id)" } else { "claude --resume $($target.Id)" }
        }
        Open-WtTab "${tool}: $linkTitle" $target.Cwd $command
        return
    }
    if (-not $handoff) { Write-Host "Nothing to hand off: no chat messages in $id"; Start-Sleep -Milliseconds 900; return }
    $tabTitle = if ($title) { "${tool}: $title" } else { "${tool}: $id" }
    $script = if ($tool -eq 'codex') { $codexShWsl } else { $claudeShWsl }
    Open-WtTab $tabTitle $cwd "$bashCommand $script $handoff"
}

# --- Alt-F: formatted chat export to the clipboard ---------------------------------
# Puts the chat on the clipboard in TWO flavours at once, so the paste target decides:
# rich HTML for Word/Outlook/OneNote/Slack, and the markdown itself as the plain-text
# fallback for a textarea or another AI chat. Both are rendered from the same markdown.
#
# Note on the ANSI/`script -qefc | aha` approach: that captures colour out of a LIVE pty.
# These rows are finished sessions stored as plain JSON on disk -- there is no scrollback
# to capture and not one escape byte to convert, and re-running a session to produce
# colour would cost Claude tokens. So the colour is applied here at render time instead.
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
#   citations             : '@claude' / '@ghabre' would be parsed as citation keys.
#   subscript/superscript : '~/.claude ... ~/.local' -- two paths on one line pair their
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
    foreach ($sp in @(@{ n='user'; c='#1b7f3b' }, @{ n='opencode'; c='#6f42c1' })) {
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
function Invoke-CopyExport($id, $cwd) {
    Write-Host "Formatting chat for the clipboard..." -NoNewline
    $export = Get-OpenCodeExport $id
    $msgs = @(Get-ChatMessages $export)
    if (-not $msgs) {
        Write-Host "`r                                    `r" -NoNewline
        Write-Host "Nothing to copy: no chat messages in $id"; Start-Sleep -Milliseconds 900; return
    }
    # One markdown document: it is both the plain-text flavour and pandoc's input.
    $md = (@(
        "# OpenCode chat"
        ""
        "- Session: ``$id``"
        "- Folder: ``$cwd``"
        "- Exported: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        ""
        "Includes a compact state pack plus chat transcript. Tool outputs may be abbreviated."
        ""
        "---"
    ) -join "`n") + "`n" + (Get-HandoffStateMarkdown $export 'OpenCode') + "`n" + (ConvertTo-ChatMarkdown $msgs) + "`n"

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

# --- Combine multiple sessions -----------------------------------------------------
# Tab-marking 2+ rows and pressing enter/alt-x/alt-c does NOT open each: it merges the
# marked sessions' chats into ONE handoff and seeds a single fresh opencode/codex/claude
# session (or, with alt-f, one combined clipboard copy). Everything reuses the same chat
# extraction as the single-session flows (Get-ChatMessages / ConvertTo-ChatMarkdown), so
# what counts as "the chat" never drifts between the single and combined paths.

# Render the marked sessions as one markdown body of '# Thread N' sections. Returns
# @{ Body=<markdown>; Count=<threads with chat> }, or $null if none had any messages.
function Build-CombinedThreads($items) {
    $body = New-Object System.Collections.ArrayList
    $n = 0
    foreach ($it in $items) {
        $export = Get-OpenCodeExport $it.Id
        $msgs = @(Get-ChatMessages $export)
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
        [void]$body.Add((Get-HandoffStateMarkdown $export 'OpenCode'))
        [void]$body.Add((ConvertTo-ChatMarkdown $msgs))
    }
    if ($n -eq 0) { return $null }
    return @{ Body = ($body.ToArray() -join "`n"); Count = $n }
}

# Merge the marked sessions into one handoff file; return its WSL path (or $null).
function New-CombinedHandoff($items, $cwd) {
    $r = Build-CombinedThreads $items
    if (-not $r) { return $null }
    $head = @(
        "# Combined handoff from multiple OpenCode sessions"
        ""
        "- Threads merged: $($r.Count)"
        "- This session is running in: ``$cwd``"
        "- Exported: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        ""
        "Each '# Thread' below has a compact state pack plus chat transcript."
        "The threads were separate sessions and they are related -- read them together."
        "Anything quoted from a file is a stale snapshot; read the file from disk instead."
        ""
        "==="
    ) -join "`n"
    # LF, not WriteAllLines' CRLF (read inside WSL); overwrite -- only one combine at a time.
    $fileName = New-HandoffFileName 'combined'
    $fileWin = Join-Path $handoffWin $fileName
    [System.IO.File]::WriteAllText($fileWin, $head + "`n" + $r.Body + "`n")
    return "$handoffWsl/$fileName"
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

# enter/alt-x/alt-c on 2+ marked rows: merge and open one new opencode/codex/claude session.
function Invoke-CombineSession($items, $tool) {
    $cwd = Select-CombinedCwd $items
    if (-not $cwd) { return }   # cancelled the folder pick
    Write-Host ("Merging {0} chats for {1}..." -f $items.Count, $tool) -NoNewline
    $handoff = New-CombinedHandoff $items $cwd
    Write-Host "`r                              `r" -NoNewline
    if (-not $handoff) { Write-Host "Nothing to combine: no chat messages in the marked sessions"; Start-Sleep -Milliseconds 900; return }
    Open-WtTab ("{0}: combined x{1}" -f $tool, $items.Count) $cwd "$bashCommand $comboShWsl $tool $handoff"
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
        "# Combined OpenCode chats"
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
if (-not $sessions) { Write-Host "No past sessions found in $opencodeDbWsl -- use the top row to start a new one." }

while ($true) {
    # fzf (Linux, via WSL): list in via file, pick out via file, console untouched so
    # keyboard/mouse/resize all reach fzf. Wheel scrolls, a second click on the
    # highlighted row (or Enter) opens.
    Remove-Item $pickWin -ErrorAction SilentlyContinue
    Invoke-Bash $fzfShWsl $listWsl $pickWsl

    # --expect puts the pressed key on line 1 ('' for Enter/click, 'alt-x', 'alt-c', 'alt-f',
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
    # everything below just uses $tool. (Alt-F launches nothing and ignores it.)
    $tool = if ($key -eq 'alt-x') { 'codex' } elseif ($key -eq 'alt-c') { 'claude' } else { 'opencode' }

    # Tab-marking 2+ real session rows means "combine", not "open each": merge their
    # chats into one handoff and seed a single new session (enter/transfer key), or one
    # combined clipboard copy (alt-f). The __NEW__ row can't be combined, so drop it first.
    $items = @(foreach ($row in $picked) {
        $p = $row -split "`t"
        [pscustomobject]@{ Id = $p[1]; Cwd = $p[2]; Title = $p[4] }
    })
    $realItems = @($items | Where-Object { $_.Id -ne '__NEW__' })
    if ($realItems.Count -ge 2) {
        if ($key -eq 'alt-f') { Invoke-CombineCopy $realItems }
        else                  { Invoke-CombineSession $realItems $tool }
        continue
    }

    foreach ($it in $items) {
        if ($key -eq 'alt-f') {   # copy to clipboard, open nothing
            if ($it.Id -eq '__NEW__') { Write-Host "Nothing to copy: that row starts a new session."; Start-Sleep -Milliseconds 900; continue }
            Invoke-CopyExport $it.Id $it.Cwd; continue
        }
        if ($it.Id -eq '__NEW__') { Invoke-NewSession $tool; continue }   # top row: start fresh
        if ($tool -ne 'opencode') { Invoke-Handoff $tool $it.Id $it.Cwd $it.Title; continue }
        $tabTitle = if ($it.Title) { "opencode: $($it.Title)" } else { "opencode: $($it.Id)" }
        Open-WtTab $tabTitle $it.Cwd "opencode --session $($it.Id)"
    }
}
