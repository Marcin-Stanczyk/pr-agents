#!/usr/bin/env bash
#
# Creates the labels used by the agent review workflow.

set -euo pipefail

command -v gh >/dev/null 2>&1 || { echo "gh CLI not found: https://cli.github.com"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Not logged in: run 'gh auth login'"; exit 1; }

REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
echo "Repository: $REPO"
echo

make_label() {
    if gh label create "$1" --description "$2" --color "$3" --repo "$REPO" >/dev/null 2>&1; then
        echo "  created  $1"
    elif gh label edit "$1" --description "$2" --color "$3" --repo "$REPO" >/dev/null 2>&1; then
        echo "  updated  $1"
    else
        echo "  FAILED   $1"
    fi
}

make_label "ai:review"      "Run the agent review (default model)"          "0E8A16"
make_label "ai:review-opus" "Run the agent review (stronger model)"         "5319E7"
make_label "ai:needs-human" "Agent review: a person has to decide (HUMAN)"  "FBCA04"

echo
echo "Done. Next:"
echo "  1. install the Claude GitHub App:  https://github.com/apps/claude"
echo "  2. add the secret:                 gh secret set CLAUDE_CODE_OAUTH_TOKEN"
echo "  3. copy the files:                 see Setup in README.md"
