---
name: batch-review-prs
description: "Use this skill whenever the user wants to check their review queue, see pending reviews, review all their PRs, says 'review my PRs', 'check my review inbox', 'what PRs need my review', 'review everything assigned to me', or any variation of batch-reviewing pending pull requests. Also trigger when the user says /batch-review-prs or /review-inbox, or asks to review and fix their own PRs. Even if the user just says 'review my stuff' or 'catch up on reviews', this skill likely applies."
---

# Batch Review PRs

Discovers all open PRs that need your review on GitHub — ones requesting you, ones you've reviewed
before, **and your own** — and reviews them via `devpilot:pr-review`. On **your own** PRs it does
not stop at the review: it applies the findings it just posted, pushes the fix, and closes the
threads it fixed (Step 3.5). A review you wrote against your own work is a to-do list you already
have the answers to; leaving it unactioned is the waste this skill exists to remove.

Needs only `gh`. Adds claim labels, opt-in GitHub Project queue sync, already-reviewed-at-HEAD
filtering, local-checkout syncing, and the self-authored auto-fix pass. This is the single
review-queue skill — the older
`pr-review-queue` (which discovered the queue via `devpilot github prs review-queue`) was removed
as a duplicate.

## Context discipline (read first)

Discovery, filtering, and repo-sync produce large volumes of raw `gh api` JSON, per-PR loop output, and `git fetch` noise. **None of that belongs in the main agent's context.** The main agent should only ever see:

1. The compact PR table returned by the discovery subagent (Step 1).
2. Per-PR review results (Step 3).
3. Per-PR fix results for self-authored PRs (Step 3.5) — one line each, never a diff.
4. The final summary (Step 4).

So the entire discover → filter → repo-sync pipeline runs inside **one** subagent (Step 1), which returns only a small structured table. Labeling is folded into each review dispatch (Step 3) so it never runs in the main context either. Do **not** run the `gh api --paginate` loops or `git fetch` calls directly in the main agent.

### Step 1: Discover, filter, and prep (single subagent)

Dispatch **one** `general-purpose` subagent to do all discovery, filtering, and local-repo syncing, and to return only a compact list. This keeps every raw JSON blob and loop iteration out of the main context.

```
Agent({
  description: "Discover & prep review-inbox PRs",
  subagent_type: "general-purpose",
  prompt: <the DISCOVERY PROMPT below>
})
```

**DISCOVERY PROMPT** (paste verbatim into the subagent):

> Discover the open GitHub PRs that need my review, filter them, sync local repos, and return a compact table. Do all of this yourself — do not summarize your reasoning, just return the final list. Steps:
>
> **1. Discover.** Run three search queries with `gh api --paginate` and union/dedup by URL:
>
> ```bash
> for q in 'is:pr is:open review-requested:@me' \
>          'is:pr is:open reviewed-by:@me' \
>          'is:pr is:open author:@me'; do
>   gh api --paginate -X GET search/issues -f q="$q" \
>     --jq '.items[] | {url, number, title, repo: (.repository_url | sub("^.*/repos/"; "")), draft, user_login: .user.login, user_type: .user.type}'
> done
> ```
>
> `repository_url` is an API URL (`https://api.github.com/repos/OWNER/REPO`), so strip the prefix
> to get the `OWNER/REPO` slug. Every later step uses that slug directly as `$repo` — there is no
> separate `$owner` variable. For the local-checkout probe you need the bare repo name:
> `repo_name="${repo##*/}"`.
>
> - `review-requested:@me` — explicitly requested reviewers.
> - `reviewed-by:@me` — PRs you've previously reviewed (GitHub drops you from the requested list after you submit, so updated PRs only show here).
> - `author:@me` — your own PRs. Mark these `(self)`; they are reviewed like any other PR but
>   **published as `COMMENT`, never `APPROVE`** — GitHub rejects self-approval with a 422 and the
>   whole review post fails. The `self` flag must survive into the returned table (see step 4)
>   because the reviewing agent in Step 3 has no other way to know.
>
> **2. Filter out:**
> - Draft PRs — **except self-authored ones**. Your own drafts are kept: a `COMMENT`-only pass over
>   your own work-in-progress is exactly what this skill is for, and dropping them is the most
>   common reason a self-authored PR silently never appears in the queue. Others' drafts are still
>   dropped (they have not asked for review yet).
> - Bot PRs (author type `Bot` or login containing `[bot]`).
> - **Already reviewed at current HEAD SHA.** For each candidate, in parallel:
>   ```bash
>   head_sha=$(gh api "repos/$repo/pulls/$number" --jq '.head.sha')
>   gh api --paginate "repos/$repo/pulls/$number/reviews" \
>     --jq ".[] | select(.commit_id == \"$head_sha\") | select((.body // \"\") | test(\"devpilot:pr-review\"))" | head -1
>   # Non-empty → drop (already reviewed at HEAD).
>   ```
>   This compares by `commit_id`, not `updatedAt`, so a force-push/rebase (new SHA) correctly does NOT skip.
>
>   `(.body // "")` is required, not defensive noise: a bare APPROVE carries a `null` body, and
>   `null | test(...)` is a hard jq error that aborts the whole paginated pipeline for that PR.
>   Without the fallback, one uncommented approval anywhere in a PR's review list empties the
>   output and the PR reads as never-reviewed — the filter fails permissive and re-reviews it.
>
>   The body match anchors on the machine marker `devpilot:pr-review` that `devpilot:pr-review`
>   emits in its review body (leading `<!-- devpilot:pr-review (devpilot <version>) -->` and the
>   trailing `Generated by devpilot:pr-review (...)` metadata comment — see
>   `skills/pr-review/references/template.md`). If that marker ever changes, this filter goes
>   silently permissive and every PR gets re-reviewed on each run.
> - **Already claimed by ≥2 other reviewers — self-authored PRs are exempt.** Two teammates
>   claiming someone else's PR means it has coverage; on *your own* PR it means nothing about
>   whether you have self-reviewed it, so never drop a `(self)` PR for this reason. Resolve my first name from the gh-authenticated user (handles `First Last`, `Last, First`, and login fallback):
>   ```bash
>   raw=$(gh api user --jq '.name // .login')
>   if [[ "$raw" == *,* ]]; then
>     first_name=$(echo "$raw" | awk -F',' '{print $2}' | awk '{print tolower($1)}' | tr -cd 'a-z0-9')
>   else
>     first_name=$(echo "$raw" | awk '{print tolower($1)}' | awk -F'[-_]' '{print $1}' | tr -cd 'a-z0-9')
>   fi
>   others=$(gh api "repos/$repo/pulls/$number" \
>     --jq "[(.labels // [])[].name | select(startswith(\"reviewing:\")) | select(. != \"reviewing:$first_name\")] | length")
>   # others >= 2 AND not self-authored → drop (enough coverage).
>   ```
>   Exclude my own `reviewing:$first_name` from the count so re-runs don't skip PRs I already claimed.
>
> **3. Sync local repos.** For each unique surviving repo, check these locations in order and use the first match: `../$repo_name`, `~/$repo_name`, `~/Works/github.com/*/$repo_name`. If found, run `git fetch origin` inside it and record the absolute path. If not found, record `remote-only`. (A local checkout lets `devpilot:pr-review` read surrounding code context instead of the diff alone.)
>
> **4. Sync the optional GitHub Project queue.** Read
> `devpilot:pr-review`'s `references/project-board.md`, resolve its verified wrapper once, and run
> `sweep-closed` once per distinct configured Project before queueing candidates. The sweep archives
> merged/closed PR items left by interrupted reviews; it must never archive open PRs or ordinary
> issues. Then set every surviving PR to `Waiting to be picked up`. Run from the PR's `local_path` so its
> `git config devpilot.reviewProject` is visible; for `remote-only`, sync only when
> `DEVPILOT_REVIEW_PROJECT` is set. A missing configuration means `not configured`, not an error.
> A sweep/wrapper/scope/API failure is non-fatal: retain the PR, record the exact short error as its
> board result, and continue. Do not run the sweep more than once for PRs sharing one Project. This
> step deliberately requeues a previously reviewed PR whose head SHA moved.
>
> **Return ONLY this** — no logs, no JSON dumps, no narration:
> - The resolved `first_name` (the reviewer's, for labeling).
> - A markdown table with columns: `#`, `repo` (owner/repo), `pr` (number), `author` (append `(self)` for self-authored), `self` (`yes` / `no`), `title`, `url`, `local_path` (absolute path or `remote-only`), and `board` (`Waiting`, `not configured`, or the short sync error).
>   The explicit `self` column is not redundant with the `(self)` suffix — Step 3 reads it to decide
>   the review event cap, and Step 3.5 reads it to decide whether the PR gets an auto-fix pass.
>   `local_path` is likewise load-bearing twice: it gives the reviewer code context, and it is the
>   only place Step 3.5 can apply a fix.
> - If nothing survives filtering, return exactly: `INBOX CLEAR`.

When the subagent returns `INBOX CLEAR`, tell the user their inbox is clear and stop.

### Step 2: Confirm

Present the table the subagent returned, with clickable links:

```
Found N PRs needing your review:

| # | Repo | PR | Author | Self | Title | Link | Board |
|---|------|----|--------|------|-------|------|-------|
| 1 | owner/repo | #123 | user | no | Title here | https://github.com/owner/repo/pull/123 | Waiting |
| 2 | owner/repo | #124 | you (self) | yes | My own PR | https://github.com/owner/repo/pull/124 | not configured |
```

Carry the `Self` column through from the discovery table — Steps 3 and 3.5 both need it, and
dropping it here is how the self-approval cap and the auto-fix pass get lost.

**Interactive mode (default):** ask which PRs to review — all, specific numbers, or exclude specific
ones. Say plainly in the same message that any PR marked `Self: yes` will also be **fixed and
pushed** after its review (Step 3.5); this prompt is the user's consent point for that push, so do
not bury it.

**Auto/loop mode:** skip confirmation and review every PR in the table (the subagent already applied all reliable filters). Do **not** add client-side heuristics like `updatedAt` filtering. Note what skipping Step 2 costs: there is then no consent point anywhere in the run, so self-authored PRs get fixed and **pushed** unattended. That is auto mode working as intended — and it is exactly why the interactive prompt above has to spell the push out, since that prompt is the only place a user ever sees it coming.

### Step 3: Review (sequential dispatch, labeling folded in)

Announce which PRs are being reviewed with clickable links, then dispatch reviews **one at a time, sequentially**. Each `devpilot:pr-review` run internally spawns its own parallel reviewer fanout, so sequential dispatch avoids excessive concurrency (5 PRs × ~6 reviewers = 30 concurrent agents would hit rate limits).

Each review agent **claims the PR by labeling it first, then reviews** — folding the label step into the dispatch keeps `gh label`/`gh pr edit` output out of the main context. Spawn a separate agent per PR and **wait for it to complete** before starting the next:

```
Agent({
  description: "Review owner/repo#123",
  subagent_type: "general-purpose",
  prompt: "You have the devpilot:pr-review skill available.

First, claim this PR for review by applying a label (idempotent — do not fail the review if labeling fails; just warn and continue):
  label=\"reviewing:<first_name>\"   # first_name from the discovery step
  gh label create \"$label\" --repo \"<owner/repo>\" --color FBCA04 --description \"Claimed for review by <first_name>\" 2>/dev/null || true
  gh pr edit <pr-url> --add-label \"$label\"

Then use devpilot:pr-review to review this PR: <url>. Local repo path: <absolute-path> (or 'not available' if remote-only). If a local path is provided, use it for reading surrounding code context. Follow the skill instructions completely.

POST THE REVIEW WITHOUT ASKING. You are running inside a batch sweep — there is no human watching this agent, so a draft held back for approval is a review that never lands. Do not return findings as text for someone else to post. The only conditions that skip a post are the three in devpilot:pr-review's posting.md ('Skip posting and say so'); PR count, comment count, finding severity, and whose PR it is are not among them.

SELF-AUTHORED: <yes|no> (copy from the `self` column of the discovery table). If yes, this is my own PR: do the full review exactly as normal, but cap the published review event at COMMENT — never post APPROVE. GitHub rejects self-approval with a 422 and the whole review post fails, so a clean self-authored PR would otherwise lose its entire review. This cap overrides devpilot:pr-review's normal event mapping. REQUEST_CHANGES is not capped and posts as usual.

Report back ONLY the result: approved, commented (with issue count), or skipped (with reason)."
})
```

After each agent completes, report its one-line result. If that PR is self-authored, run **Step
3.5** for it now, before dispatching the next PR's review — fixing while the PR is the one you
just reasoned about keeps the review and the fix on the same head SHA. Then start the next.

**The `reviewing:<name>` label is deliberately never removed.** It is a durable claim, not
transient run state: together with the `≥2 other reviewers` filter in Step 1 it is what stops
several people (or several runs) from spending tokens re-reviewing the same PR. Do not add a
cleanup step that strips the label after reviewing — that would defeat the whole mechanism.
Accumulated claim labels on a PR are the intended, useful signal of who has already covered it.

### Step 3.5: Auto-fix findings on your own PRs

Runs **only for PRs whose `self` column is `yes`**, immediately after that PR's review agent
returns and before the next PR's review is dispatched. Someone else's PR is theirs to fix — there
the review is the entire deliverable. On your own, the review you just posted is a to-do list you
already wrote the answers to, so act on it.

**Skip the fix pass** — and say which reason in the Step 4 summary — when any of these hold:

- `local_path` is `remote-only`. There is nothing to edit. Do not clone: adding checkouts to the
  user's disk is not this skill's job.
- The review posted zero inline findings (result `approved`, or `commented (0 issues)`).
- The local checkout is **dirty** (`git status --porcelain` non-empty). Uncommitted or untracked
  work in the user's tree is never something to stash, reset, clobber, or sweep into a fix commit.
The loop bound (below) is deliberately **not** in that list: counting `Devpilot-Auto-Fix` commits
needs the checkout, which the main agent never touches. Dispatch the fix agent anyway and let it
return `SKIP: fix-loop cap (N rounds)` or `SKIP: review backstop (N devpilot reviews)` — the Step 4
summary carries its line either way.

Dispatch one `general-purpose` agent per qualifying PR and **wait for it** before moving on:

```
Agent({
  description: "Auto-fix self-review findings on owner/repo#123",
  subagent_type: "general-purpose",
  prompt: <the FIX PROMPT below, with owner/repo, PR number, URL, and local_path filled in>
})
```

**FIX PROMPT** (paste verbatim, substituting the placeholders):

> You have the `devpilot:resolving-review-threads` skill available. `devpilot:pr-review` just
> reviewed **my own** PR `<url>` and posted inline findings. Apply them, push, and close the threads
> you fixed. Work inside `<local_path>`. Do not narrate — return only the one-line result at the end.
>
> **1. Read back the findings.** Anchor on the same head SHA and the same `devpilot:pr-review`
> marker the queue filter uses, so you read *that* review and not an older or foreign one:
>
> ```bash
> cd "<local_path>"
> repo="<owner/repo>"; num=<pr-number>
> head_sha=$(gh api "repos/$repo/pulls/$num" --jq '.head.sha')
> review_id=$(gh api --paginate "repos/$repo/pulls/$num/reviews" \
>   --jq ".[] | select(.commit_id == \"$head_sha\") | select((.body // \"\") | test(\"devpilot:pr-review\")) | .id" \
>   | tail -1)
> [ -n "$review_id" ] || { echo "SKIP: no devpilot review at HEAD"; exit 0; }
> gh api --paginate "repos/$repo/pulls/$num/comments" \
>   --jq ".[] | select(.pull_request_review_id == $review_id and .in_reply_to_id == null)
>         | {id, path, line: (.line // .original_line), body}" | jq -s .
> ```
>
> **Stream the jq, never wrap it in `[...]`.** Under `--paginate`, `gh` applies `--jq` to each page
> separately and concatenates the outputs (`--slurp` is rejected outright when `--jq` is present),
> so an array-wrapping filter emits one array *per page*. `[...] | last` fails worse than merely
> returning the wrong page: on a page with no match jq prints the literal `null`, which is a
> non-empty string, so `[ -n "$review_id" ]` sails past the guard and the comment filter degrades
> to `.pull_request_review_id == null` — legal jq that matches nothing. A PR whose review is full
> of findings then reads as "no findings" and is silently skipped. Stream the values and combine
> them in the shell instead — `tail -1` for the newest matching review, `jq -s .` to gather the
> comments — which is the same shape as the discovery filter's `... | head -1` in Step 1.
>
> `(.body // "")` is required for the same reason it is in the discovery filter: a bare APPROVE
> carries a `null` body and `null | test(...)` is a hard jq error that empties the whole list —
> which here would look like "the review had no findings" and silently skip a PR that has plenty.
> `.line` is `null` on an outdated comment, hence the `.original_line` fallback.
>
> **2. Guard the checkout before touching it.**
>
> ```bash
> [ -z "$(git status --porcelain)" ] || { echo "SKIP: working tree dirty"; exit 0; }
> orig_ref=$(git symbolic-ref --quiet --short HEAD || git rev-parse HEAD)
> gh pr checkout "$num" -R "$repo" || { echo "SKIP: could not check out PR branch"; exit 0; }
> [ "$(git rev-parse HEAD)" = "$head_sha" ] || { git checkout "$orig_ref"; echo "SKIP: head moved since review"; exit 0; }
> base=$(gh api "repos/$repo/pulls/$num" --jq '.base.ref')
> git fetch origin "$base" --quiet
> rounds=$(git log "origin/$base..HEAD" --grep='^Devpilot-Auto-Fix:' --oneline | wc -l | tr -d ' ')
> [ "$rounds" -lt 3 ] || { git checkout "$orig_ref"; echo "SKIP: fix-loop cap ($rounds rounds)"; exit 0; }
> posted=$(gh api --paginate "repos/$repo/pulls/$num/reviews" \
>   --jq ".[] | select((.body // \"\") | test(\"devpilot:pr-review\")) | .id" | wc -l | tr -d ' ')
> [ "$posted" -le 10 ] || { git checkout "$orig_ref"; echo "SKIP: review backstop ($posted devpilot reviews)"; exit 0; }
> ```
>
> The `head_sha` re-check is not paranoia: the findings you are about to apply are anchored to
> `path:line` **as of that SHA**. If someone (or another session) pushed while the review ran,
> those anchors point at lines that have moved, and applying them edits the wrong code. Bail and
> let the next queue run re-review the new head.
>
> `gh pr checkout` refuses rather than clobbers when a local branch of the same name has diverged;
> treat that failure as `SKIP: could not check out PR branch` and do **not** work around it with
> `-f`, a reset, or a delete-and-recreate.
>
> Restore `orig_ref` with `git checkout "$orig_ref"` before you return, on **every** exit path
> including the failure ones. Leaving the user's checkout parked on a PR branch is a side effect
> they did not ask for and will not notice until it bites them.
>
> **3. Fix everything mechanically fixable — every severity, nits included.** Attempt a fix for
> each finding regardless of its severity tag. Skip one only when applying it would mean:
>
> - **deciding something the finding does not settle** — two defensible behaviors and the comment
>   picks neither;
> - **changing what the PR set out to do**, rather than correcting how it does it;
> - **editing code far outside this PR's diff** to satisfy the comment;
> - **guessing at information you do not have** — an unstated invariant, an external contract or
>   config you cannot read.
>
> "It's only a nit" and "low severity" are **not** skip reasons. A nit with an obvious mechanical
> fix gets fixed; that is the whole point of doing this on your own PR.
>
> Open and read the file around each anchor before editing — never patch from the comment text
> alone, which is a summary of the problem, not of the surrounding code. When two findings touch
> overlapping lines, resolve them together in one edit rather than sequentially.
>
> **4. Verify, then commit and push.** Run the repo's own test and lint commands (from
> `CLAUDE.md` / `AGENTS.md` / `Makefile` / `package.json`) before committing. A fix that breaks the
> build is worse than the finding it closed. If a fix cannot be made to pass, revert *that hunk*
> and move it to the skipped list — never commit red.
>
> Stage **only the files you edited**, by path. `git add -A` sweeps in whatever the test and lint
> run left behind — coverage files, caches, build output, a refreshed lockfile — and those land in
> the PR under a commit message that claims they are review fixes.
>
> ```bash
> git status --porcelain          # confirm nothing unexpected appeared
> git add <each file you edited>
> git commit -F - <<'MSG'
> fix: address self-review findings on #<pr-number>
>
> <one line per applied finding: path:line — what changed>
>
> Devpilot-Auto-Fix: true
> MSG
> git log -1 --format=%B | grep -q '^Devpilot-Auto-Fix:' \
>   || { git checkout "$orig_ref"; echo "SKIP: fix commit has no Devpilot-Auto-Fix trailer"; exit 0; }
> git push \
>   || { git checkout "$orig_ref"; echo "SKIP: push failed — fixes are committed locally, nothing published"; exit 0; }
> ```
>
> The `Devpilot-Auto-Fix` trailer is what step 2 counts to bound the loop — do not drop it,
> reword it, or move it into the subject line, and **verify it landed before pushing**. A commit
> that lost it is the one way this pass becomes the runaway it is designed not to be: the next
> round counts zero rounds, so review → fix → push repeats with nothing to stop it. If the check
> fails, amend the trailer in and re-run it — the commit has not been pushed yet, and the
> never-amend rule below is about commits that are already on the remote. Only give up if it is
> still missing after the amend.
>
> Push with a plain `git push`: **never** `--force` or `--force-with-lease`, never rebase, never
> amend a commit that is already on the remote. Same rule as `devpilot:pr-guard`, and for the same
> reason. **Check that the push succeeded** — a protected branch, a lost race with another push,
> or missing write access all fail here. On failure, stop: do not report `pushed`, and do not go
> on to step 5. Replying "fixed in `<sha>`" and resolving threads against a commit that never
> reached the remote closes findings that are still live on the PR.
>
> **5. Close the threads.** Use `devpilot:resolving-review-threads` and follow it exactly — reply
> first, resolve second, one thread at a time. Post every reply **without asking**; nobody is
> watching this agent, and a thread left silent reads as "ignored", not "pending approval":
>
> - **Fixed** → reply naming the change and the new commit SHA, then resolve the thread.
> - **Skipped** → reply stating concretely which of the four skip cases applies and why, and
>   **leave the thread open**. Never resolve a finding you did not fix. A skipped finding still
>   gets its reply — silence is the one outcome that is never correct here.
>
> **Return ONLY** one line: `fixed: N, skipped: M, pushed <sha>` — or `skipped (<reason>)` if you
> never reached a commit. No diffs, no logs, no narration.

**Why the loop bound.** Pushing a fix moves the head SHA, so Step 1's already-reviewed-at-HEAD
filter stops matching and the next run re-reviews the PR. That is deliberate — the incremental
pass is what verifies the fix actually holds. What it must not become is a ping-pong that burns
tokens forever, so the fix agent refuses to add a fourth `Devpilot-Auto-Fix` commit to the same
branch. Three rounds that failed to converge is a signal for a human, not a reason for a fourth.

**And it terminates.** Rounds 1–3 each post a review and push a fix. Round 4 posts its review,
hits the cap, and pushes nothing — so the head SHA stops moving, that fourth review now matches
Step 1's already-reviewed-at-HEAD filter, and the PR drops out of the queue for good. Four reviews
and three fix commits is the worst case, not an open-ended cycle.

**Two counters, because one of them is erasable.** `rounds` counts trailers in the branch's own
commits, and any history rewrite — a rebase onto a moved base, an interactive squash, a force-push
from another tool — erases them and silently resets the bound to zero. The `posted` guard counts
`devpilot:pr-review` reviews on the PR instead: those are server-side records that no git operation
can rewrite. A converging PR tops out at four of them, so the ceiling of 10 only trips on something
genuinely cycling. It is a backstop, not the working limit — if it ever fires, the trailer bound
failed and that is worth reading the branch history over.

**Do not run this pass on PRs authored by someone else**, even when you have a local checkout and
the fix looks trivial. Pushing to another person's branch is not a review outcome.

### Step 4: Summary

After all agents complete:

```
## Review Summary

| PR | Link | Self | Result | Auto-fix |
|----|------|------|--------|----------|
| owner/repo#123 | [View](https://github.com/owner/repo/pull/123) | no | Approved | — |
| owner/repo#456 | [View](https://github.com/owner/repo/pull/456) | no | Commented (2 issues) | — |
| owner/repo#789 | [View](https://github.com/owner/repo/pull/789) | no | Skipped (merged) | — |
| owner/repo#790 | [View](https://github.com/owner/repo/pull/790) | yes | Commented (5 issues) | fixed 4, skipped 1, pushed `a1b2c3d` |
| owner/repo#791 | [View](https://github.com/owner/repo/pull/791) | yes | Commented (3 issues) | skipped (working tree dirty) |

Reviewed N PRs, auto-fixed M of my own. Done!
```

The `Auto-fix` column is `—` for anything not self-authored. For a self-authored PR it carries the
fix agent's one-line result verbatim, **including the skip reason** — a silent blank there reads as
"nothing to fix" when the real story is usually a dirty checkout or a missing local clone, both of
which the user can act on in seconds once they see them.
