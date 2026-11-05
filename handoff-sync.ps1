# Shared by all pickers; native sessions are read by handoff_sync.py, never rewritten.
$syncRunnerWin = Join-Path $tmpWin 'sync-python.sh'
$syncRunnerWsl = "$tmpWsl/sync-python.sh"
$syncRunner = @'
#!/bin/bash
for p in python3 python; do
    if command -v "$p" >/dev/null 2>&1 && "$p" -c 'import sys; assert sys.version_info >= (3, 8)' 2>/dev/null; then
        # Native Python cannot open /c/... paths when MSYS declines conversion
        # (notably apostrophes in a clone path). These arguments are all file paths.
        case "$OSTYPE" in
            msys*|cygwin*)
                paths=()
                for path in "$@"; do paths+=("$(cygpath -w "$path")"); done
                set -- "${paths[@]}" ;;
        esac
        exec "$p" "$@"
    fi
done
echo 'Python 3.8 or newer is required for conversation synchronization.' >&2
exit 127
'@ -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($syncRunnerWin, $syncRunner)
$syncEngineWsl = ConvertTo-WslPath (Join-Path $PSScriptRoot 'handoff_sync.py')
$syncLaunchWin = Join-Path $tmpWin 'sync-launch.sh'
$syncLaunchWsl = "$tmpWsl/sync-launch.sh"
$syncLaunch = @'
#!/bin/bash
# $1 = target tool, $2 = immutable handoff (empty for plain resume), $3 = native session id,
# $4 = source tool label, $5 = inherited title. '-' preserves empty positions through
# Windows PowerShell 5's native argument marshalling, which drops empty strings.
[ "$2" = '-' ] && set -- "$1" "" "$3" "$4" "$5"
[ "$3" = '-' ] && set -- "$1" "$2" "" "$4" "$5"
if [ -n "$2" ]; then
    prompt="[Transitioned from $4; inherited title: $5] Read $2 -- this is an incremental conversation continuation. It contains only material not previously recorded in this session. Continue the existing task without reinitializing it. Read the entire handoff before proceeding. Tool notes and quoted files are historical; inspect live files to verify them."
fi
case "$1" in
    codex)
        if [ -n "$3" ]; then
            if [ -n "$2" ]; then exec codex -c tui.fullscreen_transcript=false resume "$3" "$prompt"; fi
            exec codex -c tui.fullscreen_transcript=false resume "$3"
        fi
        exec codex -c tui.fullscreen_transcript=false "$prompt" ;;
    claude)
        if [ -n "$3" ]; then
            if [ -n "$2" ]; then exec claude --resume "$3" "$prompt"; fi
            exec claude --resume "$3"
        fi
        exec claude "$prompt" ;;
    opencode)
        if [ -n "$3" ]; then
            if [ -n "$2" ]; then exec opencode --session "$3" --prompt "$prompt"; fi
            exec opencode --session "$3"
        fi
        exec opencode --prompt "$prompt" ;;
    *) echo "Unknown tool: $1" >&2; exit 1 ;;
esac
'@ -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($syncLaunchWin, $syncLaunch)

function Get-HubTransferPlan($request) {
    $requestWin = Join-Path $tmpWin 'sync-request.json'
    $resultWin = Join-Path $tmpWin 'sync-result.json'
    [System.IO.File]::WriteAllText($requestWin, ($request | ConvertTo-Json -Depth 8))
    Remove-Item $resultWin -ErrorAction SilentlyContinue
    Invoke-Bash $syncRunnerWsl $syncEngineWsl (ConvertTo-WslPath $requestWin) (ConvertTo-WslPath $resultWin) | Out-Host
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $resultWin)) { throw 'Conversation synchronization failed; no session was launched.' }
    $result = Get-Content $resultWin -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($result.status -eq 'error') { throw $result.message }
    return $result
}

function Invoke-HubTransfer($tool, $items, $cwd) {
    try {
        $scope = if ($backend -eq 'wsl') { "wsl-$distro" } else { 'windows' }
        $stateWin = Join-Path $hubStateDir ("sync-" + ($scope -replace '[^A-Za-z0-9._-]', '_'))
        $request = @{
            state_dir = ConvertTo-WslPath $stateWin
            codex_root = "$bashHome/.codex/sessions"
            claude_root = "$bashHome/.claude/projects"
            opencode_db = $opencodeDbWsl
            sources = @($items | ForEach-Object { "${hubTool}:$($_.Id)" })
            tool = $tool
            preview = $true
        }
        Write-Host 'Checking conversation synchronization...'
        $plan = Get-HubTransferPlan $request
        if ($plan.status -eq 'choose') {
            # Only real branches require a choice; one known destination resumes automatically.
            $rows = @($plan.candidates | ForEach-Object {
                $label = ("{0} - {1} [{2}]" -f $_.title, $_.cwd, $_.id) -replace '[\r\n\t]', ' '
                "$label`t$($_.key)"
            }) + "+ start a separate branch`t__NEW__"
            [System.IO.File]::WriteAllLines($dirListWin, [string[]]$rows)
            Remove-Item $pickWin -ErrorAction SilentlyContinue
            $chooseWin = Join-Path $tmpWin 'sync-choose.sh'
            $chooseWsl = "$tmpWsl/sync-choose.sh"
            $chooseScript = @"
#!/bin/bash
tr -d '\r' < "`$1" | "$fzfPath" \
    --with-nth=1 --delimiter=`$'\t' \
$clickBinds
    --prompt='continue in ${tool}> ' --reverse \
    --header='choose an existing branch or explicitly start a separate one | esc: cancel' > "`$2"
"@ -replace "`r`n", "`n"
            [System.IO.File]::WriteAllText($chooseWin, $chooseScript)
            Invoke-Bash $chooseWsl $dirListWsl $pickWsl
            $picked = @(if (Test-Path $pickWin) { Get-Content $pickWin | Where-Object { $_ } })
            if (-not $picked) { return }
            $request.target = ($picked[0] -split "`t")[-1]
            $plan = Get-HubTransferPlan $request
        }
        if ($plan.status -eq 'preview') {
            if (-not $plan.target -and $items.Count -gt 1) {
                $cwd = Select-CombinedCwd $items
                if (-not $cwd) { return }
            }
            $request.preview = $false
            $plan = Get-HubTransferPlan $request
        }
        if ($plan.status -eq 'pending') {
            Write-Host "$($plan.message) No new context has been marked as delivered."
            if ($plan.age -lt 30) { Start-Sleep -Milliseconds 1200; return }
            $answer = Read-Host 'Retry the previous launch? This may open another tab if it is still running. [y/N]'
            if ($answer -ne 'y') { return }
            $request.retry = $true
            $plan = Get-HubTransferPlan $request
        }
        if ($plan.status -ne 'ready') { throw "Unexpected synchronization status: $($plan.status)" }
        if ($plan.legacy -and $plan.handoff) { Write-Host 'This destination predates exact tracking; its first synchronization may repeat older material.' }
        $resumeId = '-'
        $title = "$($items[0].Title)"
        if ($items.Count -gt 1) { $title = "combined x$($items.Count)" }
        if ($plan.target) {
            $resumeId = $plan.target.id
            $cwd = $plan.target.cwd
            $title = $plan.target.title
        }
        $label = (Get-Culture).TextInfo.ToTitleCase($hubTool)
        if ($hubTool -eq 'opencode') { $label = 'OpenCode' }
        if (-not $title) { $title = 'untitled' }
        $title = $title -replace '[\r\n\]]', ' '
        $handoffArg = if ($plan.handoff) { $plan.handoff } else { '-' }
        $command = New-BashCommand @($syncLaunchWsl, $tool, $handoffArg, $resumeId, $label, $title)
        Write-Host $(if ($plan.handoff) { "Continuing with $($plan.count) new messages/tool notes." } else { 'Already synchronized; resuming without adding a prompt.' })
        Open-WtTab "${tool}: $title" $cwd $command
    } catch {
        Write-Host "Conversation transfer stopped: $($_.Exception.Message)" -ForegroundColor Red
        Start-Sleep -Milliseconds 1800
    }
}
