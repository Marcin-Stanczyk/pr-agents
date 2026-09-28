#!/usr/bin/env bash
#
# Breaks each guard of the test wrapper (on a copy of scripts/) and each decision
# of the workflow steps (on a copy of the workflow), runs the matching test suite
# against the copy and requires it to FAIL.
# A mutation that does not apply, or that the suite does not notice, fails this run.
#
# Usage: bash tests/mutation-check.sh

# shellcheck disable=SC2016
set -uo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

caught=0
missed=0

mutate() {
    local name="$1"; shift
    local copy="$work/$caught-$missed-scripts"
    rm -rf "$copy"
    cp -R "$repo_root/scripts" "$copy"

    while [ "$#" -ge 2 ]; do
        local file="$1" expression="$2"; shift 2
        local before
        before="$(cat "$copy/$file")"
        sed -E "$expression" "$copy/$file" > "$copy/$file.mutated" && mv "$copy/$file.mutated" "$copy/$file"
        if [ "$before" = "$(cat "$copy/$file")" ]; then
            echo "NOT APPLIED  $name  ($file: $expression)"
            missed=$((missed + 1))
            return
        fi
    done

    local report suite_status
    report="$(SCRIPTS_DIR="$copy" bash "$repo_root/tests/run-test-wrapper.sh" 2>&1)"
    suite_status=$?
    if [ "$suite_status" -ne 0 ]; then
        caught=$((caught + 1))
        echo "CAUGHT       $name  (suite exit $suite_status)"
        printf '%s\n' "$report" | grep '^FAIL' | sed 's/^/               /'
    else
        missed=$((missed + 1))
        echo "SURVIVED     $name  (suite exit 0)"
    fi
}

W=review-run-test.sh
I=review-test-install.sh
S=review-tree-state.sh

mutate "argument count: accept more than one"        $W 's/\[ "\$#" -eq 1 \]/[ "$#" -ge 1 ]/'
mutate "leading '-' guard removed"                   $W 's/^    -\*\) refuse "flags/    --never-*) refuse "flags/'
mutate "absolute-path guard + committed-file list"   $W 's/^    \/\*\) refuse/    \/never\/*) refuse/' \
                                                     $W 's/^is_runnable "\$test_path" \\$/true \\/'
mutate "character allowlist removed"                 $W 's/\^\[A-Za-z0-9\._\/@\+-\]\+\$/.*/'
mutate "'..' guard + committed-file list"            $W 's/\*\/\.\.\/\*\|\*\/\.\/\*\)/*\/never\/*)/' \
                                                     $W 's/^is_runnable "\$test_path" \\$/true \\/'
mutate "pattern (glob) check removed"                $W 's/\[\[ "\$test_path" == \$glob \]\]/true/'
mutate "committed-file list check removed"           $W 's/^is_runnable "\$test_path" \\$/true \\/'
mutate "tree snapshot comparison removed"            $W 's/^if \[ -n "\$tree_changes" \]; then$/if false; then/'
mutate "snapshot not refreshed after a run"          $W 's/^bash "\$home_dir\/review-tree-state.sh" > "\$home_dir\/tree-state"$/true/'
mutate "environment not scrubbed"                   $W 's/^env -i "\$\{kept_environment\[@\]\}" /env /'
mutate "runner exit code swallowed"                  $W 's/^exit "\$status"$/exit 0/'
mutate "install: files changed before review kept"   $I 's/comm -23 "\$dest\/tracked.all" "\$dest\/tracked.changed"/cat "$dest\/tracked.all"/'
mutate "install: directory left writable"            $I 's/^chmod -R a-w "\$dest"$/true/'
mutate "install: empty pattern accepted"             $I 's/^    exit 1$/    true/'
mutate "snapshot: .agent-* output not excluded"      $S 's/grep -vE .*\| LC_ALL/LC_ALL/'
mutate "snapshot: .agent-* exclusion covers subdirs" $S 's/\\\.agent-\[\^\/\]\*\$/\\.agent-.*$/'
mutate "snapshot: git hooks not covered"             $S 's/\.\/\.git\/hooks //g'
mutate "snapshot: ignores inode (rename replace)"    $S "s/'%i %s/'0 %s/g; s/'%i %z/'0 %z/g"

mutate_workflow() {
    local name="$1" expression="$2"
    local copy="$work/workflow-$caught-$missed.yml"
    sed -E "$expression" "$repo_root/workflows/agent-review.yml" > "$copy"
    if cmp -s "$copy" "$repo_root/workflows/agent-review.yml"; then
        echo "NOT APPLIED  $name  ($expression)"
        missed=$((missed + 1))
        return
    fi
    local report suite_status
    report="$(WORKFLOW="$copy" bash "$repo_root/tests/workflow-steps.sh" 2>&1)"
    suite_status=$?
    if [ "$suite_status" -ne 0 ]; then
        caught=$((caught + 1))
        echo "CAUGHT       $name  (suite exit $suite_status)"
        printf '%s\n' "$report" | grep '^FAIL' | sed 's/^/               /'
    else
        missed=$((missed + 1))
        echo "SURVIVED     $name  (suite exit 0)"
    fi
}

echo
echo "-- workflow steps (tests/workflow-steps.sh)"
mutate_workflow "gate: pushes re-review PRs never reviewed"  's/\[ "\$ACTION" = synchronize \] && \[ "\$REVIEWED" != yes \]/[ "$ACTION" = synchronize ] \&\& [ "$REVIEWED" = never ]/'
mutate_workflow "gate: skipped head matched by prefix"      's/if \[ "\$HEAD_REF" = "\$skipped" \]/if [[ "$HEAD_REF" == "$skipped"* ]]/'
mutate_workflow "gate: bot PRs reviewed automatically"      's/\[ "\$AUTHOR_TYPE" = Bot \]/[ "$AUTHOR_TYPE" = NeverBot ]/'
mutate_workflow "gate: anyone's review counts as earlier"   '/reviews\?per_page=100" --paginate \\$/{n;s/select\(\.user\.login == "github-actions\[bot\]"\)/select(true)/;}'
mutate_workflow "outdated: warning added twice"             's/grep -qF .\[!WARNING\]./grep -qF NEVER-MATCHES/'
mutate_workflow "diff: cut without the warning"             '/This review is PARTIAL/d'
mutate_workflow "previous round: outsiders included"        '/fetch "replies from people"/,/fetch "replies at lines"/s/IN\("OWNER","MEMBER","COLLABORATOR"\)/true/'
mutate_workflow "publish: no fallback without line notes"   's/elif retry gh api "repos\/\$REPO\/pulls\/\$PR\/reviews" --input "\$RUNNER_TEMP\/review-no-notes.json"; then/elif false; then/'
mutate_workflow "publish: HUMAN label not added"            's/labels\[\]=ai:needs-human/labels[]=other/'
mutate_workflow "status: green without a published review" 's/if \[ "\$PUBLISHED" != success \]; then/if false; then/'

echo
echo "$caught caught, $missed survived or not applied"
[ "$missed" -eq 0 ]
