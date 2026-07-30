#!/usr/bin/env bash
#
# Creates the labels the workflows react to.
#
# They are buttons, not states: each one is removed as soon as its run starts, so
# you can click the same label again without unsticking it first.

set -euo pipefail

command -v gh >/dev/null 2>&1 || { echo "gh CLI not found: https://cli.github.com"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Not logged in: run 'gh auth login'"; exit 1; }

REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
echo "Repository: $REPO"
echo

make_label() {
    if gh label create "$1" --description "$2" --color "$3" --repo "$REPO" >/dev/null 2>&1; then
        echo "  created  $1"
    else
        gh label edit "$1" --description "$2" --color "$3" --repo "$REPO" >/dev/null 2>&1 \
            && echo "  updated  $1" \
            || echo "  FAILED   $1"
    fi
}

make_label "ai:review"      "Review this PR (Sonnet)"        "0E8A16"
make_label "ai:review-opus" "Review this PR (Opus)"          "5319E7"
make_label "ai:fix"         "Apply the review (Sonnet)"      "FBCA04"
make_label "ai:fix-opus"    "Apply the review (Opus)"        "D93F0B"
make_label "ai:task"        "Agent should do this issue"     "1D76DB"
make_label "ai:opus"        "Task: use Opus instead"         "5319E7"

echo
echo "Done. Next:"
echo "  1. install the Claude GitHub App:  https://github.com/apps/claude"
echo "  2. add the secret:                 gh secret set CLAUDE_CODE_OAUTH_TOKEN"
echo "  3. copy the workflows:             cp workflows/*.yml .github/workflows/"
