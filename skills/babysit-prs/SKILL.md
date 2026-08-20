---
name: babysit-prs
description: >
  Sweep ALL of the user's own open GitHub PRs and drive every one of them to a
  merge-ready state: answer/resolve new review comments by pushing fixes, resolve
  merge conflicts against the base, and repair failing CI. Designed to be re-run
  on a loop — each pass is idempotent and only acts on PRs with something new.
  Triggers on: "babysit my PRs", "make my PRs merge-ready", "resolve all the
  comments on my PRs", "keep my PRs green", "watch all my open PRs", "fix new
  review comments and conflicts", "/babysit-prs", "盯着我的 PR", "把我的 PR 都
  弄到可合并". For a single PR use devpilot:pr-guard; for reviewing OTHERS' PRs
  use devpilot:batch-review-prs.
---

# Babysit PRs — keep every one of my open PRs merge-ready

**Core principle:** your open PRs should never sit blocked on something a machine can fix.
Each pass answers three questions per PR — *did a reviewer say something new?*, *does it
conflict with its base?*, *is CI red?* — and remediates whichever is true. A PR with none
of the three is skipped untouched, which is what makes the skill safe to run on a loop
(`/loop /babysit-prs`, a cron, or repeated manual runs).

This skill is the multi-PR, own-PRs-only composition of two existing skills — reuse them,
do not restate their logic:

- **Conflicts + failing checks** → follow `devpilot:pr-guard` (its conflict gate, CI gate,
  hard stops, and never-force-push rules apply verbatim).
- **Replying to and resolving review threads** → follow `devpilot:resolving-review-threads`
  (reply first, resolve second, never resolve what you didn't fix).

**Operating mode: autonomous.** Assume nobody is watching. Push fixes and post replies
without asking. The only consent point is the first interactive invocation (Step 2); in
loop/auto mode there is none — that is the point of the skill, and the user opted in by
looping it.

## Context discipline

Discovery JSON, thread dumps, CI logs, and merge output stay inside subagents. The main
agent sees only: the compact PR table (Step 1), one result line per PR (Step 3), and the
final summary (Step 4). Do not run `gh api --paginate` loops or merges in the main context.

## Step 1: Discover (one subagent)

Dispatch **one** `general-purpose` subagent with the prompt below; it returns only a table.

**DISCOVERY PROMPT** (paste verbatim):

> Find my open GitHub PRs that need attention and return a compact table. No narration.
>
> **1. List my open PRs** (exclude drafts only if marked `[wip]` in the title — my own
> drafts still deserve green CI):
>
> ```bash
> gh api --paginate -X GET search/issues -f q='is:pr is:open author:@me' \
>   --jq '.items[] | {url, number, title, repo: (.repository_url | sub("^.*/repos/"; ""))}'
> ```
>
> **2. For each PR, gather state** (parallelize where easy):
>
> ```bash
> gh pr view "$url" --json mergeable,mergeStateStatus,headRefName,baseRefName,statusCheckRollup,reviewDecision,isDraft
> ```
>
> and count **actionable review threads** — unresolved threads whose *last* comment is not
> mine (i.e. a reviewer said something I haven't answered):
>
> ```bash
> me=$(gh api user --jq '.login')
> gh api graphql -f query='
>   query($owner:String!,$repo:String!,$num:Int!){
>     repository(owner:$owner,name:$repo){ pullRequest(number:$num){
>       reviewThreads(first:100){ nodes{ isResolved isOutdated
>         comments(last:1){ nodes{ author{ login } } } } } } } }' \
>   -f owner="$owner" -f repo="$repo" -F num="$number" \
>   --jq "[.data.repository.pullRequest.reviewThreads.nodes[]
>          | select(.isResolved == false)
>          | select(.comments.nodes[0].author.login != \"$me\")] | length"
> ```
>
> **3. Classify.** A PR **needs attention** when any of: actionable threads > 0;
> `mergeable == CONFLICTING` or `mergeStateStatus` in `DIRTY`/`BEHIND`; any *required*
> check failed. A PR that is clean, green, and has no unanswered threads is `idle` —
> including one blocked solely on a human approval (nothing for a machine to do there).
>
> **4. Locate local checkouts** for the surviving repos: try `../$repo_name`,
> `~/$repo_name`, `~/Works/github.com/*/$repo_name`; record the absolute path or
> `remote-only`. Run `git fetch origin` in found checkouts.
>
> **Return ONLY** a markdown table: `#`, `repo`, `pr`, `title`, `url`, `threads`
> (actionable count), `merge` (`OK`/`CONFLICT`/`BEHIND`), `ci` (`green`/`red`/`pending`/
> `none`), `local_path`, plus a final `idle: N PRs clean` line. If every PR is idle,
> return exactly: `ALL CLEAR`.

If the subagent returns `ALL CLEAR`, report "all your open PRs are merge-ready (or waiting
only on human review)" and stop — in loop mode this is the cheap no-op pass.

## Step 2: Confirm (interactive only)

Present the table. Interactively, ask which PRs to work; say plainly that fixes will be
**committed and pushed** to those branches and replies posted on threads. In **auto/loop
mode skip this step** and work every needs-attention PR.

## Step 3: Remediate (one PR at a time, sequentially)

For each needs-attention PR, dispatch one `general-purpose` agent and wait for it before
starting the next. Prompt template:

```
Agent({
  description: "Make owner/repo#123 merge-ready",
  subagent_type: "general-purpose",
  prompt: <the FIX PROMPT below, placeholders filled>
})
```

**FIX PROMPT** (paste verbatim, substituting placeholders):

> You have the `devpilot:pr-guard` and `devpilot:resolving-review-threads` skills
> available. Make my own PR `<url>` merge-ready. Work in `<local_path>`; if it is
> `remote-only`, you may only re-run flaky CI jobs and reply to threads — return
> `SKIP: remote-only` for anything needing an edit. Return only one result line.
>
> **Guards first** (all exits must restore the original checkout ref):
> - `git status --porcelain` non-empty → `SKIP: working tree dirty`.
> - `gh pr checkout <num>` fails → `SKIP: could not check out PR branch` (never `-f`,
>   reset, or delete-and-recreate).
> - Loop bound: `git fetch origin <base> --quiet;`
>   `git log origin/<base>..HEAD --grep='^Devpilot-Babysit:' --oneline | wc -l` ≥ 5
>   → `SKIP: babysit cap (N rounds)` — five automated rounds without convergence is a
>   human's problem, not a sixth round's.
>
> **A. Answer review threads.** Fetch unresolved threads whose last comment is not mine
> (same GraphQL as discovery, but include thread id, path, line, and full last-comment
> body). For each, read the surrounding code at HEAD, then:
> - **Fixable** (the comment identifies a concrete defect or asks a mechanical change,
>   and fixing it doesn't change the PR's intent, decide an unsettled design question,
>   or edit far outside the diff) → fix it in the working tree.
> - **Question** → reply with the technical answer; leave open unless the answer fully
>   settles it.
> - **Disagree / can't act** → reply stating exactly why (per
>   devpilot:resolving-review-threads); leave the thread open. Silence is never correct.
>
> **B. Resolve merge conflict / BEHIND** exactly per devpilot:pr-guard's conflict gate:
> `git merge origin/<base>`, resolve mechanical conflicts, never force-push, never rebase
> pushed history. A semantic conflict is a hard stop → include it in your result line.
>
> **C. Commit and push** (only if A/B changed files). Run the repo's test/lint commands
> first; never commit red — revert the failing hunk and move that finding to "replied,
> left open" instead. Stage only files you edited, by path. Commit message:
>
> ```
> fix: address review feedback / conflicts on #<num>
>
> <one line per change>
>
> Devpilot-Babysit: true
> ```
>
> Verify the trailer landed (`git log -1 --format=%B | grep -q '^Devpilot-Babysit:'`)
> before pushing — it is the loop bound. Plain `git push`; if it fails, stop and report,
> do not reply "fixed" against an unpushed commit.
>
> **D. Close out threads** via devpilot:resolving-review-threads: for each thread you
> fixed, reply naming the change and commit SHA, then resolve it. Post without asking.
>
> **E. CI.** After pushing (or if CI was the only issue), follow devpilot:pr-guard's CI
> gate and remediation loop, honoring all its hard stops.
>
> **Return ONLY one line:**
> `threads: fixed F / replied R / left L; merge: <ok|resolved|SEMANTIC CONFLICT>; ci: <green|red: reason|pending>; pushed <sha|nothing>`

Report each PR's result line as it completes.

## Step 4: Summary

```
## Babysit Summary

| PR | Link | Threads | Merge | CI | Pushed |
|----|------|---------|-------|----|--------|
| owner/repo#123 | [View](...) | fixed 2, replied 1 | ok | green | a1b2c3d |
| owner/repo#456 | [View](...) | — | SEMANTIC CONFLICT | — | — |

N PRs merge-ready, M blocked on a human (listed with the exact next action).
```

Every hard stop must name the specific human action needed (approve, decide conflict side,
supply secret). In loop mode, end the pass here — the next loop iteration re-discovers.

## Why it terminates on a loop

- Threads answered by me stop counting as actionable (last comment is mine), so a pass
  with no new reviewer activity finds `ALL CLEAR` and does nothing.
- The `Devpilot-Babysit` trailer caps automated fix commits at 5 per branch.
- CI remediation inherits pr-guard's bounded rounds and no-progress ceiling.

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Resolving a thread you only replied to | Only resolve threads whose fix is pushed |
| Force-push / rebase to clear a conflict | Merge base in — pr-guard's rule applies verbatim |
| Fixing a comment that asks for a design decision | Reply with the trade-off, leave open |
| Running discovery loops in the main context | One subagent returns the table only |
| Acting on PRs authored by others | This skill is own-PRs only, always |
| Counting a human-approval block as work | That's `idle` — report who must approve |
