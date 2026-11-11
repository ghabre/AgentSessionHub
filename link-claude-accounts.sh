#!/bin/bash
# Usage: link-claude-accounts.sh SHARED_DIR ACCOUNT_DIR...
#
# Lets several Claude logins share one session history. SHARED_DIR (~/.claude) keeps the
# real history and customizations; each ACCOUNT_DIR (~/.claude-work, ...) keeps only its
# own login (.credentials.json, .claude.json, org policy/remote settings, daemon state) and
# symlinks everything in SHARED_ITEMS to SHARED_DIR, so any account can resume any session.
#
# Never deletes data: an item already in the way is renamed NAME.pre-shared-STAMP. An
# account with a live Claude session is skipped (its transcript is still being written).
# Output lines: SET_ASIDE:<path>  LIVE:<account>  LINK_FAILED:<path>
set -u
shared=${1:?shared dir}
shift

SHARED_DIRS=(projects sessions file-history todos plans shell-snapshots session-env paste-cache)
SHARED_FILES=(history.jsonl CLAUDE.md settings.json commands agents skills hooks plugins output-styles scripts statusline-command.sh)

case "$OSTYPE" in
    # Git Bash silently copies instead of linking unless told to fail; a copy would fork
    # the history. Native symlinks need Windows Developer Mode (or an elevated shell).
    msys*|cygwin*) export MSYS=winsymlinks:nativestrict ;;
esac

is_live() {
    case "$OSTYPE" in
        msys*|cygwin*) tasklist //FI "PID eq $1" //NH 2>/dev/null | grep -qw "$1" ;;
        *) [ -d "/proc/$1" ] ;;
    esac
}

for d in "${SHARED_DIRS[@]}"; do mkdir -p "$shared/$d"; done
[ -e "$shared/history.jsonl" ] || : > "$shared/history.jsonl"
stamp=$(date +%Y%m%d-%H%M%S)

for account in "$@"; do
    [ -d "$account" ] || continue
    # Only an unlinked sessions/ dir can hold sessions missing from the shared history.
    if [ -d "$account/sessions" ] && [ ! -L "$account/sessions" ]; then
        live=
        for f in "$account"/sessions/*.json; do
            [ -f "$f" ] || continue
            pid=$(basename "$f" .json)
            case "$pid" in *[!0-9]*|'') continue ;; esac
            if is_live "$pid"; then live=1; break; fi
        done
        if [ -n "$live" ]; then echo "LIVE:$account"; continue; fi
    fi
    for name in "${SHARED_DIRS[@]}" "${SHARED_FILES[@]}"; do
        target="$shared/$name"
        link="$account/$name"
        [ -e "$target" ] || continue
        if [ -L "$link" ]; then
            [ "$(readlink "$link")" = "$target" ] && continue
            rm -f "$link"   # removes only the stale link, never what it pointed at
        elif [ -e "$link" ]; then
            mv "$link" "$link.pre-shared-$stamp" && echo "SET_ASIDE:$link.pre-shared-$stamp"
        fi
        ln -s "$target" "$link" 2>/dev/null || echo "LINK_FAILED:$link"
    done
done
exit 0
