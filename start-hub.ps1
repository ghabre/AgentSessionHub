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
$missing = @($requested | Where-Object { $_ -in @('codex', 'claude', 'opencode') -and $_ -notin $available })
$showReminder = Show-HubMissingTools $missing
$tabs = @()
# One Claude tab: accounts share its history and are switched inside it with Alt-A.
foreach ($tool in @('codex', 'claude', 'opencode')) {
    if ($tool -notin $requested -or $tool -notin $available) { continue }
    if ($tabs.Count) { $tabs += ';' }
    $tabs += @('new-tab', '--title', $tool, 'powershell.exe', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot "recent-$tool.ps1"))
}
if ($tabs.Count) { & $args[0] -w $env:AGENT_SESSION_HUB_WINDOW @tabs }
if (-not $tabs.Count) { Write-Host 'No enabled CLIs are available. Check agent-hub.config and CLI installation.' }
if ($showReminder) {
    # Keep the weekly installation reminder visible when launched from a shortcut.
    Write-Host 'Press Enter to close this launcher.'
    [void](Read-Host)
}
