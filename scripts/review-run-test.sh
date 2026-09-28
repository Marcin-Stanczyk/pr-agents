#!/usr/bin/env bash
#
# The only command the reviewer agent may execute: run ONE committed test file.
#
# A `Bash(tool:*)` allowlist entry does not restrict arguments, and most test
# runners accept flags or config files that load arbitrary code before any test
# runs (phpunit --bootstrap, node --require, a rewritten vitest.config). Combined
# with the agent's Write tool, that turns text in a diff into code execution in a
# job holding secrets. This wrapper only runs code committed at HEAD, in a tree
# nobody has touched since review-test-install.sh took its snapshot, with an
# environment stripped of the job's tokens.

set -euo pipefail

refuse() {
    echo "REFUSED: $1" >&2
    exit "${2:-64}"
}

home_dir="$(cd "$(dirname "$0")" && pwd -P)"
[ -r "$home_dir/review-run-test.conf" ] || refuse "the test wrapper is not configured" 78
[ -r "$home_dir/runnable-files" ] || refuse "the test wrapper is not installed (no list of committed files)" 78
[ -r "$home_dir/tree-state" ] || refuse "the test wrapper is not installed (no snapshot of the tree)" 78

runner=""
glob=""
while IFS='=' read -r key value; do
    case "$key" in
        runner) runner="$value" ;;
        glob) glob="$value" ;;
    esac
done < "$home_dir/review-run-test.conf"
[ -n "$runner" ] || refuse "no test runner configured" 78
[ -n "$glob" ] || refuse "no test file pattern configured" 78

[ "$#" -eq 1 ] || refuse "pass exactly one argument: the path of a test file matching '$glob'"
test_path="$1"

case "$test_path" in
    -*) refuse "flags are not accepted: $test_path" ;;
    /*) refuse "absolute paths are not accepted: $test_path" ;;
esac

[[ "$test_path" =~ ^[A-Za-z0-9._/@+-]+$ ]] \
    || refuse "the path may only contain letters, digits and . _ / @ + -: $test_path"

case "/$test_path/" in
    */../*|*/./*) refuse "'.' and '..' path segments are not accepted: $test_path" ;;
esac

# shellcheck disable=SC2053
[[ "$test_path" == $glob ]] || refuse "only files matching '$glob' may run: $test_path"

is_runnable() {
    local listed
    while IFS= read -r listed; do
        [ "$listed" = "$1" ] && return 0
    done < "$home_dir/runnable-files"
    return 1
}
is_runnable "$test_path" \
    || refuse "not a file committed at HEAD and unchanged when the review started: $test_path" 77

[ -f "$test_path" ] || refuse "no such file: $test_path" 66

tree_changes="$(diff "$home_dir/tree-state" <(bash "$home_dir/review-tree-state.sh") || true)"
if [ -n "$tree_changes" ]; then
    printf '%s\n' "$tree_changes" | head -20 >&2
    refuse "files changed since the review started (above); only the committed tree may run" 77
fi

kept_environment=()
for name in PATH HOME USER LANG LC_ALL TZ TMPDIR CI; do
    if [ -n "${!name+set}" ]; then
        kept_environment+=("$name=${!name}")
    fi
done

read -r -a runner_command <<< "$runner"
echo "Running: ${runner_command[*]} $test_path"
status=0
env -i "${kept_environment[@]}" "${runner_command[@]}" "$test_path" || status=$?

chmod u+w "$home_dir" "$home_dir/tree-state"
bash "$home_dir/review-tree-state.sh" > "$home_dir/tree-state"
chmod a-w "$home_dir" "$home_dir/tree-state"

exit "$status"
