#!/bin/bash
# Usage: claude-accounts.sh SHARED_DIR [new]
#
# Claude accounts are several logins sharing one session history. SHARED_DIR (~/.claude) is
# the first account and keeps the real history and customizations. Every sibling
# SHARED_DIR-<n> folder (~/.claude-2, ~/.claude-3, ...) is another account: it keeps only
# its own login (.credentials.json, .claude.json, org policy/remote settings, daemon state)
# and symlinks everything in SHARED_ITEMS to SHARED_DIR, so any account can resume any
# session. 'new' first creates the next free SHARED_DIR-<n>.
#
# Never deletes data: an item already in the way is renamed NAME.pre-shared-STAMP. An
# account with a live Claude session is skipped (its transcript is still being written).
# Output lines: ACCOUNT:<dir><TAB><login email><TAB><account uuid> (both empty until logged
# in; the uuid is what transcripts record as their owner), SHARED_DIR first, then by number.
# Also SET_ASIDE:<path>  LIVE:<account>  LINK_FAILED:<account>
set -u
shared=${1:?shared dir}

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

if [ "${2-}" = new ]; then
    n=2
    while [ -e "$shared-$n" ]; do n=$((n + 1)); done
    mkdir "$shared-$n"
fi

# The first account's file sits beside its folder (~/.claude.json), the others' inside.
login() { sed -n '/"oauthAccount"/,/}/p' "$1" 2>/dev/null | grep -o "\"$2\": *\"[^\"]*\"" | head -1 | cut -d'"' -f4; }
account_line() { printf 'ACCOUNT:%s\t%s\t%s\n' "$1" "$(login "$2" emailAddress)" "$(login "$2" accountUuid)"; }
account_line "$shared" "$shared.json"

numbers=()
for account in "$shared"-*/; do
    suffix=${account#"$shared"-}
    suffix=${suffix%/}
    case "$suffix" in ''|*[!0-9]*) ;; *) numbers+=("$suffix") ;; esac
done

for n in $(printf '%s\n' ${numbers[@]+"${numbers[@]}"} | sort -n); do
    account="$shared-$n"
    account_line "$account" "$account/.claude.json"
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
        ln -s "$target" "$link" 2>/dev/null || { echo "LINK_FAILED:$account"; break; }
    done
done
exit 0
