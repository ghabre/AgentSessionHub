# Agent Session Hub

Browse, resume, and transfer **Codex CLI, Claude Code, and OpenCode** conversations in Windows Terminal. Agent Session Hub is a PowerShell session manager for Windows, with support for agents installed in WSL2 or natively on Windows.

The hub opens two tabs. **history** is one picker over every enabled agent, with fuzzy search and transcript previews: conversations updated in the last 40 days (set `AGENT_HUB_DAYS` to change the window), newest first, each showing its age, agent and session id. A conversation handed between agents appears once, under the agent that used it last. **active** is a live board of running sessions with their state, model (`model+advisor` for Claude), last action, subagents and, for Claude on the WSL backend, running shells.

Reopen a conversation in its project folder, continue it in another agent, or switch Claude accounts while keeping the same session.

- **Alt+T destination menu:** The conversation's own agent comes first as Open, followed by other enabled agents. Multiple logged-in Claude accounts appear as separate choices.
- **Conversation handoffs:** Transfer unseen messages and tool notes, resume an existing linked destination, or combine selected conversations.
- **Claude accounts:** Share session history across logins, with email labels and account-specific tab colors.
- **Local backups:** Snapshot session history automatically, including OpenCode's SQLite database.

## Get started

Install Windows Terminal and Git, plus the tools required by your chosen backend:

| Backend | Requirements |
| --- | --- |
| WSL2 (default) | WSL2 with Bash, Linux `fzf`, Python 3.8+ with SQLite, and at least one supported agent CLI installed and signed in inside WSL. CLIs must be available in the login shell. |
| Native Windows | Git for Windows in its standard installation location, Windows `fzf`, Python 3.8+ with SQLite, PowerShell 7, and at least one supported agent CLI installed and signed in on Windows. |

Clone onto a Windows drive and launch from **Windows PowerShell**:

```powershell
git clone https://github.com/ghabre/AgentSessionHub.git
cd AgentSessionHub
.\AgentSessionHub.cmd
```

For native Windows agents, set the backend before launching:

```powershell
$env:AGENT_HUB_BACKEND = 'windows'
.\AgentSessionHub.cmd
```

## Choose which agents appear

The first launch creates `agent-hub.config` in this folder with every CLI on. It is per-machine and gitignored; set each CLI to `on` or `off`. For example:

```ini
codex=on
claude=on
opencode=off
```

This controls which agents' conversations are listed, backed up and offered as destinations. Press Esc in the picker to apply a change.

## Use the history picker

| Action | Key |
| --- | --- |
| Search sessions | Type to filter |
| Resume the highlighted session | Enter |
| Choose an agent or Claude account | Alt+T |
| Mark sessions to combine into one conversation | Tab, then Enter or Alt+T |
| Toggle transcript preview | Alt+P |
| Hide selected sessions from the picker | Alt+H |
| Restore hidden sessions | Alt+S |
| Reload sessions and configuration | Esc |
| Cycle Claude accounts, ending at a new-account option | Alt+A |

Mouse clicks highlight a row; clicking that highlighted row again opens it. Use the first **New session** row to choose an agent, then a project folder or a new one.

For a Claude conversation, choosing another Claude account through Alt+T resumes the original session without exporting a handoff. Accounts use `~/.claude` and numbered `~/.claude-<n>` folders in the chosen backend. Alt+A's new-account option creates the next numbered folder on the next Claude launch; sign in there to add a login. Native Windows account sharing requires permission to create symbolic links, normally enabled through Windows Developer Mode. To share history between Claude logins without the hub, see [claude-account-switching.md](claude-account-switching.md); the hub only recognizes numbered folders.

## Paths and local data

The default new-project root is `C:\G\code`. Override it with `AGENT_HUB_NEW_ROOT`, a Windows path.

For WSL, `WSL_DISTRO` selects a distribution and `WSL_USER` overrides home-directory discovery. OpenCode database discovery respects `OPENCODE_DB` and `XDG_DATA_HOME` in the selected backend.

Backups go to `backups/<tool>/`, at most once every 24 hours, retaining the latest ten. Override locations with `CODEX_BACKUP_DIR`, `CLAUDE_BACKUP_DIR`, or `OPENCODE_BACKUP_DIR`.

Transfer tracking and exported conversation payloads live in `.history/`, separated by backend and distribution. Keep that folder to preserve synchronization. Both `.history/` and `backups/` are gitignored and contain conversation data; keep them private. Hidden-session choices and the active Claude account are stored under `%LOCALAPPDATA%\AgentSessionHub`.

## Development

There is no build step. See [AGENTS.md](AGENTS.md) for script conventions and Windows manual checks. Run the existing checks with:

```powershell
python -m unittest test_handoff_sync.py test_hub_board.py
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test_hub_tools.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test_handoff_sync.ps1
```

The Windows integration check requires Git for Windows and Python; it uses isolated transcripts and does not launch agent CLIs.
