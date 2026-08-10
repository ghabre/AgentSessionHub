# Repository Guidelines

## Local Commit Policy

After every completed repository change, automatically create a local Git commit with a concise, meaningful message describing the result. Do not wait for a separate request. Keep commits focused, verify the staged diff, and never push unless the user explicitly requests a remote push.

## Project Structure & Module Organization

This repository contains Windows launchers and PowerShell utilities for Codex and Claude Code sessions stored in WSL.

- `recent-codex.ps1` and `recent-claude.ps1` are session pickers that create backups, export handoffs, and launch Windows Terminal tabs.
- `recent-*.cmd` and `*.lnk` files are Windows entry points; keep them aligned with the corresponding PowerShell scripts.
- `fixclip.ps1` and `fixclip.cmd` repair text clipboard forwarding in RDP scenarios.
- `backups/{codex,claude}/` contains generated transcript archives. Treat these as data, not source, and do not edit archives manually.

## Paired Script Changes

Treat `recent-codex.ps1` and `recent-claude.ps1` as mirrored implementations. Apply changes to picker behavior, handoffs, clipboard export, backups, WSL integration, and launch flow symmetrically. Preserve intentional product-specific differences: command names, data directories, prompts, and environment-variable prefixes. State how parity was verified; explain any one-script-only change.

## Build, Test, and Development Commands

There is no compilation step. Run scripts from Windows PowerShell because they depend on Windows Terminal, WSL, and Windows APIs:

```powershell
powershell.exe -NoExit -ExecutionPolicy Bypass -File .\recent-codex.ps1
powershell.exe -NoExit -ExecutionPolicy Bypass -File .\recent-claude.ps1
powershell.exe -ExecutionPolicy Bypass -File .\fixclip.ps1
```

Before submitting changes, perform a parser check:

```powershell
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\recent-codex.ps1), [ref]$null, [ref]$errors)
$errors
```

An empty result means parsing succeeded. Functional testing requires Windows, WSL2, Linux `fzf`, and the relevant CLI. `pandoc` is required only for formatted clipboard export.

## Coding Style & Naming Conventions

Use four-space indentation in PowerShell blocks. Follow existing PowerShell conventions: `PascalCase` for functions and approved verbs (for example, `ConvertTo-WslPath`), and descriptive `camelCase` for local variables. Keep environment overrides uppercase, such as `CODEX_BACKUP_DIR`. Preserve `$ErrorActionPreference = 'Stop'`, UTF-8 handling, and LF normalization for generated shell scripts. Comment cross-boundary quoting and Windows/WSL path conversions, which are easy to break.

## Testing Guidelines

No automated test suite or coverage target is present. Parser-check every modified `.ps1`, then manually exercise the affected picker action in both session pickers: new session, resume, Alt-C handoff, Alt-F export, multi-select, or backup rotation. Confirm both keyboard and mouse behavior when changing `fzf` bindings.

## Commit & Pull Request Guidelines

No Git history is available in this directory, so use short imperative commits such as `Fix Codex handoff quoting`. Keep changes focused. Pull requests should describe the user-visible behavior, Windows/WSL versions tested, manual test cases, and any new prerequisites or environment variables. Include screenshots only for visible picker or terminal changes; never attach transcript backups.
