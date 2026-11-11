# Repository Guidelines

## Commit and Push Policy

After every completed repository change, automatically create a Git commit with a concise, meaningful message describing the result and push it to `origin`, which backs up this tooling repo. Do not wait for a separate request. Keep commits focused and verify the staged diff.

## Project Structure & Module Organization

This repository contains Windows launchers and PowerShell utilities for Codex, Claude Code and OpenCode sessions stored in WSL, or natively on Windows when `AGENT_HUB_BACKEND=windows` (helper scripts then run under Git for Windows' bash; see each picker's header).

- `recent-codex.ps1`, `recent-claude.ps1` and `recent-opencode.ps1` are session pickers that create backups, export handoffs, and launch Windows Terminal tabs.
- `AgentSessionHub.cmd` and `Agent Session Hub.lnk` open the enabled pickers as tabs. `AGENT_HUB_TOOLS` is a comma-separated list drawn from `codex,claude,opencode` and defaults to all three. `codex.cmd`, `claude.cmd` and `opencode.cmd` remain portable helpers; keep launchers aligned with their PowerShell scripts.
- `fixclip.ps1` and `fixclip.cmd` repair text clipboard forwarding in RDP scenarios.
- `backups/{codex,claude,opencode}/` contains generated transcript/database archives. Treat these as data, not source, and do not edit archives manually.

Claude accounts (personal CP, work CW, dev CD; defined in `Get-HubClaudeProfiles` in `hub-tools.ps1`) share one session history in `~/.claude`. Each non-personal account keeps only its login in `~/.claude-<name>` (or `CLAUDE_<NAME>_CONFIG_DIR`), and `link-claude-accounts.sh` links everything else to `~/.claude`; it never deletes, renaming anything in the way to `*.pre-shared-<stamp>`, and skips accounts with live sessions. Alt-A in the Claude picker sets the active account (saved in `%LOCALAPPDATA%\AgentSessionHub\claude-account.txt`), which every Claude launch and handoff uses. Personal launches unset `CLAUDE_CONFIG_DIR` because its account file is `~/.claude.json`.

OpenCode stores all projects in one SQLite database (`~/.local/share/opencode/opencode.db` by default); `recent-opencode.ps1` reads it with Python 3 and snapshots it through SQLite's online backup API. Its global instructions live in `~/.config/opencode/AGENTS.md`, which points at the same shared memory file used by Codex and Claude.

## Paired Script Changes

Treat `recent-codex.ps1`, `recent-claude.ps1` and `recent-opencode.ps1` as mirrored implementations. Apply changes to picker behavior, handoffs, clipboard export, backups, WSL integration, and launch flow symmetrically. Preserve intentional product-specific differences: command names, data directories, storage formats (JSONL transcripts vs. `opencode.db`), prompts, and environment-variable prefixes. State how parity was verified; explain any one-script-only change.

## Build, Test, and Development Commands

There is no compilation step. Run scripts from Windows PowerShell because they depend on Windows Terminal, WSL, and Windows APIs:

```powershell
powershell.exe -NoExit -ExecutionPolicy Bypass -File .\recent-codex.ps1
powershell.exe -NoExit -ExecutionPolicy Bypass -File .\recent-claude.ps1
powershell.exe -NoExit -ExecutionPolicy Bypass -File .\recent-opencode.ps1
powershell.exe -ExecutionPolicy Bypass -File .\fixclip.ps1
```

Before submitting changes, perform a parser check:

```powershell
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\recent-codex.ps1), [ref]$null, [ref]$errors)
$errors
```

An empty result means parsing succeeded. Functional testing requires Windows, WSL2, Linux `fzf`, and the relevant CLI for the default backend; the windows backend needs Git for Windows, Windows `fzf`, PowerShell 7 and the native CLI instead. OpenCode support additionally needs Python 3 with SQLite. Changes to shared paths should keep both backends working. `pandoc` is required only for formatted clipboard export.

## Coding Style & Naming Conventions

Use four-space indentation in PowerShell blocks. Follow existing PowerShell conventions: `PascalCase` for functions and approved verbs (for example, `ConvertTo-WslPath`), and descriptive `camelCase` for local variables. Keep environment overrides uppercase, such as `CODEX_BACKUP_DIR`, `OPENCODE_BACKUP_DIR`, and `AGENT_HUB_TOOLS`. Preserve `$ErrorActionPreference = 'Stop'`, UTF-8 handling, and LF normalization for generated shell scripts. Comment cross-boundary quoting and Windows/WSL path conversions, which are easy to break.

## Testing Guidelines

No automated test suite or coverage target is present. Parser-check every modified `.ps1`, then manually exercise the affected picker action in all three session pickers: new session, resume, Alt-X/Alt-C/Alt-O handoff, Alt-F export, multi-select, or backup rotation. Confirm both keyboard and mouse behavior when changing `fzf` bindings. For OpenCode, also verify that session listing, handoff export, and database backup still work with `OPENCODE_DB` or `XDG_DATA_HOME` set.

## Commit & Pull Request Guidelines

No Git history is available in this directory, so use short imperative commits such as `Fix Codex handoff quoting`. Keep changes focused. Pull requests should describe the user-visible behavior, Windows/WSL versions tested, manual test cases, and any new prerequisites or environment variables. Include screenshots only for visible picker or terminal changes; never attach transcript backups.
