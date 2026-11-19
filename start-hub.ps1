$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hub-tools.ps1')
$env:AGENT_HUB_AVAILABLE_TOOLS = $null
try {
    $requested = @(Get-HubRequestedTools)
    $available = @(Get-HubAvailableTools)
} catch {
    # Launched from a shortcut, so keep the failure readable.
    Write-Host $_.Exception.Message
    [void](Read-Host 'Press Enter to close this launcher')
    exit 1
}
$env:AGENT_HUB_AVAILABLE_TOOLS = $available -join ','
$missing = @($requested | Where-Object { $_ -notin $available })
$showReminder = Show-HubMissingTools $missing
$tabs = @()
if (@($requested | Where-Object { $_ -in $available })) {
    # The board reads the session stores, so it runs in the backend that holds them.
    $board = if ($env:AGENT_HUB_BACKEND -eq 'windows') { @('python', (Join-Path $PSScriptRoot 'hub_board.py')) } else {
        @('wsl.exe') + @(if ($env:WSL_DISTRO) { '-d', $env:WSL_DISTRO }) + @(if ($env:WSL_USER) { '-u', $env:WSL_USER }) +
            @('--cd', $PSScriptRoot, '--', 'python3', 'hub_board.py')
    }
    $tabs = @('new-tab', '--title', 'history', 'powershell.exe', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'recent-history.ps1'),
              ';', 'new-tab', '--title', 'active') + $board
    & $args[0] -w $env:AGENT_SESSION_HUB_WINDOW @tabs
}
if (-not $tabs.Count) { Write-Host 'No enabled CLIs are available. Check agent-hub.config and CLI installation.' }
if ($showReminder) {
    # Keep the weekly installation reminder visible when launched from a shortcut.
    Write-Host 'Press Enter to close this launcher.'
    [void](Read-Host)
}
