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

# Claude accounts are logins sharing one session history: ~/.claude first, then every
# ~/.claude-* folder (claude-accounts.sh lists them, links each to ~/.claude and, with -New,
# creates the next numbered one). Needs the picker's Invoke-Bash, path converters and $bashHome.
# Dir is the backend-native CLAUDE_CONFIG_DIR; Email and Uuid are empty until the account logs in.
function Get-HubClaudeAccounts([switch]$New) {
    $bashArgs = @((ConvertTo-WslPath (Join-Path $PSScriptRoot 'claude-accounts.sh')), "$bashHome/.claude") + @(if ($New) { 'new' })
    $accounts = @()
    foreach ($line in @(Invoke-Bash @bashArgs)) {
        $kind, $value = "$line" -split ':', 2
        switch ($kind) {
            'ACCOUNT' {
                $dir, $email, $uuid = $value -split "`t"
                $accounts += [pscustomobject]@{
                    Name = ($dir -split '/')[-1]; Dir = $(if ($backend -eq 'windows') { ConvertFrom-WslPath $dir } else { $dir })
                    Email = $email; Uuid = $uuid; Shared = -not $accounts.Count; Color = Get-HubClaudeAccountColor $accounts.Count
                }
            }
            'SET_ASIDE'   { Write-Host "Kept aside (now shared from ~/.claude): $value" -ForegroundColor Yellow }
            'LIVE'        { Write-Host "Not linked yet, it has running Claude sessions: $value -- close them, then press Esc." -ForegroundColor Yellow }
            'LINK_FAILED' { Write-Host "Could not link $value$(if ($backend -eq 'windows') { ' -- enable Windows Developer Mode for symlinks' })" -ForegroundColor Red }
        }
    }
    $accounts
}

# Tab and prompt color by account position; Claude Code may retitle a tab but its color stays.
function Get-HubClaudeAccountColor($index) {
    $colors = '#D97757', '#3FB950', '#2F81F7', '#A371F7', '#D29922', '#DB61A2'
    $colors[$index % $colors.Count]
}

# The active account is shared by every picker: Alt-A in the Claude picker sets it, and
# every Claude launch or handoff uses it. A missing or vanished account falls back to the first.
function Get-HubClaudeAccountFile { Join-Path (Join-Path $env:LOCALAPPDATA 'AgentSessionHub') 'claude-account.txt' }

function Get-HubClaudeActiveAccount($accounts = @(Get-HubClaudeAccounts)) {
    $file = Get-HubClaudeAccountFile
    $name = if (Test-Path -LiteralPath $file) { "$(Get-Content -LiteralPath $file -Raw)".Trim() }
    $active = @($accounts | Where-Object { $_.Name -eq $name })
    if ($active) { $active[0] } else { $accounts[0] }
}

function Set-HubClaudeActiveAccount($account) {
    $file = Get-HubClaudeAccountFile
    [void][IO.Directory]::CreateDirectory((Split-Path $file))
    [IO.File]::WriteAllText($file, $account.Name)
}
