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
    # Exercise the generated command through native PowerShell and Git Bash, replacing
    # only the target executable with an argument recorder, never starting Codex.
    $binWin = Join-Path $root 'bin'
    New-Item -ItemType Directory $binWin | Out-Null
    foreach ($targetTool in @('codex', 'claude', 'opencode')) {
        [System.IO.File]::WriteAllText((Join-Path $binWin $targetTool), "#!/bin/bash`nprintf '%s\n' `"`$@`"`n")
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
        foreach ($targetTool in @('claude', 'opencode')) {
            $freshArgs = @(Invoke-Expression (New-BashCommand @($syncLaunchWsl, $targetTool, $first.handoff, '-', 'Claude', "Task O'Brien")))
            $resumeArgs = @(Invoke-Expression (New-BashCommand @($syncLaunchWsl, $targetTool, '-', 'native-test', 'Claude', "Task O'Brien")))
            $deltaArgs = @(Invoke-Expression (New-BashCommand @($syncLaunchWsl, $targetTool, $delta.handoff, 'native-test', 'Claude', "Task O'Brien")))
            if ($targetTool -eq 'claude') {
                Assert-True ($freshArgs.Count -eq 1 -and $freshArgs[0].Contains($first.handoff)) 'Fresh Claude launch arguments were damaged.'
                Assert-True ($resumeArgs.Count -eq 2 -and $resumeArgs[1] -eq 'native-test') 'Plain Claude resume injected a prompt.'
                Assert-True ($deltaArgs.Count -eq 3 -and $deltaArgs[2].Contains($delta.handoff)) 'Claude delta arguments were damaged.'
            } else {
                Assert-True ($freshArgs.Count -eq 2 -and $freshArgs[0] -eq '--prompt') 'Fresh OpenCode launch arguments were damaged.'
                Assert-True ($resumeArgs.Count -eq 2 -and $resumeArgs[1] -eq 'native-test') 'Plain OpenCode resume injected a prompt.'
                Assert-True ($deltaArgs.Count -eq 4 -and $deltaArgs[3].Contains($delta.handoff)) 'OpenCode delta arguments were damaged.'
            }
        }
    } finally { $env:PATH = $oldPath }
    Write-Output 'Windows integration passed: first transfer, automatic resume, delta, spaces/apostrophes, native launch arguments for all three tools.'
} finally {
    if (Test-Path $root) { Remove-Item $root -Recurse -Force }
}
