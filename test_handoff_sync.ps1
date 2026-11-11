# Windows boundary check: real Git Bash/Python and isolated native transcripts; no agent CLI runs.
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot ('.sync-check-' + $PID)
$gitBash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
if (-not (Test-Path $gitBash)) {
    $gitExe = Get-Command git.exe -ErrorAction Stop
    $gitBash = Join-Path (Split-Path (Split-Path $gitExe.Source)) 'bin\bash.exe'
}
if (-not (Test-Path $gitBash)) { throw 'Git for Windows is required for this integration check.' }
$backend = 'windows'
. (Join-Path $PSScriptRoot 'hub-tools.ps1')
$oldClaudeConfig = $env:CLAUDE_CONFIG_DIR
$oldLocalAppData = $env:LOCALAPPDATA
$availableTools = @('codex', 'claude', 'opencode')
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'recent-codex.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('ConvertTo-WslPath', 'ConvertFrom-WslPath', 'New-BashCommand')) {
    $fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    Invoke-Expression $fn.Extent.Text
}
function Invoke-Bash { & $gitBash @args }
$script:launches = @()
function Open-WtTab($title, $cwd, $command) { $script:launches += $command }
function Assert-True($condition, $message) { if (-not $condition) { throw $message } }
try {
    $tmpWin = Join-Path $root "temp O'Brien with spaces"
    $hubStateDir = Join-Path $root 'state'
    # The active-account file lives under LOCALAPPDATA; never touch the real one.
    $env:LOCALAPPDATA = Join-Path $root 'localappdata'
    $homeWin = Join-Path $root 'home'
    $claudeWin = Join-Path $homeWin '.claude\projects'
    $codexWin = Join-Path $homeWin '.codex\sessions'
    New-Item -ItemType Directory $tmpWin, $claudeWin, $codexWin -Force | Out-Null
    $tmpWsl = ConvertTo-WslPath $tmpWin
    $bashHome = ConvertTo-WslPath $homeWin
    $opencodeDbWsl = "$bashHome/missing.db"
    $devWin = Join-Path $homeWin ".claude-dev O'Brien"
    New-Item -ItemType Directory $devWin, (Join-Path $homeWin ".claude-work O'Brien") | Out-Null
    [IO.File]::WriteAllText((Join-Path $devWin '.claude.json'), '{ "oauthAccount": { "emailAddress": "dev@example.com" } }')
    Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
    $hubTool = 'claude'
    . (Join-Path $PSScriptRoot 'handoff-sync.ps1')
    $engineCopy = Join-Path $tmpWin 'handoff_sync.py'
    Copy-Item (Join-Path $PSScriptRoot 'handoff_sync.py') $engineCopy
    $syncEngineWsl = ConvertTo-WslPath $engineCopy
    $claudeId = '22222222-2222-2222-2222-222222222222'
    $codexId = '11111111-1111-1111-1111-111111111111'
    $sourceFile = Join-Path $claudeWin "$claudeId.jsonl"
    $row = @{ type = 'user'; cwd = $homeWin; message = @{ content = 'Original task' } }
    [System.IO.File]::WriteAllText($sourceFile, ($row | ConvertTo-Json -Compress -Depth 5) + "`n")
    $items = @([pscustomobject]@{ Id = $claudeId; Title = "Task O'Brien"; Cwd = $homeWin })
    Invoke-HubTransfer 'codex' $items $homeWin
    Assert-True ($script:launches.Count -eq 1) 'First transfer did not launch.'
    $first = Get-Content (Join-Path $tmpWin 'sync-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($first.count -eq 1 -and $first.handoff) 'First transfer did not include the original message.'
    $rows = @(
        @{ type = 'session_meta'; payload = @{ id = $codexId; cwd = $homeWin } },
        @{ type = 'response_item'; payload = @{ type = 'message'; role = 'user'; content = @(@{type = 'input_text'; text = "Read $($first.handoff) -- continue"}) } }
    )
    $destinationFile = Join-Path $codexWin "rollout-$codexId.jsonl"
    [System.IO.File]::WriteAllText($destinationFile, (($rows | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 8 }) -join "`n") + "`n")
    Invoke-HubTransfer 'codex' $items $homeWin
    $repeat = Get-Content (Join-Path $tmpWin 'sync-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($script:launches.Count -eq 2 -and -not $repeat.handoff -and $repeat.target.id -eq $codexId) 'Repeat transfer did not resume without a payload.'
    $extra = @{ type = 'assistant'; payload = $null; cwd = $homeWin; message = @{ content = 'Source update' } }
    [System.IO.File]::AppendAllText($sourceFile, ($extra | ConvertTo-Json -Compress -Depth 5) + "`n")
    Invoke-HubTransfer 'codex' $items $homeWin
    $delta = Get-Content (Join-Path $tmpWin 'sync-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($delta.count -eq 1 -and $delta.target.id -eq $codexId) 'Incremental transfer did not select the original destination.'
    $body = Get-Content $delta.handoff -Raw -Encoding UTF8
    Assert-True ($body.Contains('Source update') -and -not $body.Contains('Original task')) 'Incremental payload duplicated source history.'

    # Accounts are ~/.claude plus every ~/.claude-* folder; a new one is numbered and listed last.
    $accounts = @(Get-HubClaudeAccounts)
    Assert-True (($accounts.Name -join ',') -eq ".claude,.claude-dev O'Brien,.claude-work O'Brien") 'Account folders were not discovered.'
    Assert-True ($accounts[0].Shared -and -not $accounts[1].Shared -and $accounts[1].Dir -eq $devWin) 'Account directories are wrong.'
    Assert-True ($accounts[1].Email -eq 'dev@example.com' -and -not $accounts[2].Email) 'Login emails were not read.'
    Assert-True (@($accounts.Color | Select-Object -Unique).Count -eq 3) 'Accounts share a tab color.'
    # The active account is saved state; a missing or vanished account falls back to the first.
    Assert-True ((Get-HubClaudeActiveAccount).Shared) 'Default account is not the first.'
    Set-HubClaudeActiveAccount $accounts[2]
    Assert-True ((Get-HubClaudeActiveAccount).Name -eq $accounts[2].Name) 'Active account was not saved.'
    Assert-True ((Get-HubClaudeActiveAccount @($accounts[0..1])).Shared) 'Vanished account was still active.'
    $accounts = @(Get-HubClaudeAccounts -New)
    Assert-True ($accounts.Count -eq 4 -and $accounts[3].Name -eq '.claude-2' -and $accounts[2].Name -eq ".claude-work O'Brien") 'New account was not appended.'

    $claudeAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'recent-claude.ps1'), [ref]$null, [ref]$null)
    # Run the generated scanner/backup against the shared history, including prompt history.
    $backupEvery = 24
    $backupKeep = 10
    foreach ($variable in @('scanSh', 'backupSh')) {
        $assignment = $claudeAst.Find({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq ('$' + $variable) }, $true)
        Invoke-Expression $assignment.Extent.Text
    }
    $scanFile = Join-Path $tmpWin 'profile-scan.sh'
    $backupFile = Join-Path $tmpWin 'profile-backup.sh'
    [IO.File]::WriteAllText($scanFile, $scanSh)
    [IO.File]::WriteAllText($backupFile, $backupSh)
    $archiveReader = Join-Path $tmpWin 'read-history.sh'
    [IO.File]::WriteAllText($archiveReader, 'tar -xOzf "$1" history.jsonl' + "`n")
    $configBash = "$bashHome/.claude"
    [IO.File]::WriteAllText((Join-Path $homeWin '.claude\history.jsonl'), 'shared')
    $scanRows = @(& $gitBash (ConvertTo-WslPath $scanFile) all $configBash)
    Assert-True ($scanRows.Count -gt 0) 'No transcripts scanned.'
    foreach ($scanRow in $scanRows) { Assert-True (($scanRow -split "`t")[1].StartsWith("$configBash/projects/")) 'Scan left the shared history.' }
    $archiveDir = Join-Path $tmpWin 'backups\claude'
    $archives = @(& $gitBash (ConvertTo-WslPath $backupFile) (ConvertTo-WslPath $archiveDir) $configBash)
    Assert-True ($archives.Count -eq 1) 'No backup made.'
    $archiveHistory = @(& $gitBash (ConvertTo-WslPath $archiveReader) $archives[0])
    Assert-True ($archiveHistory[0] -ceq 'shared') 'Backup missed the prompt history.'
    $repeatArchive = @(& $gitBash (ConvertTo-WslPath $backupFile) (ConvertTo-WslPath $archiveDir) $configBash)
    Assert-True ($repeatArchive.Count -eq 0) 'Backup throttle failed.'

    # Execute the real tab builder with a terminal recorder: one Claude tab, no profiles.
    $hubScript = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'start-hub.ps1'))
    $hubBuilder = [scriptblock]::Create($hubScript.Substring($hubScript.IndexOf('$tabs = @()')).Replace('$PSScriptRoot', "'" + $PSScriptRoot.Replace("'", "''") + "'"))
    function Record-HubTabs { $script:tabArgs = @($args) }
    $available = @('claude')
    $requested = @('claude')
    $showReminder = $false
    & $hubBuilder 'Record-HubTabs'
    Assert-True ('-Profile' -notin $script:tabArgs -and @($script:tabArgs | Where-Object { $_ -eq (Join-Path $PSScriptRoot 'recent-claude.ps1') }).Count -eq 1) 'Hub did not open exactly one Claude picker.'

    # Exercise the generated command through native PowerShell and Git Bash, replacing
    # only the target executable with an argument recorder, never starting Codex.
    $binWin = Join-Path $root 'bin'
    New-Item -ItemType Directory $binWin | Out-Null
    foreach ($targetTool in @('codex', 'claude', 'opencode')) {
        $configOutput = if ($targetTool -eq 'claude') { '"CONFIG:$CLAUDE_CONFIG_DIR" ' } else { '' }
        [System.IO.File]::WriteAllText((Join-Path $binWin $targetTool), "#!/bin/bash`nprintf '%s\n' $configOutput`"`$@`"`n")
    }
    $oldPath = $env:PATH
    try {
        $env:PATH = "$binWin;$oldPath"
        # Native handoffs resolve profile-defined commands directly in PowerShell.
        function codex { $args }
        $nativeFreshArgs = @(Invoke-Expression $script:launches[0])
        Assert-True ($nativeFreshArgs.Count -eq 3 -and $nativeFreshArgs[2].Contains((ConvertFrom-WslPath $first.handoff))) 'Native fresh launch arguments were damaged.'
        $freshCommand = New-BashCommand @($syncLaunchWsl, 'codex', $first.handoff, '-', 'Claude', "Task O'Brien")
        $freshArgs = @(Invoke-Expression $freshCommand)
        Assert-True ($freshArgs.Count -eq 3 -and $freshArgs[0] -eq '-c' -and $freshArgs[2].Contains($first.handoff)) 'Fresh launch arguments were damaged.'
        $resumeArgs = @(Invoke-Expression $script:launches[1])
        Assert-True ($resumeArgs.Count -eq 4 -and $resumeArgs[2] -eq 'resume' -and $resumeArgs[3] -eq $codexId) 'Plain resume injected a prompt or shifted arguments.'
        $deltaArgs = @(Invoke-Expression $script:launches[2])
        Assert-True ($deltaArgs.Count -eq 5 -and $deltaArgs[3] -eq $codexId -and $deltaArgs[4].Contains($delta.handoff)) 'Resumed launch arguments were damaged.'
        # '-' is the first account: the launcher must unset CLAUDE_CONFIG_DIR, not pass it through.
        foreach ($case in @(@('claude', '-', ''), @('claude', $accounts[2].Dir, $accounts[2].Dir), @('opencode', '-', ''))) {
            $targetTool, $configDir, $expectedConfig = $case
            $freshArgs = @(Invoke-Expression (New-BashCommand @($syncLaunchWsl, $targetTool, $first.handoff, '-', 'Claude', "Task O'Brien", $configDir)))
            $resumeArgs = @(Invoke-Expression (New-BashCommand @($syncLaunchWsl, $targetTool, '-', 'native-test', 'Claude', "Task O'Brien", $configDir)))
            $deltaArgs = @(Invoke-Expression (New-BashCommand @($syncLaunchWsl, $targetTool, $delta.handoff, 'native-test', 'Claude', "Task O'Brien", $configDir)))
            if ($targetTool -eq 'claude') {
                Assert-True ($freshArgs[0] -ceq "CONFIG:$expectedConfig" -and $resumeArgs[0] -ceq "CONFIG:$expectedConfig" -and $deltaArgs[0] -ceq "CONFIG:$expectedConfig") 'Bash handoff lost the selected Claude config directory.'
                Assert-True ($freshArgs.Count -eq 2 -and $freshArgs[1].Contains($first.handoff)) 'Fresh Claude launch arguments were damaged.'
                Assert-True ($resumeArgs.Count -eq 3 -and $resumeArgs[2] -eq 'native-test') 'Plain Claude resume injected a prompt.'
                Assert-True ($deltaArgs.Count -eq 4 -and $deltaArgs[3].Contains($delta.handoff)) 'Claude delta arguments were damaged.'
            } else {
                Assert-True ($freshArgs.Count -eq 2 -and $freshArgs[0] -eq '--prompt') 'Fresh OpenCode launch arguments were damaged.'
                Assert-True ($resumeArgs.Count -eq 2 -and $resumeArgs[1] -eq 'native-test') 'Plain OpenCode resume injected a prompt.'
                Assert-True ($deltaArgs.Count -eq 4 -and $deltaArgs[3].Contains($delta.handoff)) 'OpenCode delta arguments were damaged.'
            }
        }

        function claude { "CONFIG:$env:CLAUDE_CONFIG_DIR"; $args }
        $env:CLAUDE_CONFIG_DIR = 'leaked from the login shell'
        foreach ($account in $accounts) {
            $expectedDir = if ($account.Shared) { '' } else { $account.Dir }
            $profileArgs = @(Invoke-Expression (New-HubClaudeCommand "claude --resume $claudeId" $account))
            Assert-True ($profileArgs.Count -eq 3 -and $profileArgs[0] -ceq "CONFIG:$expectedDir" -and $profileArgs[2] -eq $claudeId) 'Native Claude profile or resume arguments were damaged.'
        }
        # Both picker sources must launch fresh handoffs in the selected profile.
        foreach ($sourceTool in @('codex', 'opencode')) {
            # Accounts share one Claude destination, so a second pending OpenCode transfer
            # would rightly wait for the first; Codex is already synchronized and resumes.
            foreach ($activeAccount in $(if ($sourceTool -eq 'codex') { $accounts } else { @($accounts[1]) })) {
                $targetTool = 'claude'
                Set-HubClaudeActiveAccount $activeAccount
                $hubTool = $sourceTool
                $id = if ($sourceTool -eq 'codex') { $codexId } else { 'ses_profile' }
                $opencodeDbWsl = "$bashHome/override.db"
                if ($sourceTool -eq 'opencode') {
                    $dbScript = Join-Path $tmpWin 'fixture.py'
                    $fixture = @'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute('CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT, title TEXT, time_updated INTEGER, parent_id TEXT, time_archived INTEGER)')
    db.execute('CREATE TABLE session_message (session_id TEXT, type TEXT, data TEXT, seq INTEGER PRIMARY KEY AUTOINCREMENT)')
    db.execute('INSERT INTO session_v2 VALUES (?, ?, ?, 1000, NULL, NULL)', ('ses_profile', sys.argv[2], 'Task'))
    db.execute('INSERT INTO session_message (session_id, type, data) VALUES (?, ?, ?)', ('ses_profile', 'user', '{"text":"OpenCode task"}'))
'@
                    if (-not (Test-Path (Join-Path $homeWin 'override.db'))) {
                        [IO.File]::WriteAllText($dbScript, $fixture.Replace("`r`n", "`n"))
                        Invoke-Bash $syncRunnerWsl (ConvertTo-WslPath $dbScript) (ConvertTo-WslPath (Join-Path $homeWin 'override.db')) $bashHome
                    }
                }
                $profileItems = @([pscustomobject]@{ Id = $id; Title = "Profile O'Brien"; Cwd = $homeWin })
                $launchCount = $script:launches.Count
                Invoke-HubTransfer $targetTool $profileItems $homeWin
                Assert-True ($script:launches.Count -eq $launchCount + 1) "$sourceTool to $($activeAccount.Name) did not launch."
                $profileArgs = @(Invoke-Expression $script:launches[-1])
                $expectedDir = if ($activeAccount.Shared) { '' } else { $activeAccount.Dir }
                Assert-True ($profileArgs[0] -ceq "CONFIG:$expectedDir") 'Native handoff ignored the active Claude account.'
            }
        }
        # The WSL command quoting runs through Bash using a CLI stub and no credentials.
        $shellFile = Join-Path $tmpWin 'profile-quote.sh'
        $shellFileBash = ConvertTo-WslPath $shellFile
        $backend = 'wsl'
        foreach ($account in $accounts) {
            $expectedDir = if ($account.Shared) { '' } else { $account.Dir }
            $command = 'export CLAUDE_CONFIG_DIR=leaked; ' + (New-HubClaudeCommand "claude --resume $claudeId" $account)
            $shellTest = "#!/bin/bash`nclaude() { printf '%s\n' `"CONFIG:`$CLAUDE_CONFIG_DIR`" `"`$@`"; }`n$command`n"
            [IO.File]::WriteAllText($shellFile, $shellTest.Replace("`r`n", "`n"))
            $profileArgs = @(& $gitBash $shellFileBash)
            Assert-True ($profileArgs.Count -eq 3 -and $profileArgs[0] -ceq "CONFIG:$expectedDir" -and $profileArgs[2] -eq $claudeId) 'Bash profile quoting was damaged.'
        }
        $backend = 'windows'

    } finally { $env:PATH = $oldPath }
    Write-Output 'Windows integration passed: first transfer, automatic resume, delta, spaces/apostrophes, native launch arguments for all three tools, active account, shared scans/backups, hub tabs, Claude account quoting.'
} finally {
    $env:CLAUDE_CONFIG_DIR = $oldClaudeConfig
    $env:LOCALAPPDATA = $oldLocalAppData
    if (Test-Path $root) { Remove-Item $root -Recurse -Force }
}
