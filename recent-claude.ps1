# recent-claude.ps1
#
# Fuzzy-picker for Claude Code sessions running inside WSL. Lists top-level transcripts
# updated within the last 40 days; pick one to resume in a new Windows Terminal tab.
# Picking takes two clicks: the first left-click on a row only highlights it, a second
# click on that same row opens it (Enter opens the highlighted row straight away). This
# is deliberately NOT fzf's own double-click, which demands two fast clicks with no mouse
# drift -- here the two clicks can be any distance apart in time.
# The picker stays up for more picks; Esc reloads this script in-place; close the window to quit.
#
# The top row ("+ New session...") starts a fresh conversation: it opens a folder picker
# listing the project root itself followed by its immediate subfolders (default C:\G\code,
# override with $env:CLAUDE_NEW_ROOT or $env:AGENT_HUB_NEW_ROOT), and launches a new session
# in the folder you pick -- `claude` on enter/click, `codex` on Alt-X, or `opencode` on Alt-O.
#
# Transfer hotkeys resume a unique linked destination automatically, importing only
# unseen messages and tool notes. Multiple branches require a destination choice.
# A repeated transfer with no new material resumes without adding a prompt.
# Tab marks multiple sessions; Enter or a transfer key continues their combined
# conversation, reusing the existing result when known.
# Transfer state and immutable payloads live in the gitignored .history folder beside this script,
# separately for each backend/distro. Keep this directory to preserve synchronization.
#
# On startup it also snapshots the transcripts (~/.claude/projects, plus history.jsonl) to
# a .tar.gz under .\backups\claude, but only if the newest snapshot is more than 24 hours old, and
# it keeps the 10 most recent. They land on the Windows side on purpose: the originals only
# exist inside the WSL VHD. Override the location with $env:CLAUDE_BACKUP_DIR.
#
# Backend: $env:AGENT_HUB_BACKEND = 'wsl' (default) or 'windows'.
#   wsl     : Claude Code installed INSIDE WSL; the requirements below apply as written.
#   windows : Claude Code installed natively (data under %USERPROFILE%\.claude). The same
#             helper scripts run under Git for Windows' bash; fzf, Python and the
#             other CLIs come from the Windows PATH, and tabs open in PowerShell 7, whose
#             profile supplies per-shell tools such as fnm's codex. No WSL is used.
#
# Requirements (wsl backend):
#   - Windows with WSL2, and Claude Code installed INSIDE WSL (data under ~/.claude).
#   - Windows Terminal (wt.exe) -- used to open the resumed sessions as tabs.
#   - The Linux build of fzf installed in WSL (NOT fzf.exe -- the Windows build
#     mis-parses Windows Terminal mouse input). apt: `sudo apt install fzf`, or grab a
#     release binary into ~/.local/bin. It's found via the WSL login-shell PATH.
#   - `claude` reachable from the WSL login shell (bash -lic).
#   - `codex` / `opencode` likewise, but only if you use the Alt-X / Alt-O handoff.
#   - Python 3.8+ with SQLite for conversation handoffs and combining.
#
# Auto-detected (no per-machine editing needed): the default WSL distro and the fzf path.
# Overrides: set $env:WSL_DISTRO to force a distro, $env:WSL_USER to force the home user.
#
# Usage: run under Windows PowerShell, e.g. a shortcut with target:
#   powershell.exe -NoExit -ExecutionPolicy Bypass -File "C:\path\to\recent-claude.ps1"

# Claude accounts: one session history (~/.claude), several logins. ~/.claude is the first
# account and every ~/.claude-* folder another, keeping only its login; claude-accounts.sh
# links the rest of each to ~/.claude. Alt-A cycles the active account, named by its login
# email in the prompt, and every launch, resume and handoff opens in it with the account's
# tab color. The last Alt-A stop is a new account: the next Claude launch creates
# ~/.claude-<n>, where Claude asks for the login once.

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
$codexEnabled = 'codex' -in $enabledTools
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
$tmpWin  = Join-Path $env:TEMP ("recent-claude-{0}" -f $PID)
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
# The shared history lives in the first account's ~/.claude; accounts only change the login.
$claudeConfigDirBash = "$bashHome/.claude"
$claude = ConvertFrom-WslPath $claudeConfigDirBash
$projects = "$claude\projects"
$sessDir  = "$claude\sessions"
$hubStateDir = Join-Path $env:LOCALAPPDATA 'AgentSessionHub'
$hiddenSessionsFile = Join-Path $hubStateDir 'hidden-claude-session-ids.txt'

# Locate wt.exe (may not be on PATH depending on launch context)
$wt = Get-Command wt.exe -ErrorAction SilentlyContinue
if ($wt) { $wt = $wt.Source } else { $wt = "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe" }
$wtWindow = if ($env:AGENT_SESSION_HUB_WINDOW) { $env:AGENT_SESSION_HUB_WINDOW } else { '0' }

# wt.exe splits its whole command line on ';' (titles and paths too), so a title such as
# "a; b" opens several broken tabs. '\;' is wt's literal semicolon.
# $color, when given, is the tab color: Claude tabs carry their account's.
function Open-WtTab($title, $cwd, $command, $color) {
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

$hubTool = 'claude'
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
$clickStateWsl = "/tmp/recent-claude-$PID-click.state"
$clickBinds = (@"
    --bind "focus:transform:echo {n} > $clickStateWsl" \
    --bind "left-click:transform:if [ \"\`$(cat $clickStateWsl 2>/dev/null)\" = \"{n}\" ]; then echo accept; fi" \
"@ -replace "`r`n","`n")

# --expect makes fzf print the pressed key as the FIRST line of the pick file (an empty
# first line for a plain Enter/click accept), so one picker can mean several things:
# open in claude, hand the session off to codex/opencode, copy it, or hide it from this picker.
$expectKeys = @($(if ($codexEnabled) { 'alt-x' }), $(if ($opencodeEnabled) { 'alt-o' }), 'alt-a', 'alt-h', 'alt-s') -join ','
# Rewritten before every pick so the prompt names the active account, in its tab color.
# No $script:account means the new-account stop, which will take the next color.
function Write-FzfScript {
    $label = if (-not $script:account) { 'NEW account' }
             elseif ($script:account.Email) { $script:account.Email -replace "'", '' }   # the prompt is single-quoted
             else { "$($script:account.Name.TrimStart('.')) (not logged in)" }
    $color = if ($script:account) { $script:account.Color } else { Get-HubClaudeAccountColor $claudeAccounts.Count }
    $headerActions = @('enter: open', 'tab: mark', $(if ($codexEnabled) { 'alt-x: codex' }), $(if ($opencodeEnabled) { 'alt-o: opencode' }), 'alt-a: next account', 'alt-h: hide', 'alt-s: show', 'alt-p: preview', 'esc: reload') -join ' | '
    $fzfSh = @"
#!/bin/bash
# `$1 = list file (CRLF from PowerShell -- strip CRs), `$2 = pick output file
tr -d '\r' < "`$1" | "$fzfPath" \
    --with-nth=1 --delimiter=`$'\t' \
    --multi \
    --expect=$expectKeys \
$clickBinds
$(Get-HubPreviewOptions "$bashHome/.claude/projects")
    --prompt='claude [$label] sessions> ' --color='prompt:$color' --reverse \
    --header='$headerActions' \
    > "`$2"
"@ -replace "`r`n","`n"
    [System.IO.File]::WriteAllText($fzfShWin, $fzfSh)
}

$showSh = @"
#!/bin/bash
tr -d '\r' < "`$1" | "$fzfPath" \
    --with-nth=1 --delimiter=`$'\t' \
    --multi \
$clickBinds
    --prompt='hidden claude sessions> ' --reverse \
    --header='enter: show | tab: mark multiple | esc: cancel' \
    > "`$2"
"@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($showShWin, $showSh)

# scan.sh: enumerate top-level transcripts natively (find over \\wsl$ from Windows is
# slow, and wsl.exe mangles backslash escapes like \t when passed as arguments -- a
# script file keeps them intact). Claude stores internal agents under subagents/, so
# exclude that path; headless runs (claude -p, Agent SDK) start with an sdk-* entrypoint,
# so exclude those too. This mirrors the Codex metadata filter.
# Emits "epoch-mtime<TAB>linux-path".
$scanShWin = Join-Path $tmpWin 'scan.sh'; $scanShWsl = "$tmpWsl/scan.sh"
$scanSh = @"
#!/bin/bash
if [ "`$1" = all ]; then
    find "`$2/projects" -name '*.jsonl' -not -path '*/subagents/*' -printf '%T@\t%p\n' 2>/dev/null
else
    find "`$2/projects" -name '*.jsonl' -mtime -40 -not -path '*/subagents/*' -printf '%T@\t%p\n' 2>/dev/null
fi |
while IFS=`$'\t' read -r session_mtime session_path; do
    if ! grep -am1 -oE '"entrypoint":"[^"]*"' "`$session_path" | grep -q '"sdk-'; then
        printf '%s\t%s\n' "`$session_mtime" "`$session_path"
    fi
done |
    sort -rn
"@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($scanShWin, $scanSh)

# --- New-session support -----------------------------------------------------------
# Root that the folder picker lists (immediate subfolders become new-session choices).
# Its first row can also create an initialized local Git project under this root.
# Override with $env:CLAUDE_NEW_ROOT or $env:AGENT_HUB_NEW_ROOT (a Windows path). WSL path derived like $tmpWsl.
$newRoot    = if ($env:CLAUDE_NEW_ROOT) { $env:CLAUDE_NEW_ROOT } elseif ($env:AGENT_HUB_NEW_ROOT) { $env:AGENT_HUB_NEW_ROOT } else { 'C:\G\code' }
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
# `$3 is the tool being started ('claude', 'codex' or 'opencode') -- it only ever labels
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

# --- Transcript backup -------------------------------------------------------------
# The transcripts under ~/.claude/projects are the only record of past conversations and
# they live inside the WSL VHD, so snapshots are written to the WINDOWS side: they then
# survive `wsl --unregister`, a VHD corruption, or a distro rebuild. ~1.7s and ~26MB per
# snapshot at 100MB of transcripts, so it runs inline at startup rather than in the
# background. Override the location with $env:CLAUDE_BACKUP_DIR.
$backupDir    = if ($env:CLAUDE_BACKUP_DIR) { $env:CLAUDE_BACKUP_DIR } else { Join-Path $PSScriptRoot 'backups\claude' }
$backupDirWsl = ConvertTo-WslPath $backupDir
$backupEvery  = 24   # hours between snapshots
$backupKeep   = 10   # snapshots retained; older ones are pruned

# backup.sh: throttle, snapshot, prune. All three decisions are driven by ONE source of
# truth -- the snapshot filenames themselves (claude-history-<stamp>.tar.gz). The stamp
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

newest=`$(ls -1 "`$dir"/claude-history-*.tar.gz 2>/dev/null | sort | tail -1)
if [ -n "`$newest" ]; then
    ts=`${newest##*/claude-history-}; ts=`${ts%.tar.gz}
    last=`$(date -d "`${ts:0:4}-`${ts:4:2}-`${ts:6:2} `${ts:9:2}:`${ts:11:2}:`${ts:13:2}" +%s 2>/dev/null)
    # Unparsable name (hand-renamed?) -> treat as no backup and take one; better an extra
    # snapshot than a skipped one.
    [ -n "`$last" ] && [ `$(( `$(date +%s) - last )) -lt "`$interval" ] && exit 0
fi

out="`$dir/claude-history-`$(date +%Y%m%d-%H%M%S).tar.gz"
cd "`$2" 2>/dev/null || exit 0
set -- projects
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
ls -1 "`$dir"/claude-history-*.tar.gz 2>/dev/null | sort | head -n -$backupKeep | xargs -r rm -f
"@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($backupShWin, $backupSh)

# Runs once per launch; backup.sh itself decides whether one is actually due.
function Invoke-Backup {
    Write-Host "Checking transcript backup..." -NoNewline
    $made = @(Invoke-Bash $backupShWsl $backupDirWsl $claudeConfigDirBash | Where-Object { $_ })
    Write-Host "`r                             `r" -NoNewline
    if ($made) {
        $f = Get-Item (Join-Path $backupDir (Split-Path $made[-1] -Leaf)) -ErrorAction SilentlyContinue
        if ($f) { Write-Host ("Backed up transcripts -> {0} ({1:N0} MB)" -f $f.Name, ($f.Length/1MB)) }
    }
}
# -----------------------------------------------------------------------------------

# A name is "real" only if set by the user (skip blanks, placeholders, slash-commands, bare ids)
function Get-RealName($meta, $id) {
    $n = $meta[$id].name
    if (-not $n) { return $null }
    if ($n -eq $id -or $n -match '^/' -or $n -match '^\s*$') { return $null }
    if ($meta[$id].nameSource -eq 'derived') { return $null }
    if ($meta[$id].jobId -and $n -eq $meta[$id].jobId) { return $null }
    return $n
}

# Human-readable age: minutes under an hour, hours under 2 days, days under 2 weeks, then weeks
function Format-Age($lastWrite) {
    $span = (Get-Date) - $lastWrite
    if ($span.TotalHours -lt 1)  { return "{0}m" -f [int]$span.TotalMinutes }
    if ($span.TotalHours -lt 48) { return "{0}h" -f [int]$span.TotalHours }
    if ($span.TotalDays  -lt 14) { return "{0}d" -f [int]$span.TotalDays }
    return "{0}w" -f [int]($span.TotalDays / 7)
}

# /cd moves a session permanently and records it as a relocated entry (last one wins);
# per-line cwds only follow the shell, so otherwise the first cwd is the session's.
$relocatedPattern = '^\{"type":"relocated".*"relocatedCwd":"([^"]+)"'

# Parsed-transcript cache: full read of every .jsonl over \\wsl$ costs ~10s,
# so keep {cwd,titles} per file and only re-parse when the mtime changes.
$cacheFile = Join-Path $env:TEMP 'recent-claude-cache-v7.json'
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
    return $candidate
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
        Write-Host "No hidden Claude conversations found."
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
    # sessionId -> {name, status} from sessions/*.json (live sessions: rename + status)
    $meta = @{}
    if (Test-Path $sessDir) {
        Get-ChildItem "$sessDir\*.json" -File | ForEach-Object {
            try {
                $s = Get-Content $_.FullName -Raw | ConvertFrom-Json
                if ($s.sessionId) { $meta[$s.sessionId] = @{ name = $s.name; status = $s.status; nameSource = $s.nameSource; jobId = $s.jobId } }
            } catch {}
        }
    }

    # Gather top-level sessions updated within 40 days (excluding subagent sidechains),
    # enumerated natively inside WSL by scan.sh: "epoch-mtime<TAB>linux-path" per line.
    $scanMode = if ($visibility -eq 'hidden') { 'all' } else { 'recent' }
    Invoke-Bash $scanShWsl $scanMode $claudeConfigDirBash |
        ForEach-Object {
            $epoch, $linuxPath = $_ -split "`t"
            $winPath   = ConvertFrom-WslPath $linuxPath
            $lastWrite = [DateTimeOffset]::FromUnixTimeSeconds([long][double]$epoch).LocalDateTime
            $id = [System.IO.Path]::GetFileNameWithoutExtension($linuxPath)
            $normalizedId = $id.ToLowerInvariant()
            $isHidden = $hiddenIds.ContainsKey($normalizedId)
            if (($visibility -eq 'hidden') -ne $isHidden) { return }
            if ($emittedIds.ContainsKey($normalizedId)) { return }
            $emittedIds[$normalizedId] = $true

            # One pass over the transcript: cwd + titles. Renames are stored in the
            # transcript itself as custom-title records (ai-title = auto title);
            # keep the LAST of each since a session can be renamed more than once.
            # Skipped entirely when the cached entry's mtime still matches.
            $mtime = $epoch
            $c = $cache[$winPath]
            if ($c -and "$($c.mtime)" -eq $mtime) {
                $cwd = $c.cwd; $fallback = $c.fallback; $continuedIn = $c.continuedIn
                $customTitle = $c.customTitle; $aiTitle = $c.aiTitle
            } else {
                $cwd = $null; $fallback = $null; $customTitle = $null; $aiTitle = $null; $continuedIn = $null
                $transitionSource = $null; $transitionTitle = $null
                foreach ($line in [SharedFile]::ReadLines($winPath)) {
                    if ($line -match $relocatedPattern) { $cwd = $Matches[1] }
                    elseif (-not $cwd -and $line -match '"cwd"\s*:\s*"([^"]+)"') { $cwd = $Matches[1] }
                    if ($line -match '"customTitle"\s*:\s*"((?:[^"\\]|\\.)+)"') { $customTitle = $Matches[1] }
                    elseif ($line -match '"aiTitle"\s*:\s*"((?:[^"\\]|\\.)+)"') { $aiTitle = $Matches[1] }
                    elseif ($line -match '^\{"type":"continued-in".*"continuedInSessionId":"([^"]+)"') { $continuedIn = $Matches[1] }
                    if (-not $fallback -and $line -match '"summary"\s*:\s*"([^"]+)"') { $fallback = $Matches[1] }
                    # Claude user content can be either a string or an array of text
                    # blocks. Parse JSON for the fallback instead of assuming a string.
                    if (-not $fallback -and $line -match '"type"\s*:\s*"user"') {
                        try {
                            $record = $line | ConvertFrom-Json
                            $content = $record.message.content
                            if ($content -is [string]) { $fallback = Get-TitleCandidate $content }
                            else {
                                $fallback = Get-TitleCandidate (@($content | Where-Object { $_.type -eq 'text' } |
                                    ForEach-Object { $_.text } | Where-Object { $_ }) -join ' ')
                            }
                        } catch {}
                    }
                    if (-not $transitionSource -and $line -match '\[Transitioned from (Codex|OpenCode); inherited title: (.*?)\]') {
                        $transitionSource = $Matches[1]; $transitionTitle = $Matches[2]
                    }
                }
                $cache[$winPath] = @{ mtime = $mtime; cwd = $cwd; fallback = $fallback; continuedIn = $continuedIn
                                      customTitle = $customTitle; aiTitle = $aiTitle
                                      transitionSource = $transitionSource; transitionTitle = $transitionTitle }
            }
            # Native Windows cwds arrive JSON-escaped (C:\\dir); WSL paths have no backslashes.
            $cwd = "$cwd" -replace '\\\\','\'
            # A backgrounded job can record a continuation that never writes a transcript.
            if (-not $cwd -or ($continuedIn -and (Test-Path (Join-Path (Split-Path $winPath) "$continuedIn.jsonl")))) { return }

            # Title priority: live rename (sessions/) > rename in transcript > auto title > deduced
            $title = Get-RealName $meta $id
            if (-not $title) { $title = $customTitle }
            if ($c -and "$($c.mtime)" -eq $mtime) {
                $transitionSource = $c.transitionSource; $transitionTitle = $c.transitionTitle
            }
            if (-not $title -and $transitionTitle) { $title = $transitionTitle }
            if (-not $title) { $title = $aiTitle }
            $title = Get-TitleCandidate $title
            $folder = (($cwd -replace '\\','/') -split '/' | Select-Object -Last 2) -join '/'
            if (-not $title) { $title = if ($fallback) { $fallback } else { "Untitled session in $folder" } }
            $title = $title -replace '\\"','"'
            $title = $title -replace '\\[nrt]',' ' -replace '\s+',' '
            $handoffTitle = $title
            if ($transitionSource) { $title = "From ${transitionSource}: $title" }
            if ($title.Length -gt 50) { $title = $title.Substring(0,50) }

            $age    = Format-Age $lastWrite
            $shortId = ($id -split '-')[-1]
            $status = $meta[$id].status
            $tag    = if ($status -and $status -ne 'idle') { "[$status] " } else { '' }

            # display <TAB> id <TAB> cwd <TAB> transcript (only col 1 is shown; --with-nth=1)
            "{0}{1} - {2} - {3} ago [..-{4}]`t{5}`t{6}`t{7}`t{8}" -f $tag, $folder, $title, $age, $shortId, $id, $cwd, $winPath, $handoffTitle
        }

    try { $cache | ConvertTo-Json -Depth 3 | Set-Content $cacheFile } catch {}
}

# Keep the picker alive on a cached list: opening a tab leaves the same sessions on
# screen (no rescan, no reshuffle). Esc reloads the whole script so code changes are picked up; close the
# window to quit. Scan up front, then restart the script when Esc asks for it.
# Synthetic first row: picking it (id __NEW__) triggers the folder picker below --
# with claude on enter/click, or a transfer target on its hotkey, same as the session rows.
$newTargets = @($(if ($codexEnabled) { 'alt-x: codex' }), $(if ($opencodeEnabled) { 'alt-o: opencode' })) -join ' | '
$newRow = if ($newTargets) { "+ New session (choose folder)...  [enter: claude | $newTargets]`t__NEW__`t`t" } else { "+ New session (choose folder)...  [enter: claude]`t__NEW__`t`t" }

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
    $title = if ($tool -eq 'claude') { $name } else { "${tool}: $name" }
    $command = if ($tool -eq 'claude') { New-HubClaudeCommand 'claude' $script:account } elseif ($tool -eq 'codex') { 'codex -c tui.fullscreen_transcript=false' } else { $tool }
    Open-WtTab $title $path $command $(if ($tool -eq 'claude') { $script:account.Color })
}

function Invoke-Handoff($tool, $id, $cwd, $transcript, $title) {
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
$claudeAccounts = @(Get-HubClaudeAccounts)
$newAccount = $false   # Alt-A went past the last account: the next Claude launch creates one

$sessions = Update-List
if (-not $sessions) { Write-Host "No past sessions found under $projects -- use the top row to start a new one." }

while ($true) {
    # Another picker window may have switched accounts; always launch in the saved one.
    $script:account = if (-not $newAccount) { Get-HubClaudeActiveAccount $claudeAccounts }
    Write-FzfScript
    # fzf (Linux, via WSL): list in via file, pick out via file, console untouched so
    # keyboard/mouse/resize all reach fzf. Wheel scrolls, a second click on the
    # highlighted row (or Enter) opens.
    Remove-Item $pickWin -ErrorAction SilentlyContinue
    Invoke-Bash $fzfShWsl $listWsl $pickWsl

    # --expect puts the pressed key on line 1 ('' for Enter/click, 'alt-c', 'alt-h', or 'alt-s') and
    # the picks after it. Read the lines raw -- a normal accept leaves line 1 BLANK, so
    # blanks can only be filtered out once the key has been taken off the front.
    $out    = @(if (Test-Path $pickWin) { Get-Content $pickWin })
    $key    = if ($out.Count) { $out[0].Trim() } else { '' }
    $picked = @($out | Select-Object -Skip 1 | Where-Object { $_ })
    if ($key -eq 'alt-a') {   # next account, then the new-account stop; history and open tabs are unaffected
        $claudeAccounts = @(Get-HubClaudeAccounts)   # pick up new folders and logins
        $index = if ($newAccount) { -1 } else { [array]::IndexOf(@($claudeAccounts.Name), $script:account.Name) }
        $newAccount = -not $newAccount -and $index -eq $claudeAccounts.Count - 1
        if (-not $newAccount) { Set-HubClaudeActiveAccount $claudeAccounts[$index + 1] }
        continue
    }
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
    # bash -lic loads the login profile so PATH includes claude.
    # For the keys that launch something, the pressed key chooses the tool once, here;
    # everything below just uses $tool.
    $tool = if ($key -eq 'alt-x') { 'codex' } elseif ($key -eq 'alt-o') { 'opencode' } else { 'claude' }
    if ($newAccount -and $tool -eq 'claude') {
        $known = @($claudeAccounts.Name)
        $claudeAccounts = @(Get-HubClaudeAccounts -New)
        $script:account = @($claudeAccounts | Where-Object { $_.Name -notin $known })[0]
        Set-HubClaudeActiveAccount $script:account
        $newAccount = $false
    }

    # Tab-marking 2+ real session rows means "combine", not "open each": merge their
    # transcripts into one handoff and seed a single new session (enter/transfer key). The __NEW__ row can't be combined, so drop it first.
    # A /cd since the scan moved the transcript into the new folder's project dir: find it again
    # and re-read its relocation so picks follow the move without an Esc reload.
    $items = @(foreach ($row in $picked) {
        $p = $row -split "`t"
        $item = [pscustomobject]@{ Id = $p[1]; Cwd = $p[2]; Tr = $p[3]; Title = $p[4] }
        if ($item.Id -ne '__NEW__') {
            if (-not (Test-Path -LiteralPath $item.Tr)) { $item.Tr = (Get-Item "$projects\*\$($item.Id).jsonl" | Select-Object -First 1).FullName }
            $relocated = Select-String -LiteralPath $item.Tr -Pattern $relocatedPattern | Select-Object -Last 1
            if ($relocated) { $item.Cwd = $relocated.Matches[0].Groups[1].Value -replace '\\\\','\' }
        }
        $item
    })
    $realItems = @($items | Where-Object { $_.Id -ne '__NEW__' })
    if ($realItems.Count -ge 2) {
        Invoke-CombineSession $realItems $tool
        continue
    }

    foreach ($it in $items) {
        if ($it.Id -eq '__NEW__') { Invoke-NewSession $tool; continue }   # top row: start fresh
        if ($tool -ne 'claude')   { Invoke-Handoff $tool $it.Id $it.Cwd $it.Tr $it.Title; continue }
        $tabTitle = if ($it.Title) { $it.Title } else { $it.Id }
        Open-WtTab $tabTitle $it.Cwd (New-HubClaudeCommand "claude --resume $($it.Id)" $script:account) $script:account.Color
    }
}
