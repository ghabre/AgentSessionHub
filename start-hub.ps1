$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hub-tools.ps1')
$requested = if ($env:AGENT_HUB_TOOLS) { @($env:AGENT_HUB_TOOLS.ToLowerInvariant() -split ',' | ForEach-Object { $_.Trim() }) } else { @('codex', 'claude', 'opencode') }
$env:AGENT_HUB_AVAILABLE_TOOLS = $null
try { $available = @(Get-HubAvailableTools) } catch {
    # Launched from a shortcut, so keep the failure readable.
    Write-Host $_.Exception.Message
    [void](Read-Host 'Press Enter to close this launcher')
    exit 1
}
$env:AGENT_HUB_AVAILABLE_TOOLS = $available -join ','
$missing = @($requested | Where-Object { $_ -in @('codex', 'claude', 'opencode') -and $_ -notin $available })
$showReminder = Show-HubMissingTools $missing
$tabs = @()
foreach ($tool in @('codex', 'claude', 'opencode')) {
    if ($tool -notin $requested -or $tool -notin $available) { continue }
    if ($tabs.Count) { $tabs += ';' }
    $tabs += @('new-tab', '--title', $tool, 'powershell.exe', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot "recent-$tool.ps1"))
}
if ($tabs.Count) { & $args[0] -w $env:AGENT_SESSION_HUB_WINDOW @tabs }
if ($showReminder) {
    # Keep the weekly installation reminder visible when launched from a shortcut.
    Write-Host 'Press Enter to close this launcher.'
    [void](Read-Host)
}
