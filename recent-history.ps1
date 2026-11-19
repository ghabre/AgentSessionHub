# recent-history.ps1
#
# One list of conversations across Codex, Claude Code and OpenCode, newest first. Sessions
# joined by a transfer or a continuation are one row, shown under the agent that used it
# last (handoff_sync.py list); "<- codex" names the agents it came through. Enter resumes
# the row in its own agent, Alt-T opens it with another one through the shared transfer
# planner, and Tab marks several rows to combine. The first row starts a new session.
#
# Picking takes two clicks: the first left-click on a row only highlights it, a second
# click on that same row opens it. Esc reloads this script in-place; close the window to quit.
#
# Backend, requirements and overrides are those of the per-agent pickers (recent-claude.ps1);
# hidden conversations and the active Claude account are shared with them. Backups are still
# taken by the per-agent pickers.

param([switch]$Run)
# The outer invocation is only this loop. Esc makes the picker exit with 75 and it is rerun in a
# fresh scope of the same process, so reloads neither stack processes nor read stale variables.
if (-not $Run) { do { & $PSCommandPath -Run @args } while ($LASTEXITCODE -eq 75); exit $LASTEXITCODE }

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$backend = if ($env:AGENT_HUB_BACKEND) { $env:AGENT_HUB_BACKEND.ToLowerInvariant() } else { 'wsl' }
if ($backend -notin @('wsl', 'windows')) { throw "AGENT_HUB_BACKEND must be 'wsl' or 'windows', not '$backend'" }

. (Join-Path $PSScriptRoot 'hub-tools.ps1')
$availableTools = @(Get-HubAvailableTools)

$enabledTools = @(Get-HubRequestedTools | Where-Object { $_ -in $availableTools })

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
$tmpWin  = Join-Path $env:TEMP ("recent-history-{0}" -f $PID)
New-Item -ItemType Directory -Path $tmpWin -Force | Out-Null
# Nothing runs when a tab is closed, so each launch removes the folders of pickers that are gone.
Get-ChildItem $env:TEMP -Directory | Where-Object { $_.Name -match '^recent-history-(\d+)$' -and -not (Get-Process -Id $Matches[1] -ErrorAction SilentlyContinue) } |
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
$hubStateDir = Join-Path $env:LOCALAPPDATA 'AgentSessionHub'

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

# The row's own tool is the source of a transfer, so it is set per pick.
$hubTool = $null
. (Join-Path $PSScriptRoot 'handoff-sync.ps1')
$stores = @{ codex = "$bashHome/.codex/sessions"; claude = "$bashHome/.claude/projects"; opencode = $opencodeDbWsl }
$scope = if ($backend -eq 'wsl') { "wsl-$distro" } else { 'windows' }
$stateName = "sync-" + ($scope -replace '[^A-Za-z0-9._-]', '_')

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
$clickStateWsl = "/tmp/recent-history-$PID-click.state"
$clickBinds = (@"
    --bind "focus:transform:echo {n} > $clickStateWsl" \
    --bind "left-click:transform:if [ \"\`$(cat $clickStateWsl 2>/dev/null)\" = \"{n}\" ]; then echo accept; fi" \
"@ -replace "`r`n","`n")

# preview.sh: the highlighted row's last turns, read from its own tool's store.
$previewShWin = Join-Path $tmpWin 'preview.sh'; $previewShWsl = "$tmpWsl/preview.sh"
$quotedStores = @{}
foreach ($name in $stores.Keys) { $quotedStores[$name] = $stores[$name].Replace("'", "'\''") }
$previewSh = @"
#!/bin/bash
# `$1 = tool, `$2 = session id
case "`$1" in
    codex) store='$($quotedStores.codex)' ;;
    claude) store='$($quotedStores.claude)' ;;
    *) store='$($quotedStores.opencode)' ;;
esac
exec bash '$($syncRunnerWsl.Replace("'", "'\''"))' '$($syncEngineWsl.Replace("'", "'\''"))' preview "`$1" "`$store" "`$2"
"@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($previewShWin, $previewSh)

# --expect makes fzf print the pressed key as the FIRST line of the pick file (an empty
# first line for a plain Enter/click accept), so one picker can mean several things.
$expectKeys = 'alt-t,alt-a,alt-h,alt-s'
# Rewritten before every pick so the prompt names the active Claude account, in its tab color.
# No $script:account means the new-account stop, or that Claude is not enabled.
function Write-FzfScript {
    $label = if ('claude' -notin $enabledTools) { '' }
             elseif (-not $script:account) { ' [claude: NEW account]' }
             elseif ($script:account.Email) { " [claude: $($script:account.Email -replace "'", '')]" }   # the prompt is single-quoted
             else { " [claude: $($script:account.Name.TrimStart('.')) (not logged in)]" }
    $color = if ($script:account) { $script:account.Color } else { '#9A9A9A' }
    $headerActions = @('enter: open', 'tab: mark', 'alt-t: open with', 'alt-a: next claude account', 'alt-h: hide', 'alt-s: show', 'alt-p: preview', 'esc: reload') -join ' | '
    $fzfSh = @"
#!/bin/bash
# `$1 = list file (CRLF from PowerShell -- strip CRs), `$2 = pick output file
tr -d '\r' < "`$1" | "$fzfPath" \
    --ansi --with-nth=1 --delimiter=`$'\t' \
    --multi \
    --expect=$expectKeys \
$clickBinds
    --preview 'bash "$($previewShWsl.Replace("'", "'\''"))" {4} {2}' \
    --preview-window 'right,45%,wrap,follow,hidden' --bind 'alt-p:toggle-preview' \
    --prompt='history$label> ' --color='prompt:$color' --reverse \
    --header='$headerActions' \
    > "`$2"
"@ -replace "`r`n","`n"
    [System.IO.File]::WriteAllText($fzfShWin, $fzfSh)
}

$showSh = @"
#!/bin/bash
tr -d '\r' < "`$1" | "$fzfPath" \
    --ansi --with-nth=1 --delimiter=`$'\t' \
    --multi \
$clickBinds
    --prompt='hidden conversations> ' --reverse \
    --header='enter: show | tab: mark multiple | esc: cancel' \
    > "`$2"
"@ -replace "`r`n","`n"
[System.IO.File]::WriteAllText($showShWin, $showSh)

# --- New-session support -----------------------------------------------------------
# Root that the folder picker lists (immediate subfolders become new-session choices).
# Its first row can also create an initialized local Git project under this root.
$newRoot    = if ($env:AGENT_HUB_NEW_ROOT) { $env:AGENT_HUB_NEW_ROOT } else { 'C:\G\code' }
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

# Hidden conversations are the per-agent pickers' lists, one id per line for each tool.
function Get-HiddenFile($tool) { Join-Path $hubStateDir "hidden-$tool-session-ids.txt" }
function Get-HiddenKeys {
    foreach ($tool in 'codex', 'claude', 'opencode') {
        $file = Get-HiddenFile $tool
        if (Test-Path $file) { Get-Content $file | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { "${tool}:$_" } }
    }
}

# Rows from handoff_sync.py list: display, id, cwd, tool, title, has-native-name, member keys.
function Get-Conversations($visibility = 'visible') {
    $ownerLabels = @{}
    if ($claudeAccounts.Count -gt 1) { $claudeAccounts | Where-Object { $_.Uuid } | ForEach-Object { $ownerLabels[$_.Uuid] = ($_.Email -split '@')[0] } }
    $request = @{
        scope = $stateName
        legacy_state_dir = ConvertTo-WslPath (Join-Path $hubStateDir $stateName)
        codex_root = $stores.codex; claude_root = $stores.claude; opencode_db = $stores.opencode
        tools = @($enabledTools); days = $hubDays
        hidden = @(Get-HiddenKeys); hidden_only = ($visibility -eq 'hidden')
        owner_labels = $ownerLabels
    }
    $requestWin = Join-Path $tmpWin 'list-request.json'
    $rowsWin = Join-Path $tmpWin 'list-rows.tsv'
    [System.IO.File]::WriteAllText($requestWin, ($request | ConvertTo-Json -Depth 4))
    Remove-Item $rowsWin -ErrorAction SilentlyContinue
    Invoke-Bash $syncRunnerWsl $syncEngineWsl list (ConvertTo-WslPath $requestWin) (ConvertTo-WslPath $rowsWin) | Out-Host
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $rowsWin)) { throw 'Could not list conversations.' }
    @(Get-Content $rowsWin -Encoding UTF8 | Where-Object { $_ })
}

function Hide-Conversations($rows) {
    $hidden = @(Get-HiddenKeys)
    New-Item -ItemType Directory -Path $hubStateDir -Force | Out-Null
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    foreach ($key in @($rows | ForEach-Object { ($_ -split "`t")[6] -split ',' } | Where-Object { $_ -and $_ -notin $hidden } | Select-Object -Unique)) {
        $tool, $id = $key -split ':', 2
        [System.IO.File]::AppendAllText((Get-HiddenFile $tool), "$id`n", $utf8NoBom)
    }
}

function Show-HiddenConversations {
    $rows = @(Get-Conversations 'hidden')
    if (-not $rows) {
        Write-Host "No hidden conversations found."
        Start-Sleep -Milliseconds 900
        return
    }
    [System.IO.File]::WriteAllLines($showListWin, [string[]]$rows)
    Remove-Item $showPickWin -ErrorAction SilentlyContinue
    Invoke-Bash $showShWsl $showListWsl $showPickWsl
    $picked = @(if (Test-Path $showPickWin) { Get-Content $showPickWin -Encoding UTF8 | Where-Object { $_ } })
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    foreach ($group in @($picked | ForEach-Object { $p = $_ -split "`t"; [pscustomobject]@{ Tool = $p[3]; Id = $p[1] } } | Group-Object Tool)) {
        $file = Get-HiddenFile $group.Name
        $remaining = @(Get-Content $file | Where-Object { $_.Trim() -and $_.Trim() -notin @($group.Group.Id) })
        [System.IO.File]::WriteAllLines($file, [string[]]$remaining, $utf8NoBom)
    }
}

# Keep the picker alive on a cached list: opening a tab leaves the same rows on screen (no
# rescan, no reshuffle). Esc reloads the whole script so code changes are picked up.
# Synthetic first row: picking it (id __NEW__) asks for the agent, then the folder.
$newRow = "+ New session (choose agent and folder)...`t__NEW__`t`t`t`t`t"

function Restart-Script {
    Write-Host "Reloading script..."
    # Re-detect CLIs so a tool installed since the hub launched appears.
    $env:AGENT_HUB_AVAILABLE_TOOLS = $null
    exit 75   # the loop at the top of this script reruns it
}
function Update-List {
    Write-Host "Reading conversations..." -NoNewline
    $rows = @(Get-Conversations)
    Write-Host "`r                           `r" -NoNewline
    [System.IO.File]::WriteAllLines($listWin, [string[]](@($newRow) + $rows))
    return $rows
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

if (-not $enabledTools) { Write-Host 'No enabled CLIs are available. Check agent-hub.config and CLI installation.'; [void](Read-Host 'Press Enter to close'); exit 1 }
$claudeAccounts = @(if ('claude' -in $enabledTools) { Get-HubClaudeAccounts })
$newAccount = $false   # Alt-A went past the last account: the next Claude launch creates one

$conversations = Update-List
if (-not $conversations) { Write-Host "No conversations in the last $hubDays days -- use the top row to start one." }

while ($true) {
    # Another picker window may have switched accounts; always launch in the saved one.
    $script:account = if ($claudeAccounts -and -not $newAccount) { Get-HubClaudeActiveAccount $claudeAccounts }
    Write-FzfScript
    Remove-Item $pickWin -ErrorAction SilentlyContinue
    Invoke-Bash $fzfShWsl $listWsl $pickWsl

    # --expect puts the pressed key on line 1 ('' for Enter/click) and the picks after it.
    # Read the lines raw -- a normal accept leaves line 1 BLANK, so blanks can only be
    # filtered out once the key has been taken off the front.
    $out    = @(if (Test-Path $pickWin) { Get-Content $pickWin -Encoding UTF8 })
    $key    = if ($out.Count) { $out[0].Trim() } else { '' }
    $picked = @($out | Select-Object -Skip 1 | Where-Object { $_ })
    if ($key -eq 'alt-a') {   # next account, then the new-account stop; history and open tabs are unaffected
        if (-not $claudeAccounts) { continue }
        $claudeAccounts = @(Get-HubClaudeAccounts)   # pick up new folders and logins
        $index = if ($newAccount) { -1 } else { [array]::IndexOf(@($claudeAccounts.Name), $script:account.Name) }
        $newAccount = -not $newAccount -and $index -eq $claudeAccounts.Count - 1
        if (-not $newAccount) { Set-HubClaudeActiveAccount $claudeAccounts[$index + 1] }
        continue
    }
    if ($key -eq 'alt-s') {
        Show-HiddenConversations
        $conversations = Update-List
        continue
    }
    # Esc (or no match) -> empty pick: reload the full script so edits are picked up.
    if (-not $picked) { Restart-Script }

    if ($key -eq 'alt-h') {
        Hide-Conversations $picked
        $conversations = Update-List
        continue
    }

    $items = @(foreach ($row in $picked) {
        $p = $row -split "`t"
        [pscustomobject]@{ Id = $p[1]; Cwd = $p[2]; Tool = $p[3]; Title = $p[4] }
    })
    $realItems = @($items | Where-Object { $_.Id -ne '__NEW__' })

    # Enter keeps each row in its own agent. Alt-T asks for one, and so does the new-session row for itself.
    $target = $null
    if ($key -eq 'alt-t' -or $items.Count -ne $realItems.Count) {
        $current = if ($realItems) { $realItems[0].Tool } else { $enabledTools[0] }
        $target = Select-HubTransferTarget $current $enabledTools
        if (-not $target) { continue }
        if ($target.Account) {
            $script:account = $target.Account
            $newAccount = $false
        }
    }
    $moveTo = if ($key -eq 'alt-t') { $target.Tool }
    $usesClaude = ($target -and $target.Tool -eq 'claude') -or (-not $moveTo -and 'claude' -in @($realItems.Tool))
    if ($newAccount -and $usesClaude) {
        $known = @($claudeAccounts.Name)
        $claudeAccounts = @(Get-HubClaudeAccounts -New)
        $script:account = @($claudeAccounts | Where-Object { $_.Name -notin $known })[0]
        Set-HubClaudeActiveAccount $script:account
        $newAccount = $false
    }

    # Tab-marking 2+ rows means "combine", not "open each": merge them into one handoff
    # and seed or update a single session, in the first row's agent unless Alt-T chose one.
    if ($realItems.Count -ge 2) {
        $hubTool = $realItems[0].Tool
        Invoke-HubTransfer $(if ($moveTo) { $moveTo } else { $hubTool }) $realItems $realItems[0].Cwd
        continue
    }

    foreach ($it in $items) {
        if ($it.Id -eq '__NEW__') { Invoke-NewSession $target.Tool; continue }
        $tool = if ($moveTo) { $moveTo } else { $it.Tool }
        if ($tool -ne $it.Tool) {
            $hubTool = $it.Tool
            Invoke-HubTransfer $tool @($it) $it.Cwd
            continue
        }
        $tabTitle = if ($it.Title) { $it.Title } else { $it.Id }
        $tabTitle = $tabTitle -replace '[\r\n\]"]', ' '   # '"' would break native argument passing to wt.exe
        switch ($tool) {
            'claude'   { Open-WtTab $tabTitle $it.Cwd (New-HubClaudeCommand "claude --resume $($it.Id)" $script:account) $script:account.Color }
            'codex'    { Open-WtTab "codex: $tabTitle" $it.Cwd "codex -c tui.fullscreen_transcript=false resume $($it.Id)" }
            'opencode' { Open-WtTab "opencode: $tabTitle" $it.Cwd "opencode --session $($it.Id)" }
        }
    }
}
