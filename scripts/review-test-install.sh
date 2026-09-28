#!/usr/bin/env bash
#
# Installs the single-test wrapper for the reviewer OUTSIDE the working tree,
# read-only, together with a snapshot of the tree taken before the agent starts.
# Run from the repository root by the workflow, never by the agent.
#
# Usage: TEST_RUNNER='npx vitest run' TEST_FILE_GLOB='tests/*.test.ts' \
#          review-test-install.sh <destination directory>
# An empty TEST_RUNNER installs nothing: the reviewer then has no way to run code.

set -euo pipefail

dest="${1:?usage: review-test-install.sh <destination directory>}"
scripts_dir="$(cd "$(dirname "$0")" && pwd -P)"

if [ -z "${TEST_RUNNER:-}" ]; then
    echo "TEST_RUNNER is empty: the reviewer will not be able to run tests."
    exit 0
fi
if [ -z "${TEST_FILE_GLOB:-}" ]; then
    echo "TEST_FILE_GLOB is empty: refusing to install a wrapper that would accept any file." >&2
    exit 1
fi
case "$TEST_RUNNER$TEST_FILE_GLOB" in
    *$'\n'*) echo "TEST_RUNNER and TEST_FILE_GLOB must be single lines." >&2; exit 1 ;;
esac

if [ -e "$dest" ]; then
    chmod -R u+w "$dest"
    rm -rf "$dest"
fi
mkdir -p "$dest"

cp "$scripts_dir/review-run-test.sh" "$scripts_dir/review-tree-state.sh" "$dest/"
printf 'runner=%s\nglob=%s\n' "$TEST_RUNNER" "$TEST_FILE_GLOB" > "$dest/review-run-test.conf"

git ls-files -z | tr '\0' '\n' | LC_ALL=C sort > "$dest/tracked.all"
{ git diff --name-only -z HEAD; git ls-files -z --deleted; } | tr '\0' '\n' | LC_ALL=C sort -u > "$dest/tracked.changed"
LC_ALL=C comm -23 "$dest/tracked.all" "$dest/tracked.changed" > "$dest/runnable-files"
rm -f "$dest/tracked.all" "$dest/tracked.changed"

bash "$dest/review-tree-state.sh" > "$dest/tree-state"

chmod -R a-w "$dest"
echo "Test wrapper installed in $dest ($(wc -l < "$dest/runnable-files" | tr -d ' ') committed files, runner: $TEST_RUNNER, pattern: $TEST_FILE_GLOB)"
