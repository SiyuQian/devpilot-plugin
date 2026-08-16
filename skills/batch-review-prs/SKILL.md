---
name: batch-review-prs
description: "Use this skill whenever the user wants to check their review queue, see pending reviews, review all their PRs, says 'review my PRs', 'check my review inbox', 'what PRs need my review', 'review everything assigned to me', or any variation of batch-reviewing pending pull requests. Also trigger when the user says /batch-review-prs or /review-inbox. Even if the user just says 'review my stuff' or 'catch up on reviews', this skill likely applies."
---

# Batch Review PRs

Discovers all open PRs that need your review on GitHub — ones requesting you, ones you've reviewed
before, **and your own** — and reviews them via `devpilot:pr-review`.

Needs only `gh`. Adds claim labels, already-reviewed-at-HEAD filtering, and local-checkout
syncing. This is the single review-queue skill — the older `pr-review-queue` (which discovered
the queue via `devpilot github prs review-queue`) was removed as a duplicate.

## Context discipline (read first)

Discovery, filtering, and repo-sync produce large volumes of raw `gh api` JSON, per-PR loop output, and `git fetch` noise. **None of that belongs in the main agent's context.** The main agent should only ever see:

1. The compact PR table returned by the discovery subagent (Step 1).
2. Per-PR review results (Step 3).
3. The final summary (Step 4).

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
> **Return ONLY this** — no logs, no JSON dumps, no narration:
> - The resolved `first_name` (the reviewer's, for labeling).
> - A markdown table with columns: `#`, `repo` (owner/repo), `pr` (number), `author` (append `(self)` for self-authored), `self` (`yes` / `no`), `title`, `url`, `local_path` (absolute path or `remote-only`).
>   The explicit `self` column is not redundant with the `(self)` suffix — Step 3 reads that column to decide the review event cap.
> - If nothing survives filtering, return exactly: `INBOX CLEAR`.

When the subagent returns `INBOX CLEAR`, tell the user their inbox is clear and stop.

### Step 2: Confirm

Present the table the subagent returned, with clickable links:

```
Found N PRs needing your review:

| # | Repo | PR | Author | Self | Title | Link |
|---|------|----|--------|------|-------|------|
| 1 | owner/repo | #123 | user | no | Title here | https://github.com/owner/repo/pull/123 |
| 2 | owner/repo | #124 | you (self) | yes | My own PR | https://github.com/owner/repo/pull/124 |
```

Carry the `Self` column through from the discovery table — Step 3 needs it, and dropping it here is
how the self-approval cap gets lost.

**Interactive mode (default):** ask which PRs to review — all, specific numbers, or exclude specific ones.

**Auto/loop mode:** skip confirmation and review every PR in the table (the subagent already applied all reliable filters). Do **not** add client-side heuristics like `updatedAt` filtering.

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

SELF-AUTHORED: <yes|no> (copy from the `self` column of the discovery table). If yes, this is my own PR: do the full review exactly as normal, but cap the published review event at COMMENT — never post APPROVE. GitHub rejects self-approval with a 422 and the whole review post fails, so a clean self-authored PR would otherwise lose its entire review. This cap overrides devpilot:pr-review's normal event mapping. REQUEST_CHANGES is not capped and posts as usual.

Report back ONLY the result: approved, commented (with issue count), or skipped (with reason)."
})
```

After each agent completes, report its one-line result before starting the next.

**The `reviewing:<name>` label is deliberately never removed.** It is a durable claim, not
transient run state: together with the `≥2 other reviewers` filter in Step 1 it is what stops
several people (or several runs) from spending tokens re-reviewing the same PR. Do not add a
cleanup step that strips the label after reviewing — that would defeat the whole mechanism.
Accumulated claim labels on a PR are the intended, useful signal of who has already covered it.

### Step 4: Summary

After all agents complete:

```
## Review Summary

| PR | Link | Result |
|----|------|--------|
| owner/repo#123 | [View](https://github.com/owner/repo/pull/123) | Approved |
| owner/repo#456 | [View](https://github.com/owner/repo/pull/456) | Commented (2 issues) |
| owner/repo#789 | [View](https://github.com/owner/repo/pull/789) | Skipped (merged) |

Reviewed N PRs. Done!
```
