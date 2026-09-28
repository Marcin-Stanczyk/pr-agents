# pr-agents

A quality gate for pull requests, run in GitHub Actions: **one AI reviewer**
with its own small set of tools and deliberately limited, read-only access.
It reads the change, can run a committed test file, and publishes a review plus
an `agent-review` commit status you can require before merging.

It does not write code. There used to be a fixer and a task agent here; they are
gone, and [Why there is no coding agent](#why-there-is-no-coding-agent) explains
why.

What it is good at, as a gate in CI:

- **finding problems** in the diff, each with a concrete failure scenario;
- **another angle**: an alternative approach, or a risk the author most likely
  did not consider;
- **broader test coverage**: a list of concrete scenarios the PR's tests do not
  cover, written as `input -> expected outcome`.

The current implementation runs on
[`claude-code-action`](https://github.com/anthropics/claude-code-action). The
repository name stays provider-neutral.

---

## Setup

**1. Add one secret.** Either works:

```bash
# a Claude subscription: draws on the same limits your terminal uses
claude setup-token
gh secret set CLAUDE_CODE_OAUTH_TOKEN

# or an API key: billed separately, can never throttle your own work
gh secret set ANTHROPIC_API_KEY
```

With an API key, replace `claude_code_oauth_token:` in the workflow with
`anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}`. If you already hit your
subscription's weekly limits, use the API key.

Installing the [Claude GitHub App](https://github.com/apps/claude) is optional:
the workflow passes `github_token` explicitly.

**2. Copy the files and create the labels.**

```bash
mkdir -p .github/workflows .github/scripts
cp workflows/agent-review.yml .github/workflows/
cp scripts/review-*.sh .github/scripts/
./setup-labels.sh
```

**3. Configure the `env:` block** at the top of `agent-review.yml`:

| Variable | Default | Meaning |
|---|---|---|
| `TEST_COMMAND` | empty | Full test suite, run in a separate read-only job. Its result is handed to the reviewer. Empty: the reviewer is told there are no test results. |
| `TEST_RUNNER` | empty | Command that runs ONE test file, e.g. `npx vitest run`, `php vendor/bin/phpunit -c phpunit.xml`, `python -m pytest`. Split on spaces, no shell. Empty: the reviewer cannot run anything. |
| `TEST_FILE_GLOB` | `tests/*` | Bash pattern a test path must match (`*` also matches `/`). |
| `REVIEW_SETUP_COMMAND` | empty | Installs dependencies for `TEST_RUNNER` in the review job. **Must not run code from the PR**: use `npm ci --ignore-scripts`, `composer install --no-scripts --no-plugins`. |
| `SKIP_HEAD_BRANCHES` | empty | Space-separated head branches whose PRs are never reviewed, e.g. `stage` for `stage -> prod` promotion PRs. |
| `DIFF_LINE_LIMIT` | `4000` | Longer diffs are cut; the reviewer is told the review is partial. |
| `MODEL_DEFAULT` / `MODEL_ON_LABEL` | Sonnet / Opus | Model for normal runs and for the `ai:review-opus` label. |

If `TEST_COMMAND` needs a toolchain, add the setup step (`actions/setup-node`,
`setup-python`, ...) in the `tests` job where the workflow marks it. For
`TEST_RUNNER`, add the same setup to the `review` job before
`REVIEW_SETUP_COMMAND`.

**4. Optionally require the status.** In branch protection, require
`agent-review`. Read [the trap about skipped PRs](#traps-we-hit) first: a PR the
gate skips never gets the status.

## How a review runs

| Event | Reviewed? |
|---|---|
| PR opened, or marked ready for review | yes (drafts never) |
| label `ai:review` / `ai:review-opus` | yes, Sonnet / Opus; the label is removed afterwards so it can be clicked again |
| push to the PR | **only if the PR was already reviewed**; a push then means "the author answered the review" |
| PR edited | only when the base branch changed (a retargeted PR gets no other event) |
| PR by a bot (Dependabot, ...) | only with the label |
| head branch in `SKIP_HEAD_BRANCHES` | never, not even with the label |

Three jobs:

1. **gate**: a few seconds of `gh api`, no model. Decides whether this event
   needs a review and whether the PR was reviewed before (`yes`, `no`, or
   `unknown` when the API did not answer; `unknown` is never presented to the
   reviewer as "first round").
2. **tests**: runs `TEST_COMMAND` on the PR's code with a `contents: read` token
   and no secrets, and hands the result over as `.agent-tests.md`.
3. **review**: sets `agent-review` to *pending*, marks earlier reviews as
   outdated, prepares the reviewer's input, runs the agent, publishes, and sets
   the final status.

**Rounds.** The previous review, the reviewer's line notes, and replies from
people with write access go into `.agent-previous-round.md`. The next round is
told the code is already after those fixes, and must check that each fix does
what was asked, that nothing next to it changed meaning, and must not repeat
resolved findings. A "To verify locally" point that a person answered with a
measurement counts as closed. Earlier reviews get an **Outdated** banner, so an
old PASS does not read as approval of new commits; `ai:needs-human` from the
previous round is removed while the new one runs.

**Concurrency.** Clicking a review label cancels a review in progress. A push
does not: it waits. Cancelling on push deadlocked. A push during the *first*
review cancelled it before anything was published, and the replacement run's
gate then saw "never reviewed" and skipped, leaving the PR with no review at all.
Events that never start a review (other labels, title edits) get their own
concurrency group, so they cannot replace a queued review.

## What the reviewer sees, and what it cannot do

It gets, precomputed by the workflow:

- `.agent-diff.patch`: the whole diff against the base branch;
- `.agent-previous-round.md`: see Rounds above;
- `.agent-tests.md`: the test suite result on this commit, or a plain statement
  that there is none.

| Capability | Reviewer |
|---|---|
| Commit or push | **No.** The job token has `contents: read`, and there is no git tool. This is the enforcement: a future "fix it too" step fails on permissions instead of quietly adding commits. |
| Comment on the PR | No. It writes files; a plain workflow step publishes them. |
| Write files | Only `.agent-*` in the repository root (`Edit(/.agent-*)` permission rule). |
| Read files | Yes, the checkout (`Read`, `Glob`, `Grep`). |
| Run commands | Only the wrapper: one committed test file per call. No git, no interpreters, no package managers. |
| Network | No tool for it (`WebFetch`, `WebSearch` disallowed; no shell). |
| Tokens while tests run | Stripped from the environment by the wrapper. |
| Production data, servers, third-party code not in the repo | None. The prompt tells it not to guess these and to ask instead (see "To verify locally"). |

### The single-test wrapper

A `Bash(tool:*)` allowlist entry does not restrict arguments, and most test
runners accept flags or config that load arbitrary code before any test runs
(`phpunit --bootstrap`, `node --require`, a rewritten `vitest.config`). In an
earlier setup this was confirmed by execution: `--bootstrap` pointing at a
substituted file ran foreign code. Together with a Write tool that is a path from
**text in a diff** (which the agent reads as untrusted input) to **code execution
in a job that holds tokens**, and a published review is a ready exfiltration
channel. Running committed code is what CI does anyway; turning text into code
is not.

So the reviewer's only command is `review-run-test.sh`, installed by
`review-test-install.sh` outside the working tree, read-only, before the agent
starts. It:

- takes exactly one argument, never a flag, never an absolute path, no `.` or
  `..` segments, only `[A-Za-z0-9._/@+-]`;
- runs only a path matching `TEST_FILE_GLOB` that was **committed at HEAD and
  unchanged** when the review started;
- refuses if **any file in the working tree** changed since then, including
  git-ignored ones (`node_modules/`, `vendor/`), runner configs, files replaced
  by rename, and `.git/hooks` / `.git/info`; only the reviewer's root-level
  `.agent-*` files are exempt;
- runs the test with an environment reduced to `PATH HOME USER LANG LC_ALL TZ
  TMPDIR CI`, so test code does not see the job's tokens.

`tests/run-test-wrapper.sh` proves each refusal against a throwaway repository,
and `tests/mutation-check.sh` breaks each guard in turn and requires the tests to
fail.

What it does not cover:

- **`.git/config`** is not in the snapshot, because `claude-code-action` may
  write it after the snapshot is taken. Committed test code that runs `git`
  would read a tampered config. The `Edit(/.agent-*)` rule is what keeps the
  agent from writing there.
- **The PR's own workflow file runs**, not the base branch's (GitHub behaviour
  for `pull_request`). A PR can loosen its own reviewer. Protect `.github/` with
  CODEOWNERS and human review.
- Committed test code runs as the runner user and can read what that user can
  read, like any CI job.

## What a review contains

The published review starts with the verdict and the commit it describes, then:

- **Findings**: numbered one-line titles, so people can refer to them by number.
  Details are line notes pinned to the diff. Every finding has a concrete failure
  scenario, or it is left out. A finding is treated as a pattern: the reviewer
  searches the diff for the same shape and lists every occurrence, because
  authors fix exactly what is pointed at.
- **To verify locally**: what the reviewer cannot check (production values,
  third-party schemas, external services). Each item says what to check and
  which result means a problem.
- **Another angle**: at most three concrete alternatives or overlooked risks.
- **Untested scenarios**: `input or situation -> expected outcome` cases the
  PR's tests do not cover.

Empty sections are omitted; an empty review is a valid result. Prose is capped
at four sentences, and summaries of what the PR changes are forbidden: the
reader has the diff.

| Verdict | Meaning | `agent-review` status |
|---|---|---|
| PASS | nothing here will break | success |
| FAIL | at least one finding | failure |
| HUMAN | a design or business decision; one concrete question; adds `ai:needs-human` | failure |
| none | the agent did not finish, or publishing failed | failure |

PASS may not hide an unverified point: if confirming a "To verify locally" item
would turn the verdict into FAIL, the verdict is HUMAN.

## Why there is no coding agent

This repository started with three agents: a reviewer, a fixer that applied the
review, and a task agent that turned issues into PRs. The same design ran on a
production shop's repository. Both dropped the fixing half. What happened:

**The fixer silently disabled a payment gate.** On its first real run it removed
a status prefix from an order query. That query was the guard that stops a
deploy while customers are mid-transaction. The change looked reasonable in the
diff. Only a second review round caught it and put the prefix back. With one
round, that PR would have carried a broken payment gate under a green verdict.

**A PASS described a fix that was not in the tree.** The review quoted the
corrected line and explained why it was now right. The line actually in the
tree still read `REGEXP 5xx`, unquoted, which MySQL rejects with `ERROR 1054`.
The reviewer had read an earlier state, and nothing in its output said so.

**The review described the state before its own fixes.** In the pipeline where
fix steps committed to the PR branch, the PASS comment was published after the
fix commits and looked as if it covered them. It had been written before them.

**The fixes came without tests.** On the run that settled it, both automated
fixes could be reverted without a single test in the suite failing. Nothing
protected them.

**Nobody asked for those changes.** Authors found extra commits in their
branches after the fact. Those same two fixes were correct, and one even caught
a file the human had missed. Quality was not the problem. The
problem was who changes the repository.

**With the access a CI agent should have, it cannot verify its own work.** The
owner's reason for dropping the idea: an agent in CI gets limited, safe access by
design. It has no production data, no server, no way to run the application the
way users do. That is enough to find problems and propose scenarios. It is not
enough to make a change and prove it correct. A coding agent under those limits
produces changes nobody can trust without redoing the work.

So the agent reviews, and people (or a local agent with real access) change the
code. `contents: read` on the review job is both the consequence and the
enforcement.

One habit survives from the fixer days: **check a review's claim against the
file, not against the review.**

```bash
git show HEAD:path/to/file | grep -n 'the thing the review says is fixed'
```

## Traps we hit

**`id-token: write` is required.** Without it the action fails with `Could not
fetch an OIDC token` before reaching the model.

**An unquoted space splits `--allowedTools`.** `Bash(git diff:*)` unquoted
arrives as an empty list, and empty means *nothing is allowed*: every tool call
is denied and the run burns its turns on closed doors. Quote entries with spaces,
as the wrapper entry is quoted.

**Grant exactly the tools the prompt asks for.** If the prompt says "write a
file" and `Write` is not allowed, the agent spends turns discovering that and
ends with nothing.

**Pass `github_token` explicitly.** Otherwise the action exchanges a token
through the Claude GitHub App and fails with `401 Unauthorized — Claude Code is
not installed on this repository`.

**A required status that is never reported blocks merging.** A path-filtered
test workflow made required bricks every PR outside those paths. The same holds
here: PRs the gate skips (drafts, `SKIP_HEAD_BRANCHES`, bot PRs without the
label) never get `agent-review`. Do not require it on the branch promotion PRs
target, and label bot PRs you want to merge.

**The Actions token cannot approve.** `event: APPROVE` returns `422 — Can not
approve your own pull request`, after the model has done the work. Reviews are
published as `COMMENT`; the verdict branch protection reads is the status.

**A COMMENT review cannot be dismissed.** Only APPROVED / CHANGES_REQUESTED can.
The outdated banner is written by editing the body, and editing a review body is
`PUT .../reviews/{id}`; `PATCH` returns 404.

**Events caused by `GITHUB_TOKEN` start no workflows.** Labels and comments the
review adds never trigger anything, so there is no loop. The flip side: a failed
review cannot retry itself. Add the label again.

**`pull_request` runs the PR branch's copy of the workflow.** A fix step was
switched off on the production branch only. PRs from the development branch
kept running the old, unconditional copy, and it surfaced as commits nobody
expected. Change the workflow on every long-lived branch.

**`upload-artifact` skips dotfiles.** Since v4.4 `include-hidden-files` defaults
to false. `.agent-tests.md` never uploaded, the job stayed green with a warning,
and the reviewer wrote in its verdict that there were no test results while the
tests were passing. `if-no-files-found: error` turns the next such slip red.

**Dotfiles that are git-ignored are invisible to search.** Measured with the
agent's own tools: directory search does not list `.agent-*` files, opening them
by path does. The prompt tells the agent to open them by name, and to pass the
path explicitly when searching inside them.

**`gh api --paginate --jq` filters each page separately.** With two pages,
`last` returns two lines. Slurp all pages with `jq -s` first.

**One bad line pin rejects the whole review.** GitHub refuses the review if any
note points outside the diff. The workflow retries without pins, then as a plain
comment. A bad pin costs a pin, not the review.

**Invalid JSON from the agent sank a finished review.** A syntax error in the
notes file made `jq` fail the publish step under `set -e`, with the verdict and
text ready. The notes are validated first and dropped with a visible remark if
broken.

## Design choices worth keeping

**The agent writes files; the workflow publishes them.** Asking the agent to post
its own comment cost $1–2.40 per run and kept failing on tool permissions. Moving
publication into a `gh api` step dropped a real run to 6 turns and $0.18,
because the model only does the part that needs a model.

**The diff is precomputed.** An agent that fetches its own diff spends its turn
budget before reading any code.

**A missing verdict is a failure, never a pass.** Green requires a PASS file, a
review text, and a successful publish.

## Cost

**Measured 2026-07-30, on the earlier single-agent design** (diff only, no test
results, no previous round): Sonnet, one-file PR, **6 turns, 53 seconds, $0.18
equivalent**. A large PR costs several times that; Opus roughly 2.5× Sonnet at
that date's list prices.

The current design reads more (test results, the previous round) and may run
tests, so expect more than that figure. It has not been re-measured. Measure on
your own repository before budgeting. Prices change.

The biggest lever is not the model but how much you feed it: the reviewer reads
the diff, not the repository. With a subscription token, the dollar figure is an
equivalent; what you spend is quota from the pool your own sessions use.

## Emergency stop

```bash
gh workflow disable "Agent review"
```

If `agent-review` is a required status, disabling the workflow blocks merging:
remove the requirement in branch protection at the same time.

## Files

| Path | Installed as |
|---|---|
| `workflows/agent-review.yml` | `.github/workflows/agent-review.yml` |
| `scripts/review-test-install.sh` | `.github/scripts/review-test-install.sh` |
| `scripts/review-run-test.sh` | `.github/scripts/review-run-test.sh` |
| `scripts/review-tree-state.sh` | `.github/scripts/review-tree-state.sh` |
| `setup-labels.sh` | run once |
| `tests/` | this repository's own checks, not installed |

## Checks for this repository

`.github/workflows/ci.yml` runs all of these:

```bash
actionlint workflows/*.yml .github/workflows/*.yml
shellcheck --severity=style setup-labels.sh scripts/*.sh tests/*.sh
bash tests/lint-run-blocks.sh      # bash -n + shellcheck on every run: block
bash tests/run-test-wrapper.sh     # what the wrapper accepts and refuses
bash tests/workflow-steps.sh       # workflow step decisions, against a fake gh
bash tests/mutation-check.sh       # each guard broken in turn; the tests must fail
```

## License

MIT
