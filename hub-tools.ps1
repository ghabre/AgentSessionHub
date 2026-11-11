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

# One row per Claude login (account), in Alt-A cycle order. personal is the stock login
# (~/.claude plus ~/.claude.json) and owns the one shared session history. Every other
# account keeps only its login in CLAUDE_<NAME>_CONFIG_DIR (default ~/.claude-<name>) and
# links everything else to ~/.claude (link-claude-accounts.sh), so any account can resume
# any session. An account is offered once its folder exists. Tool is only a tab identity.
function Get-HubClaudeProfiles {
    [ordered]@{
        personal = [pscustomobject]@{ Name = 'personal'; Tool = 'claude';      Label = 'CP'; Color = '#D97757' }
        work     = [pscustomobject]@{ Name = 'work';     Tool = 'claude-work'; Label = 'CW'; Color = '#2F81F7' }
        dev      = [pscustomobject]@{ Name = 'dev';      Tool = 'claude-dev';  Label = 'CD'; Color = '#3FB950' }
    }
}

# 'claude-work' -> 'work'; $null for codex/opencode.
function Get-HubClaudeProfileOfTool($tool) {
    foreach ($p in (Get-HubClaudeProfiles).Values) { if ($p.Tool -eq $tool) { return $p.Name } }
}

# Per-profile env override: CLAUDE_<suffix> for personal, CLAUDE_<NAME>_<suffix> otherwise.
function Get-HubClaudeProfileEnv($profile, $suffix) {
    $name = if ($profile -eq 'personal') { "CLAUDE_$suffix" } else { "CLAUDE_$($profile.ToUpperInvariant())_$suffix" }
    [Environment]::GetEnvironmentVariable($name)
}

# Returns a backend-native config path; WSL overrides may come from its login shell.
function Get-HubClaudeConfigDir([ValidateSet('personal', 'work', 'dev')]$profile = 'personal') {
    $dirName = if ($profile -eq 'personal') { '.claude' } else { ".claude-$profile" }
    # Personal never takes an override: CLAUDE_CONFIG_DIR is what we export to select a profile.
    $override = if ($profile -ne 'personal') { Get-HubClaudeProfileEnv $profile 'CONFIG_DIR' }
    if ($override) { return $override }
    $nativeWindows = $env:AGENT_HUB_BACKEND -eq 'windows' -or $backend -eq 'windows'
    if ($nativeWindows) {
        $profileHome = if ($bashHome) { ConvertFrom-WslPath $bashHome } else { $HOME }
        return Join-Path $profileHome $dirName
    }
    if ($profile -eq 'personal' -and $bashHome) { return "$bashHome/.claude" }
    # One login-shell probe per process covers every profile's override and the home dir.
    if (-not $script:hubClaudeProbe) {
        $wslArgs = @()
        if ($env:WSL_DISTRO) { $wslArgs += @('-d', $env:WSL_DISTRO) }
        $lines = @((Get-HubClaudeProfiles).Keys | Where-Object { $_ -ne 'personal' } | ForEach-Object {
            $upper = $_.ToUpperInvariant()
            "`"HUB_CONFIG_${upper}:`${CLAUDE_${upper}_CONFIG_DIR-}`""
        })
        # Encode the probe: Windows PowerShell native marshalling strips embedded shell quotes.
        $probe = 'printf "%s\n" ' + ($lines -join ' ') + ' "HUB_HOME:/home/${WSL_USER:-$(id -un)}"'
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($probe))
        $output = @(& wsl.exe @wslArgs --exec bash -lic "eval `$(echo $encoded | base64 -d)")
        if ($LASTEXITCODE -ne 0) { throw "Could not resolve Claude $profile config directory." }
        $script:hubClaudeProbe = $output
    }
    $prefix = "HUB_CONFIG_$($profile.ToUpperInvariant()):"
    $config = @($script:hubClaudeProbe | Where-Object { "$_".StartsWith($prefix) })
    $homeLine = @($script:hubClaudeProbe | Where-Object { "$_".StartsWith('HUB_HOME:') })
    if (-not $homeLine.Count) { throw 'Claude config directory probe returned no home directory.' }
    if ($config.Count -and "$($config[-1])".Substring($prefix.Length)) { return "$($config[-1])".Substring($prefix.Length) }
    $profileHome = if ($bashHome) { $bashHome } elseif ($env:WSL_USER) { "/home/$env:WSL_USER" } else { "$($homeLine[-1])".Substring(9) }
    return "$profileHome/$dirName"
}

# Every Claude account runs the same CLI, so label (CP/CW/CD) and color their tabs. Claude
# Code may replace the tab title with its own, but Windows Terminal keeps the tab color.
function Get-HubTabLabel($tool) {
    $profile = Get-HubClaudeProfileOfTool $tool
    if ($profile) { (Get-HubClaudeProfiles)[$profile].Label } else { $tool }
}

function Get-HubTabColorArgs($tool) {
    $profile = Get-HubClaudeProfileOfTool $tool
    if (-not $profile) { return @() }
    $color = Get-HubClaudeProfileEnv $profile 'TAB_COLOR'
    @('--tabColor', $(if ($color) { $color } else { (Get-HubClaudeProfiles)[$profile].Color }))
}

# personal is always offered; the others need their config directory to exist.
function Test-HubClaudeProfile($profile) {
    if ($profile -eq 'personal') { return $true }
    $configDir = Get-HubClaudeConfigDir $profile
    if ($env:AGENT_HUB_BACKEND -eq 'windows' -or $backend -eq 'windows') { return Test-Path -LiteralPath $configDir -PathType Container }
    $wslArgs = @()
    if ($env:WSL_DISTRO) { $wslArgs += @('-d', $env:WSL_DISTRO) }
    # Quote the Linux path for bash, including apostrophes, before crossing wsl.exe.
    $quoted = "'" + $configDir.Replace("'", "'\''") + "'"
    & wsl.exe @wslArgs --exec bash -c "test -d $quoted"
    return $LASTEXITCODE -eq 0
}

function Get-HubClaudeAccounts {
    @((Get-HubClaudeProfiles).Values | Where-Object { Test-HubClaudeProfile $_.Name })
}

# The active account is shared by every picker: Alt-A in the Claude picker sets it, and
# every Claude launch or handoff uses it. A missing or vanished account falls back to personal.
function Get-HubClaudeAccountFile { Join-Path (Join-Path $env:LOCALAPPDATA 'AgentSessionHub') 'claude-account.txt' }

# $known (account names) skips re-probing account folders when the caller has the list.
function Get-HubClaudeActiveAccount([string[]]$known) {
    $file = Get-HubClaudeAccountFile
    $name = if (Test-Path -LiteralPath $file) { "$(Get-Content -LiteralPath $file -Raw)".Trim() }
    if (-not $name -or -not (Get-HubClaudeProfiles).Contains($name)) { return 'personal' }
    $exists = if ($PSBoundParameters.ContainsKey('known')) { $name -in $known } else { Test-HubClaudeProfile $name }
    if ($exists) { $name } else { 'personal' }
}

function Set-HubClaudeActiveAccount($name) {
    $file = Get-HubClaudeAccountFile
    [void][IO.Directory]::CreateDirectory((Split-Path $file))
    [IO.File]::WriteAllText($file, $name)
}
