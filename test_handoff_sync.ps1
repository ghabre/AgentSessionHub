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
$oldWorkConfig = $env:CLAUDE_WORK_CONFIG_DIR
$oldClaudeConfig = $env:CLAUDE_CONFIG_DIR
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
    $homeWin = Join-Path $root 'home'
    $claudeWin = Join-Path $homeWin '.claude\projects'
    $codexWin = Join-Path $homeWin '.codex\sessions'
    New-Item -ItemType Directory $tmpWin, $claudeWin, $codexWin -Force | Out-Null
    $tmpWsl = ConvertTo-WslPath $tmpWin
    $bashHome = ConvertTo-WslPath $homeWin
    $opencodeDbWsl = "$bashHome/missing.db"
    $env:CLAUDE_WORK_CONFIG_DIR = Join-Path $homeWin "work O'Brien"
    [void][IO.Directory]::CreateDirectory($env:CLAUDE_WORK_CONFIG_DIR)
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

    # Profile copies preserve relative paths and bytes, and never overwrite either side.
    $claudeAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'recent-claude.ps1'), [ref]$null, [ref]$null)
    $copyFn = $claudeAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Copy-SessionToOtherProfile' }, $true)
    Invoke-Expression $copyFn.Extent.Text
    $projects = $claudeWin
    $otherProfile = 'work'
    $nestedSource = Join-Path $projects "project O'Brien\$claudeId.jsonl"
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($nestedSource))
    [IO.File]::WriteAllText($nestedSource, [IO.File]::ReadAllText($sourceFile))
    $before = [IO.File]::ReadAllText($nestedSource)
    $copyItem = [pscustomobject]@{ Id = $claudeId; Title = "Task O'Brien"; Cwd = $homeWin; Tr = $nestedSource }
    $beforeLaunches = $script:launches.Count
    Copy-SessionToOtherProfile $copyItem
    $copiedFile = Join-Path $claudeWorkConfigDir "projects\project O'Brien\$claudeId.jsonl"
    Assert-True ([IO.File]::ReadAllText($copiedFile) -ceq $before) 'Copy changed the transcript or relative project path.'
    Assert-True ([IO.File]::ReadAllText($nestedSource) -ceq $before) 'Copy changed the source.'
    [IO.File]::AppendAllText($copiedFile, 'destination-only')
    Copy-SessionToOtherProfile $copyItem
    Assert-True ($script:launches.Count -eq $beforeLaunches + 1) 'Existing destination was launched or overwritten.'
    Assert-True ([IO.File]::ReadAllText($copiedFile).EndsWith('destination-only')) 'Copy overwrote destination changes.'
    $otherProfile = 'personal'
    $projects = Join-Path $claudeWorkConfigDir 'projects'
    $returnSource = Join-Path $projects "return-project\$claudeId.jsonl"
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($returnSource))
    [IO.File]::WriteAllText($returnSource, $before)
    $copyItem.Tr = $returnSource
    Copy-SessionToOtherProfile $copyItem
    Assert-True ([IO.File]::ReadAllText((Join-Path $claudeWin "return-project\$claudeId.jsonl")) -ceq $before) 'Work-to-personal copy failed.'

    Assert-True ($claudeAst.ParamBlock.Parameters[0].Name.VariablePath.UserPath -eq 'Profile') 'Claude profile is not a bound script parameter.'
    # Run the generated scanners/backups against isolated profile dirs, including history.
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
    foreach ($profileName in @('personal', 'work')) {
        $configDir = if ($profileName -eq 'work') { $claudeWorkConfigDir } else { $claudePersonalConfigDir }
        $configBash = ConvertTo-WslPath $configDir
        [IO.File]::WriteAllText((Join-Path $configDir 'history.jsonl'), $profileName)
        $scanRows = @(& $gitBash (ConvertTo-WslPath $scanFile) all $configBash)
        Assert-True ($scanRows.Count -gt 0) "No $profileName transcripts scanned."
        foreach ($scanRow in $scanRows) { Assert-True (($scanRow -split "`t")[1].StartsWith("$configBash/projects/")) 'Scan crossed profile directories.' }
        $archiveDir = Join-Path $tmpWin "backups\$profileName"
        $archives = @(& $gitBash (ConvertTo-WslPath $backupFile) (ConvertTo-WslPath $archiveDir) $configBash)
        Assert-True ($archives.Count -eq 1) "No $profileName backup made."
        $archiveHistory = @(& $gitBash (ConvertTo-WslPath $archiveReader) $archives[0])
        Assert-True ($archiveHistory[0] -ceq $profileName) 'Backup included another profile history.'
        $repeatArchive = @(& $gitBash (ConvertTo-WslPath $backupFile) (ConvertTo-WslPath $archiveDir) $configBash)
        Assert-True ($repeatArchive.Count -eq 0) 'Backup throttle failed.'
    }

    # Execute the real tab builder with a terminal recorder and the isolated config dir.
    $hubScript = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'start-hub.ps1'))
    $hubBuilder = [scriptblock]::Create($hubScript.Substring($hubScript.IndexOf('$workAvailable =')).Replace('$PSScriptRoot', "'" + $PSScriptRoot.Replace("'", "''") + "'"))
    function Record-HubTabs { $script:tabArgs = @($args) }
    $available = @('claude')
    $requested = @('claude', 'claude-work')
    $showReminder = $false
    & $hubBuilder 'Record-HubTabs'
    Assert-True ('claude work' -in $script:tabArgs -and '--tabColor' -in $script:tabArgs -and '-Profile' -in $script:tabArgs -and 'work' -in $script:tabArgs) 'Hub omitted the work tab or profile argument.'
    Assert-True (@($script:tabArgs | Where-Object { $_ -eq (Join-Path $PSScriptRoot 'recent-claude.ps1') }).Count -eq 2) 'Hub did not reuse the Claude picker.'
    $env:CLAUDE_WORK_CONFIG_DIR = Join-Path $root 'missing-work'
    & $hubBuilder 'Record-HubTabs'
    Assert-True ('claude-work' -notin $script:tabArgs) 'Hub showed a nonexistent work config.'
    $env:CLAUDE_WORK_CONFIG_DIR = $claudeWorkConfigDir
    $requested = @('claude')
    & $hubBuilder 'Record-HubTabs'
    Assert-True ('-Profile' -notin $script:tabArgs) 'Personal-only hub behavior changed.'

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
        foreach ($targetTool in @('claude', 'claude-work', 'opencode')) {
            $configDir = if ($targetTool -eq 'claude-work') { $claudeWorkConfigDir } else { $claudePersonalConfigDir }
            $freshArgs = @(Invoke-Expression (New-BashCommand @($syncLaunchWsl, $targetTool, $first.handoff, '-', 'Claude', "Task O'Brien", $configDir)))
            $resumeArgs = @(Invoke-Expression (New-BashCommand @($syncLaunchWsl, $targetTool, '-', 'native-test', 'Claude', "Task O'Brien", $configDir)))
            $deltaArgs = @(Invoke-Expression (New-BashCommand @($syncLaunchWsl, $targetTool, $delta.handoff, 'native-test', 'Claude', "Task O'Brien", $configDir)))
            if ($targetTool -in @('claude', 'claude-work')) {
                Assert-True ($freshArgs[0] -ceq "CONFIG:$configDir" -and $resumeArgs[0] -ceq "CONFIG:$configDir" -and $deltaArgs[0] -ceq "CONFIG:$configDir") 'Bash handoff lost the selected Claude config directory.'
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
        foreach ($profileName in @('personal', 'work')) {
            $expectedDir = if ($profileName -eq 'work') { $claudeWorkConfigDir } else { $claudePersonalConfigDir }
            $profileArgs = @(Invoke-Expression (New-HubClaudeCommand "claude --resume $claudeId" $profileName))
            Assert-True ($profileArgs.Count -eq 3 -and $profileArgs[0] -ceq "CONFIG:$expectedDir" -and $profileArgs[2] -eq $claudeId) 'Native Claude profile or resume arguments were damaged.'
        }
        # Both picker sources must launch fresh handoffs in the selected profile.
        foreach ($sourceTool in @('codex', 'opencode')) {
            foreach ($targetTool in @('claude', 'claude-work')) {
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
                Assert-True ($script:launches.Count -eq $launchCount + 1) "$sourceTool to $targetTool did not launch."
                $profileArgs = @(Invoke-Expression $script:launches[-1])
                $expectedDir = if ($targetTool -eq 'claude-work') { $claudeWorkConfigDir } else { $claudePersonalConfigDir }
                Assert-True ($profileArgs[0] -ceq "CONFIG:$expectedDir") 'Native handoff selected the wrong Claude profile.'
            }
        }
        # The WSL command quoting runs through Bash using a CLI stub and no credentials.
        $shellFile = Join-Path $tmpWin 'profile-quote.sh'
        $shellFileBash = ConvertTo-WslPath $shellFile
        $backend = 'wsl'
        foreach ($profileName in @('personal', 'work')) {
            $expectedDir = if ($profileName -eq 'work') { $claudeWorkConfigDir } else { $claudePersonalConfigDir }
            $command = New-HubClaudeCommand "claude --resume $claudeId" $profileName
            $shellTest = "#!/bin/bash`nclaude() { printf '%s\n' `"CONFIG:`$CLAUDE_CONFIG_DIR`" `"`$@`"; }`n$command`n"
            [IO.File]::WriteAllText($shellFile, $shellTest.Replace("`r`n", "`n"))
            $profileArgs = @(& $gitBash $shellFileBash)
            Assert-True ($profileArgs.Count -eq 3 -and $profileArgs[0] -ceq "CONFIG:$expectedDir" -and $profileArgs[2] -eq $claudeId) 'Bash profile quoting was damaged.'
        }
        $backend = 'windows'

    } finally { $env:PATH = $oldPath }
    Write-Output 'Windows integration passed: first transfer, automatic resume, delta, spaces/apostrophes, native launch arguments for all three tools, profile isolation/copies, scans/backups, hub tabs, Claude profile quoting.'
} finally {
    $env:CLAUDE_WORK_CONFIG_DIR = $oldWorkConfig
    $env:CLAUDE_CONFIG_DIR = $oldClaudeConfig
    if (Test-Path $root) { Remove-Item $root -Recurse -Force }
}
