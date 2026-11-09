# Shared CLI discovery. Native tools must be resolved after the PowerShell profile
# initializes version managers; Git Bash's PATH can differ from that environment.
# start-hub publishes the result in AGENT_HUB_AVAILABLE_TOOLS, which Windows Terminal
# passes to the picker tabs, so only standalone pickers probe themselves.
function Get-HubAvailableTools {
    if ($null -ne $env:AGENT_HUB_AVAILABLE_TOOLS) { return @($env:AGENT_HUB_AVAILABLE_TOOLS -split ',' | Where-Object { $_ }) }
    if ($env:AGENT_HUB_BACKEND -eq 'windows') {
        $shell = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
        $probe = "'codex','claude','opencode' | ForEach-Object { if (Get-Command `$_ -ErrorAction SilentlyContinue) { Write-Output ('HUB_TOOL:' + `$_) } }; 'HUB_PROBE_OK'"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
        $output = @(& $shell -NoLogo -NonInteractive -EncodedCommand $encoded)
    } else {
        $wslArgs = @()
        if ($env:WSL_DISTRO) { $wslArgs += @('-d', $env:WSL_DISTRO) }
        $output = @(& wsl.exe @wslArgs --exec bash -lic 'for tool in codex claude opencode; do command -v "$tool" >/dev/null 2>&1 && echo HUB_TOOL:$tool; done; echo HUB_PROBE_OK')
    }
    # Without the marker the probe itself broke; failing beats hiding every tool.
    if ('HUB_PROBE_OK' -notin @($output | ForEach-Object { "$_".Trim() })) { throw "CLI probe failed in the $(Get-HubScope) backend; output: $($output -join ' | ')" }
    @($output | ForEach-Object { if ("$_" -match '^HUB_TOOL:(codex|claude|opencode)$') { $Matches[1] } })
}

function Get-HubScope {
    if ($env:AGENT_HUB_BACKEND -eq 'windows') { 'windows' } elseif ($env:WSL_DISTRO) { "wsl-$env:WSL_DISTRO" } else { 'wsl' }
}

function Show-HubMissingTools([string[]]$tools) {
    $shown = $false
    $stateDir = Join-Path $env:LOCALAPPDATA 'AgentSessionHub'
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $scope = (Get-HubScope) -replace '[^A-Za-z0-9._-]', '_'
    foreach ($tool in $tools) {
        $stamp = Join-Path $stateDir "missing-$scope-$tool.txt"
        if ((Test-Path $stamp) -and (Get-Item $stamp).LastWriteTimeUtc -gt [DateTime]::UtcNow.AddDays(-7)) { continue }
        Write-Host "$tool is unavailable in the $scope backend. Install it there and make it available in the login shell to show its tab and handoff actions."
        $shown = $true
        [IO.File]::WriteAllText($stamp, [DateTime]::UtcNow.ToString('o'))
    }
    return $shown
}
