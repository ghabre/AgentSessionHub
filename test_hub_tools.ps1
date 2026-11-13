$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hub-tools.ps1')
function Assert-True($condition, $message) { if (-not $condition) { throw $message } }
$root = Join-Path $PSScriptRoot ('.hub-check-' + $PID)
$oldLocalAppData = $env:LOCALAPPDATA
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    # Load an isolated copy so config and account tests cannot change real settings.
    Copy-Item (Join-Path $PSScriptRoot 'hub-tools.ps1') $root
    . (Join-Path $root 'hub-tools.ps1')
    $env:LOCALAPPDATA = $root
    $config = Join-Path $root 'agent-hub.config'
    Assert-True ((@(Get-HubRequestedTools) -join ',') -eq 'codex,claude,opencode' -and (Test-Path -LiteralPath $config)) 'First use did not create an all-on config.'
    [IO.File]::WriteAllText($config, "opencode=off`n")
    Assert-True ((@(Get-HubRequestedTools) -join ',') -eq 'codex,claude') 'Unlisted CLI was not on by default.'
    [IO.File]::WriteAllText($config, "codex=on`nclaude=off`nopencode=on`n")
    Assert-True ((@(Get-HubRequestedTools) -join ',') -eq 'codex,opencode') 'Disabled CLI was included.'
    [IO.File]::WriteAllText($config, "codex=off`nclaude=off`nopencode=off`n")
    Assert-True (@(Get-HubRequestedTools).Count -eq 0) 'All-off config was ignored.'
    [IO.File]::WriteAllText($config, "codex=maybe`nclaude=on`nopencode=on")
    $rejected = $false
    try { $null = @(Get-HubRequestedTools) } catch { $rejected = $true }
    Assert-True $rejected 'Invalid configuration was accepted.'
    $accounts = @(
        [pscustomobject]@{ Name = '.claude'; Email = 'first@example.com'; Uuid = '1'; Shared = $true; Dir = '/home/test/.claude' }
        [pscustomobject]@{ Name = '.claude-2'; Email = "second.o'brien@example.com"; Uuid = '2'; Shared = $false; Dir = '/home/test/.claude-2' }
        [pscustomobject]@{ Name = '.claude-3'; Email = ''; Uuid = ''; Shared = $false; Dir = '/home/test/.claude-3' }
    )
    foreach ($tool in @('codex', 'claude', 'opencode')) {
        $targets = @(Get-HubTransferTargets $tool @('codex', 'claude', 'opencode') $accounts $accounts[1])
        Assert-True ($targets[0].Label -like 'Open (*' -and $targets[0].Tool -eq $tool) "Wrong first row for $tool."
        $claude = @($targets | Where-Object { $_.Tool -eq 'claude' })
        Assert-True ($claude.Count -eq 2 -and $claude[0].Account.Name -eq '.claude-2') 'Logged-in Claude account rows/order failed.'
    }
    $targets = @(Get-HubTransferTargets 'codex' @('codex') @() $null)
    Assert-True ($targets.Count -eq 1) 'Disabled destinations were included.'
    $targets = @(Get-HubTransferTargets 'opencode' @('codex', 'opencode') @() $null)
    Assert-True ($targets[0].Tool -eq 'opencode' -and $targets[1].Tool -eq 'codex') 'Current tool did not come first.'
    $targets = @(Get-HubTransferTargets 'claude' @('claude') @($accounts[0]) $accounts[0])
    Assert-True ($targets.Count -eq 1 -and $targets[0].Label -eq 'Open (claude)') 'Single Claude login should have one tool row.'

    # Exercise the file boundary, account selection and cancellation without launching CLIs.
    function Get-HubClaudeAccounts { $accounts }
    function ConvertTo-WslPath($path) { $path }
    $tmpWin = $root
    $fzfPath = '/usr/bin/fzf'
    $clickBinds = ''
    $script:cancel = $false
    function Invoke-Bash($shellFile, $listFile, $pickFile) {
        $rows = @(Get-Content -LiteralPath $listFile)
        if (-not $script:cancel) {
            [IO.File]::WriteAllText($pickFile, ($rows | Where-Object { $_ -like "*second.o*" } | Select-Object -First 1))
        }
    }
    Set-HubClaudeActiveAccount $accounts[0]
    $selected = Select-HubTransferTarget 'claude' @('codex', 'claude', 'opencode')
    Assert-True ($selected.Tool -eq 'claude' -and $selected.Account.Name -eq '.claude-2') 'Account selection changed the destination tool.'
    Assert-True ((Get-HubClaudeActiveAccount $accounts).Name -eq '.claude-2') 'Selected account was not saved for launches/handoffs.'
    $script:cancel = $true
    Assert-True ($null -eq (Select-HubTransferTarget 'codex' @('codex', 'claude'))) 'Cancel reused a previous selection.'
    Assert-True ((Get-HubClaudeActiveAccount $accounts).Name -eq '.claude-2') 'Cancel changed the active account.'
    Write-Host 'Hub config, destination ordering, account selection and cancellation passed.'
} finally {
    $env:LOCALAPPDATA = $oldLocalAppData
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
