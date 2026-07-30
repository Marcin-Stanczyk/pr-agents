# pr-agents

Three GitHub Actions workflows that put Claude on your pull requests: **a
reviewer, a fixer and a task agent** — each started deliberately, none of them
able to run away with your budget.

```bash
cp workflows/*.yml .github/workflows/
./setup-labels.sh
```

Plus one repository secret. Details below.

The name is provider-neutral on purpose; the current implementation is built on
[`claude-code-action`](https://github.com/anthropics/claude-code-action), which is
why the workflow files say `claude-`.

---

## What you get

| Workflow | What it does | How it starts |
|---|---|---|
| `claude-review.yml` | reviews a PR, posts inline notes, sets a status check | PR opened, or the `ai:review` label |
| `claude-fix.yml` | applies the review, or exactly what you asked for | `ai:fix` label, or `@claude ...` in a comment |
| `claude-task.yml` | turns an issue into a pull request | `ai:task` label, or `@claude ...` on an issue |

Sonnet by default everywhere. Opus on an explicit label (`ai:review-opus`,
`ai:fix-opus`, `ai:opus`) — cheaper by default, more expensive only when you ask.

## Setup

**1. Install the Claude GitHub App** — https://github.com/apps/claude → *Only
select repositories*. Requires admin on the repository.

You may not strictly need it if `github_token` is passed explicitly (these
workflows do), but installing it removes a variable and costs nothing.

**2. Add one secret.** Either works:

```bash
# a Claude subscription — draws on the same limits your terminal uses
claude setup-token
gh secret set CLAUDE_CODE_OAUTH_TOKEN

# or an API key — bills separately, can never throttle your own work
gh secret set ANTHROPIC_API_KEY
```

If you use an API key, swap `claude_code_oauth_token:` for
`anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}` in all three files.

**Which to pick:** if you are already bumping into your subscription's weekly
limits, use the API key. A correctly configured review cost roughly \$0.18 when
measured on 2026-07-30 — paying that separately buys certainty that an agent can
never block your own work mid-task.

**3. Copy the workflows and create the labels.**

```bash
cp workflows/*.yml .github/workflows/
./setup-labels.sh
```

**4. Edit `BASE_BRANCH`** at the top of `claude-task.yml` if your repository does
not develop on `main`.

## The design, and why it is this way

### There is no automatic loop, on purpose

The obvious next idea is a loop: reviewer finds problems → fixer fixes them →
reviewer checks again. We built that and then removed it.

**Events caused by `GITHUB_TOKEN` do not start new workflow runs.** That is a
GitHub guard against a workflow triggering itself forever. So the fixer's push
does not wake the reviewer, and a real loop needs your own GitHub App to get past
that guard — at which point you have *disabled the safety mechanism* and have to
write your own round counter to replace it.

That complexity only pays off once you trust the reviews. Until then, every round
costs money, so every round should be a decision. **You are the loop.**

### Labels are buttons, not states

Every label is removed once its run starts, so you can click it again without
unsticking it first. `ai:review` after a fix, `ai:fix` after a second reading —
the same button, as many times as you need.

### The gate is a status check, not an approval

If the same agent both opened a PR and approved it, GitHub would reject that as
self-approval. So the reviewer sets a commit status called `agent-review` that you
can require in branch protection. It sidesteps the question entirely and works the
same whether the PR was opened by a human or by the task agent.

**A missing verdict is a failure, never a pass.** If the agent does not finish and
writes no verdict file, the status goes red. Not knowing must not open the way to
production.

### The agent writes files, the workflow publishes them

The reviewer does not call the GitHub API. It writes three files, and a plain
workflow step turns them into a review.

This was not the first design. Asking the agent to post its own comment cost
\$1–2.40 per run and kept failing on tool permissions. Moving publication into a
`gh api` call dropped a real run to **6 turns and \$0.18**, because the model now
does only the part that needs a model.

### Findings land on the lines they refer to

`.agent-notes.json` becomes inline review comments, so you read them in the file
view rather than scrolling a conversation.

The GitHub API rejects the **entire** review if any line number falls outside the
diff, so there is a fallback: on rejection the workflow publishes the review body
without the pins. A bad pin should cost you a pin, not the whole review.

## Traps we hit, so you do not have to

These cost five failed runs to find. All of them are already handled in the
workflows here — this section is for when you adapt them.

**`id-token: write` is required.** Without it the action fails with `Could not
fetch an OIDC token` before it ever reaches the model.

**`--allowedTools` must contain no spaces.** A value like
`Bash(git diff:*)` splits on the space, the list arrives **empty**, and empty
means *nothing is allowed* — every tool call is denied and the run burns its whole
turn budget hitting closed doors. Use `Bash(git:*)`.

**Grant the tools your prompt asks for.** If the prompt says "run `git diff` and
write a file", the agent needs `Bash(git:*)` and `Write`. Otherwise it spends
turns discovering it cannot, and finishes with nothing.

**Pass `github_token` explicitly.** Otherwise the action tries to exchange a token
through the Claude GitHub App and fails with `401 Unauthorized — Claude Code is
not installed on this repository`.

**A path-filtered workflow makes a poor required status check.** If your test
workflow only runs on certain paths, requiring it in branch protection blocks
every PR that does not touch those paths — the check never reports, so it never
passes. This is the fastest way to brick your own merge button.

**Restrict the reviewer with token permissions, not tool patterns.** The reviewer
job has `contents: read`, so it cannot push regardless of which shell commands it
is allowed to run. That is a stronger guarantee than an allowlist pattern.

## Cost

**All figures measured 2026-07-30.** Model prices change — treat them as an order
of magnitude, not a quote, and re-measure before budgeting.

Measured on a real repository, Sonnet, one-file PR: **6 turns, 53 seconds, \$0.18
equivalent.** A large PR costs several times that; Opus roughly 2.5× Sonnet, based
on list prices on that date.

GitHub Actions minutes are effectively free at this scale — a run takes a few
minutes against an allowance of thousands.

The lever that matters most is not the model, it is **how much you feed it**. The
prompts here review the diff, not the repository.

If you authenticate with a subscription rather than an API key, the reported
dollar figure is an *equivalent*, not a charge — what you actually spend is quota
from the same pool your own sessions use.

## Emergency stop

```bash
gh workflow disable "Claude — review PR"
gh workflow disable "Claude — fix after review"
gh workflow disable "Claude — task from issue"
```

## Requirements

A repository where you can add secrets and workflows. `jq` and `gh` are present
on GitHub-hosted runners by default.

## License

MIT
