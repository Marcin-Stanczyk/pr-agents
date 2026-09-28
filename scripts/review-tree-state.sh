#!/usr/bin/env bash
#
# Prints one line per file in the working tree (inode, size, mtime, path), so
# that any file the agent writes, replaces or adds after the snapshot shows up
# as a difference. Root-level `.agent-*` files are the agent's own output and
# are left out. `.git` is left out except hooks/ and info/ (claude-code-action
# may rewrite .git/config after the snapshot is taken).

set -euo pipefail

list_files() {
    if find . -maxdepth 0 -printf '%p' >/dev/null 2>&1; then
        find . \( -path ./.git -prune \) -o \( -type f -o -type l \) -printf '%i %s %T@ %p\n'
        find ./.git/hooks ./.git/info \( -type f -o -type l \) -printf '%i %s %T@ %p\n' 2>/dev/null || true
    else
        find . \( -path ./.git -prune \) -o \( -type f -o -type l \) -exec stat -f '%i %z %Fm %N' {} +
        find ./.git/hooks ./.git/info \( -type f -o -type l \) -exec stat -f '%i %z %Fm %N' {} + 2>/dev/null || true
    fi
}

list_files | grep -vE '^[0-9]+ [0-9]+ [0-9.]+ \./\.agent-[^/]*$' | LC_ALL=C sort -k4
