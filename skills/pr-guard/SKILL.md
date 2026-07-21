---
name: pr-guard
description: >
  Use after a pull request or merge request exists to drive it to a mergeable,
  green state — poll CI/GitHub Actions until it passes, detect and resolve merge
  conflicts against the base branch, read failing-check logs, apply fixes, push,
  and re-poll in a bounded loop. Triggers on: "make CI pass", "watch the PR",
  "babysit the PR", "get this PR green", "fix the merge conflict", "is my PR
  mergeable", "wait for checks", "/pr-guard", "保证 CI 通过", "看着 PR 直到合并",
  "解决冲突", "盯着 actions". Hand-off target after devpilot:pr-creator.
---

# PR Guard — drive a PR to mergeable + green

**Core principle:** A PR is not "done" when it is created. It is done when it has **no merge
conflict with its base** and **every required check is green**. This skill watches, diagnoses,
and remediates until both hold — or until it hits a genuine hard stop and hands control back
with a precise report.

**Operating mode: autonomous remediation with bounded loops.** Do not stop to confirm routine
fixes (rebase onto base for a trivial conflict, correct a lint error, add a missing import,
re-run a flaky job once). Only stop for the cases under [Hard Stops](#hard-stops).

## Inputs

Resolve the target PR/MR first, in this order:
1. Explicit argument (`/pr-guard 123`, a PR URL, or a branch name).
2. The PR for the current branch: `gh pr view --json number,headRefName,baseRefName,mergeable,mergeStateStatus,url` (GitHub) or `glab mr view` (GitLab).
3. If none exists, stop — there is nothing to guard. Tell the user to create one first (`devpilot:pr-creator`).

Detect the platform from `git remote get-url origin` (github.com → `gh`, gitlab.com → `glab`).

## The loop

Run this cycle. Cap it at **a bounded number of remediation rounds (default 5)**; each round
must make measurable progress (a conflict resolved, a check fixed) or the round counts as a
no-progress round. **Two consecutive no-progress rounds → stop and report.**

```
1. Refresh state       →  fetch base, read PR mergeability + check statuses
2. Conflict gate       →  if not mergeable, resolve conflict (see below), push, restart loop
3. CI gate             →  wait for checks to finish; if all green → DONE
4. Diagnose failure    →  read the failing job's logs
5. Remediate           →  fix locally, commit, push
6. back to step 1
```

### 1. Refresh state

```bash
git fetch origin <base> --quiet
gh pr view <n> --json mergeable,mergeStateStatus,statusCheckRollup,headRefName,baseRefName
```

- `mergeable`: `MERGEABLE` / `CONFLICTING` / `UNKNOWN` (UNKNOWN = GitHub still computing; wait and re-poll).
- `mergeStateStatus`: `CLEAN`, `BLOCKED` (required review/check pending), `BEHIND` (base moved), `DIRTY` (conflict).

### 2. Conflict gate

If `mergeable == CONFLICTING` or `mergeStateStatus == DIRTY`:

```bash
git checkout <headRefName>
git fetch origin <base>
git merge origin/<base>        # prefer merge over rebase — never rewrite already-pushed history
```

- **Trivial / mechanical conflicts** (lockfiles, imports, non-overlapping hunks, generated files,
  changelog stacking): resolve them, `git add`, `git commit --no-edit`, `git push`. Restart the loop.
- **Semantic conflicts** where resolving means choosing between two real behaviors, or the same
  logical lines were changed on both sides with different intent → **Hard Stop**. Do not guess at
  business logic. Report exactly which files/hunks conflict and what the two sides do.
- `BEHIND` with no conflict: merging base in is safe and often required by "require branches up to
  date" rules — do it, push, restart.

**Never** `git push --force` / `--force-with-lease` on a shared PR branch, and never rebase a
branch whose commits are already on the remote. Merge the base in instead.

### 3. CI gate

```bash
gh pr checks <n> --watch           # blocks until all checks conclude; exit code != 0 if any fail
```

If `gh pr checks` is unavailable or the run is long, poll `statusCheckRollup` on an interval
instead of a tight loop. **Distinguish required vs optional checks** — only required (and
merge-blocking) checks must be green; note optional failures but do not loop on them.

All required checks green **and** mergeable → **DONE**. Report the PR URL and the green state.

### 4. Diagnose failure

For each failing required check:

```bash
gh run view <run-id> --log-failed         # only the failing steps
# or: gh pr checks <n>  → follow the details URL → gh run view
```

Read the actual error. Classify:
- **Flaky / infra** (network, timeout, runner died): re-run once (`gh run rerun <run-id> --failed`).
  A second flake of the same job is a no-progress round.
- **Real failure** (lint, type error, test assertion, build): go to step 5.
- **Config / secret / permissions** (missing secret, unauthorized, workflow needs approval):
  Hard Stop — the agent cannot supply secrets or approve workflow runs.

### 5. Remediate

Fix the root cause in the working tree — run the same command locally when you can (the repo's
lint/test command from CLAUDE.md/AGENTS.md/package.json/Makefile) to confirm the fix before
pushing. Commit with a conventional message (`fix: …`, `chore: …`) describing what CI caught.
Push to the PR branch. Return to step 1.

Keep fixes scoped to what CI flagged. If a fix would require a substantive design change or
touches code far from the diff, stop and report rather than sprawling.

## Hard Stops

Stop the loop and hand back a precise report when:
- **Semantic merge conflict** requiring a business-logic decision.
- **Missing secret / permission / workflow approval** — CI needs something only a human/repo-admin can grant.
- **Required human review** is the only thing blocking (`BLOCKED` with all checks green) — nothing to remediate; tell the user who needs to approve.
- **Test asserts intended-but-changed behavior** — fixing it would mean changing the feature's intent, not a mistake.
- **No-progress ceiling reached** (two consecutive rounds with no conflict resolved and no check fixed) or **round cap hit**.
- **Force-push would be required** to proceed — never do it; report why.

In autonomous mode (invoked by a parent skill), return the stop reason to the parent instead of blocking on human input.

## Report

Whether it finished green or hit a stop, end with:
- Final mergeability + per-check status (✅/❌, required vs optional).
- What you changed and why (commits pushed, conflicts resolved), with commit SHAs.
- For any remaining red/blocked item: the exact failing log excerpt and the specific next action a human must take.
- The PR URL.

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Force-pushing to "fix" a conflict or bad commit | Merge base in; never rewrite pushed history |
| Rebasing a branch whose commits are already on origin | Use `git merge origin/<base>` instead |
| Guessing at a semantic conflict resolution | Hard Stop — report both sides, let a human decide |
| Looping forever on a flaky job | Re-run once; a second flake is a no-progress round |
| Treating optional check failures as blocking | Only required/merge-blocking checks gate DONE |
| Reading full CI logs | Use `gh run view --log-failed` — only failing steps |
| Reporting "CI passed" from an in-progress run | Wait for checks to *conclude* (`--watch`) before claiming green |
| Fixing far outside the diff to satisfy a test | Keep fixes scoped; sprawling fix → Hard Stop |
