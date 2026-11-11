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

# Returns a backend-native config path; WSL overrides may come from its login shell.
function Get-HubClaudeConfigDir([ValidateSet('personal', 'work')]$profile = 'personal') {
    $nativeWindows = $env:AGENT_HUB_BACKEND -eq 'windows' -or $backend -eq 'windows'
    if ($nativeWindows) {
        $profileHome = if ($bashHome) { ConvertFrom-WslPath $bashHome } else { $HOME }
        if ($profile -eq 'work' -and $env:CLAUDE_WORK_CONFIG_DIR) { return $env:CLAUDE_WORK_CONFIG_DIR }
        return Join-Path $profileHome $(if ($profile -eq 'work') { '.claude-work' } else { '.claude' })
    }
    if ($profile -eq 'work' -and $env:CLAUDE_WORK_CONFIG_DIR) { return $env:CLAUDE_WORK_CONFIG_DIR }
    if ($profile -eq 'personal' -and $bashHome) { return "$bashHome/.claude" }
    $wslArgs = @()
    if ($env:WSL_DISTRO) { $wslArgs += @('-d', $env:WSL_DISTRO) }
    # Encode the probe: Windows PowerShell native marshalling strips embedded shell quotes.
    $probe = 'printf "%s\n" "HUB_CONFIG:${CLAUDE_WORK_CONFIG_DIR-}" "HUB_HOME:/home/${WSL_USER:-$(id -un)}"'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($probe))
    $output = @(& wsl.exe @wslArgs --exec bash -lic "eval `$(echo $encoded | base64 -d)")
    if ($LASTEXITCODE -ne 0) { throw "Could not resolve Claude $profile config directory." }
    $config = @($output | Where-Object { "$_".StartsWith('HUB_CONFIG:') })
    $homeLine = @($output | Where-Object { "$_".StartsWith('HUB_HOME:') })
    if (-not $homeLine.Count) { throw 'Claude config directory probe returned no home directory.' }
    if ($profile -eq 'work' -and $config.Count -and "$($config[-1])".Substring(11)) { return "$($config[-1])".Substring(11) }
    $profileHome = if ($bashHome) { $bashHome } elseif ($env:WSL_USER) { "/home/$env:WSL_USER" } else { "$($homeLine[-1])".Substring(9) }
    return "$profileHome/" + $(if ($profile -eq 'work') { '.claude-work' } else { '.claude' })
}

# Both Claude profiles run the same CLI, so label and color their tabs. Claude Code may
# replace the tab title with its own, but Windows Terminal keeps the tab color.
function Get-HubTabLabel($tool) {
    switch ($tool) { 'claude' { 'claude personal' } 'claude-work' { 'claude work' } default { $tool } }
}

function Get-HubTabColorArgs($tool) {
    $color = switch ($tool) {
        'claude' { if ($env:CLAUDE_TAB_COLOR) { $env:CLAUDE_TAB_COLOR } else { '#D97757' } }
        'claude-work' { if ($env:CLAUDE_WORK_TAB_COLOR) { $env:CLAUDE_WORK_TAB_COLOR } else { '#2F81F7' } }
    }
    if ($color) { @('--tabColor', $color) } else { @() }
}

function Test-HubClaudeWork {
    $configDir = Get-HubClaudeConfigDir 'work'
    if ($env:AGENT_HUB_BACKEND -eq 'windows' -or $backend -eq 'windows') { return Test-Path -LiteralPath $configDir -PathType Container }
    $wslArgs = @()
    if ($env:WSL_DISTRO) { $wslArgs += @('-d', $env:WSL_DISTRO) }
    # Quote the Linux path for bash, including apostrophes, before crossing wsl.exe.
    $quoted = "'" + $configDir.Replace("'", "'\''") + "'"
    & wsl.exe @wslArgs --exec bash -c "test -d $quoted"
    return $LASTEXITCODE -eq 0
}
