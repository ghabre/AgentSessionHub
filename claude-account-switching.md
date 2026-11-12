# Switch Claude Code accounts and keep one session history

Keep each login in its own configuration folder. Link the history and customizations to one shared folder, so switching accounts changes the login while keeping your conversations available. This works with Claude Code in a terminal; no account-switching tool is needed.

## 1. Sign in to each account once

Use your normal `~/.claude` folder for the first account and a folder such as `~/.claude-work` for the second. Repeat with another folder name for more accounts.

On **macOS, Linux, or WSL**, run these separately, exiting Claude after each login:

```bash
# First account
(unset CLAUDE_CONFIG_DIR; claude)

# Second account: choose its email in the browser login
CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude
```

On **Windows PowerShell**, run these separately, exiting Claude after each login:

```powershell
# First account
Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
claude

# Second account: choose its email in the browser login
$env:CLAUDE_CONFIG_DIR = "$HOME\.claude-work"
claude
```

Separate configuration directories are [documented by Anthropic](https://code.claude.com/docs/en/authentication#log-in-with-multiple-accounts). Without the next step, each account has its own history and settings.

## 2. Share history and customizations

Close all Claude Code sessions before setting up links. Run the following in **Bash**: a terminal on macOS/Linux, WSL for WSL-installed Claude, or **Git Bash for native Windows Claude**. On Windows, enable Developer Mode or run Git Bash as administrator so it can create native symbolic links. Use the same home directory that your Claude installation uses; Windows and WSL have separate homes.

This keeps existing items in the second account as timestamped backups; it does not merge their contents into the shared history.

```bash
(
set -e
shared="$HOME/.claude"
account="$HOME/.claude-work"
stamp=$(date +%Y%m%d-%H%M%S)

# Make Git Bash fail rather than silently copy when a symlink cannot be made.
export MSYS=winsymlinks:nativestrict
mkdir -p "$account"

for name in projects sessions file-history todos plans shell-snapshots session-env paste-cache; do
    mkdir -p "$shared/$name"
done
touch "$shared/history.jsonl"

for name in projects sessions file-history todos plans shell-snapshots session-env paste-cache \
    history.jsonl CLAUDE.md settings.json commands agents skills hooks plugins \
    output-styles scripts statusline-command.sh; do
    [ -e "$shared/$name" ] || continue
    [ ! -L "$account/$name" ] || continue
    if [ -e "$account/$name" ]; then
        mv "$account/$name" "$account/$name.pre-shared-$stamp"
    fi
    ln -s "$shared/$name" "$account/$name"
done
)
```

Keep `.credentials.json`, `.claude.json`, organization policy, remote settings, and daemon state separate. Never link the entire configuration folder. Credentials may also live in the macOS Keychain; sign in on each machine rather than copying credentials.

The original account must launch with `CLAUDE_CONFIG_DIR` **unset**: its account file is `~/.claude.json`. Setting the variable to `~/.claude` makes Claude look for that file inside the folder instead.

## 3. Switch by choosing the launch command

Use the commands from step 1 whenever you want to switch. Exit the current session, launch with the other account, and use `/status` to confirm the login. From the same project directory, add `--resume` to `claude` to choose a shared conversation.

On macOS/Linux/WSL, optional shortcuts in `~/.bashrc` or `~/.zshrc` make this quicker:

```bash
claude-personal() { (unset CLAUDE_CONFIG_DIR; claude "$@"); }
claude-work() { CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude "$@"; }
```

Open a new terminal, then run `claude-personal` or `claude-work --resume`.

Repeat setup on each machine. These links share local files between accounts; they do not sync machines. Newly created customizations that were absent during setup need the linking step run again. Each account keeps its own `.claude.json`, so MCP configuration and trust decisions stored there remain separate. Only share conversations and settings between accounts where you intend both to use them.
