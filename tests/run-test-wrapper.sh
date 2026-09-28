#!/usr/bin/env bash
#
# Proves what the reviewer's single-test wrapper accepts and refuses, against a
# throwaway git repository and a stub test runner.
#
# Usage: bash tests/run-test-wrapper.sh
#        SCRIPTS_DIR=/path/to/mutated/scripts bash tests/run-test-wrapper.sh

set -uo pipefail

SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "$0")/../scripts" && pwd -P)}"
work="$(mktemp -d)"
cleanup() {
    chmod -R u+w "$work" 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT

passed=0
failed=0
fixture_count=0

cat > "$work/stub-runner.sh" <<'STUB'
#!/usr/bin/env bash
echo "STUB-RAN:$1"
if [ -n "${AGENT_SECRET:-}" ]; then
    echo "SECRET-VISIBLE"
fi
mkdir -p .cache
date +%s%N > .cache/last-run
if grep -q -e STUB-FAIL -- "$1"; then
    exit 3
fi
exit 0
STUB

git_quiet() {
    git -c user.name=test -c user.email=test@example.invalid -c init.defaultBranch=main "$@" >/dev/null 2>&1
}

new_repo() {
    fixture_count=$((fixture_count + 1))
    repo="$work/repo-$fixture_count"
    dest="$work/wrapper-$fixture_count"
    mkdir -p "$repo/tests/unit" "$repo/src" "$repo/config"
    (
        cd "$repo" || exit 1
        git_quiet init
        printf 'node_modules/\n.cache/\n' > .gitignore
        echo 'echo ok' > tests/ok.test.sh
        echo 'echo nested' > tests/unit/nested.test.sh
        echo 'echo STUB-FAIL' > tests/failing.test.sh
        echo 'echo dirty' > tests/dirty.test.sh
        echo 'echo spaced' > "tests/has space.test.sh"
        echo 'echo tool' > src/tool.sh
        echo 'setting=1' > config/runner.conf
        echo 'flag-named file' > ./-x
        mkdir -p node_modules
        echo 'module.exports = 1' > node_modules/dep.js
        git_quiet add -A -- .
        git_quiet commit -m fixture
        echo 'echo untracked' > tests/untracked.test.sh
        echo 'echo changed before the review started' >> tests/dirty.test.sh
    )
}

install_wrapper() {
    (cd "$repo" && TEST_RUNNER="bash $work/stub-runner.sh" TEST_FILE_GLOB="$1" \
        bash "$SCRIPTS_DIR/review-test-install.sh" "$dest" >/dev/null)
}

fresh() {
    new_repo
    install_wrapper "${1:-tests/*}"
}

run_wrapper() {
    output="$(cd "$repo" && AGENT_SECRET=token-value bash "$dest/review-run-test.sh" "$@" 2>&1 </dev/null)"
    status=$?
}

record() {
    if [ "$1" = ok ]; then
        passed=$((passed + 1))
        echo "PASS  $2"
    else
        failed=$((failed + 1))
        echo "FAIL  $2"
        printf '      exit=%s output: %s\n' "$status" "$(printf '%s' "$output" | head -5 | tr '\n' '|')"
    fi
}

expect_refused() {
    local name="$1"; shift
    run_wrapper "$@"
    if [ "$status" -ne 0 ] && [[ "$output" == *REFUSED* ]] && [[ "$output" != *STUB-RAN* ]]; then
        record ok "$name"
    else
        record fail "$name"
    fi
}

expect_ran() {
    local name="$1" expected_status="$2"; shift 2
    run_wrapper "$@"
    if [ "$status" -eq "$expected_status" ] && [[ "$output" == *"STUB-RAN:$1"* ]]; then
        record ok "$name"
    else
        record fail "$name"
    fi
}

echo "Wrapper under test: $SCRIPTS_DIR"
echo

fresh
expect_ran "accepts a committed, unchanged test file" 0 tests/ok.test.sh
expect_ran "accepts it again after the runner wrote its own cache" 0 tests/ok.test.sh
expect_ran "accepts a nested test file" 0 tests/unit/nested.test.sh
if [[ "$output" == *SECRET-VISIBLE* ]]; then
    record fail "the test runs without the caller's secrets in its environment"
else
    record ok "the test runs without the caller's secrets in its environment"
fi
expect_ran "passes the runner's failing exit code through" 3 tests/failing.test.sh
echo '# review' > "$repo/.agent-review.md"
echo '[]' > "$repo/.agent-notes.json"
expect_ran "accepts after the reviewer wrote its .agent-* output files" 0 tests/ok.test.sh

fresh
expect_refused "refuses no argument"
expect_refused "refuses a second argument (a flag after the path)" tests/ok.test.sh --bootstrap
expect_refused "refuses a --flag=value argument" --bootstrap=evil.php
expect_refused "refuses a path outside the pattern (committed src/tool.sh)" src/tool.sh
expect_refused "refuses path traversal out of the pattern" tests/../src/tool.sh
expect_refused "refuses a '.' path segment" tests/./ok.test.sh
expect_refused "refuses a path with a space (committed, matches the pattern)" "tests/has space.test.sh"
expect_refused "refuses a path with a newline" "tests/ok.test.sh
src/tool.sh"
expect_refused "refuses an untracked test file" tests/untracked.test.sh
expect_refused "refuses a test file modified before the review started" tests/dirty.test.sh
expect_refused "refuses a file that does not exist" tests/missing.test.sh

fresh '*'
expect_refused "refuses a flag even when a committed file has that name (pattern '*')" -x
expect_refused "refuses an absolute path (pattern '*')" "$repo/tests/ok.test.sh"

fresh
echo 'echo injected' >> "$repo/tests/ok.test.sh"
expect_refused "refuses a test file modified after the review started" tests/ok.test.sh

fresh
echo 'bootstrap=/tmp/evil' >> "$repo/config/runner.conf"
expect_refused "refuses when another committed file (runner config) was modified" tests/ok.test.sh

fresh
echo 'require("child_process").exec("evil")' > "$repo/node_modules/dep.js"
expect_refused "refuses when a git-ignored dependency was modified" tests/ok.test.sh

fresh
echo 'evil' > "$repo/node_modules/new.js"
expect_refused "refuses when a new git-ignored file appeared" tests/ok.test.sh

fresh
echo 'echo new' > "$repo/tests/new.test.sh"
expect_refused "refuses a test file written after the review started" tests/new.test.sh
expect_refused "refuses any test once an untracked file appeared" tests/ok.test.sh

fresh
cp -p "$repo/tests/ok.test.sh" "$work/replacement"
mv "$work/replacement" "$repo/tests/ok.test.sh"
expect_refused "refuses a file replaced by rename (same content and mtime)" tests/ok.test.sh

fresh
mkdir -p "$repo/.agent-extra"
echo 'evil' > "$repo/.agent-extra/setup.js"
expect_refused "refuses when files appear under an .agent-* directory" tests/ok.test.sh

fresh
echo 'evil' > "$repo/.git/hooks/post-checkout"
expect_refused "refuses when a git hook was added" tests/ok.test.sh

fresh
chmod u+w "$dest"
rm -f "$dest/review-run-test.conf"
expect_refused "refuses when the wrapper is not configured" tests/ok.test.sh

fresh
if (: > "$dest/runnable-files") 2>/dev/null || (: > "$dest/new-file") 2>/dev/null; then
    status=0; output="installed directory is writable"; record fail "installed wrapper directory is read-only"
else
    status=1; output=""; record ok "installed wrapper directory is read-only"
fi

new_repo
install_output="$(cd "$repo" && TEST_RUNNER='' TEST_FILE_GLOB='tests/*' bash "$SCRIPTS_DIR/review-test-install.sh" "$dest" 2>&1)"
status=$?
output="$install_output"
if [ "$status" -eq 0 ] && [ ! -e "$dest" ]; then
    record ok "empty TEST_RUNNER installs no wrapper"
else
    record fail "empty TEST_RUNNER installs no wrapper"
fi

new_repo
output="$(cd "$repo" && TEST_RUNNER='bash x' TEST_FILE_GLOB='' bash "$SCRIPTS_DIR/review-test-install.sh" "$dest" 2>&1)"
status=$?
if [ "$status" -ne 0 ] && [ ! -e "$dest/review-run-test.sh" ]; then
    record ok "empty TEST_FILE_GLOB refuses to install"
else
    record fail "empty TEST_FILE_GLOB refuses to install"
fi

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
