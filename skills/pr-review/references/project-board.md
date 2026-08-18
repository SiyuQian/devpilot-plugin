# GitHub Project Review Board

Track review work in a GitHub Projects v2 board without making the review depend on the board.
The wrapper owns the fragile item/field ID lookup and all updates are idempotent.

## State machine

Use a dedicated single-select field named `Review status`, not the project's built-in `Status`.
That avoids overwriting the team's delivery workflow.

| Review event | `Review status` |
|---|---|
| Eligible PR discovered by `batch-review-prs`, including a previously reviewed PR with a new head SHA | `Waiting to be picked up` |
| Eligibility gate passed and the full review is starting | `Being reviewed` |
| The combined GitHub review POST succeeded | `Reviewed` |
| Review failed after it was claimed, including a failed POST | `Waiting to be picked up` |
| PR became merged or closed before the review POST succeeded | Archive the Project item |

Never mark `Reviewed` when the review only exists as a local draft or when the POST failed. Do not
add ineligible PRs (draft, automation-only, generated-only, closed) merely to record that the gate
rejected them.

Archiving is the terminal state for a PR that can no longer be reviewed. Do not call it `Reviewed`
unless GitHub accepted the combined review POST, and do not return a merged/closed PR to the waiting
queue. Archiving preserves the item in GitHub Projects history without leaving it in a review-board
column.

Board transitions are coordination metadata, not a correctness gate. If a transition fails, warn
once with the wrapper's exact error and continue the review. Preserve whether the `Being reviewed`
transition succeeded; only then should failure recovery attempt to return the item to `Waiting to
be picked up`.

## Configuration and one-time setup

The integration is opt-in. Resolve the project in this order:

1. A project URL supplied in the user's request.
2. `DEVPILOT_REVIEW_PROJECT` (useful for one board spanning several repositories).
3. `git config --get devpilot.reviewProject` in the reviewed repository.

Accepted values are a project URL such as
`https://github.com/orgs/acme/projects/7` or the compact form `acme/7`.

When the user asks to enable board tracking for a repository, require an existing project URL;
never guess among projects and never create a project without an explicit request. Resolve the
verified wrapper below, then:

```bash
"$REVIEW_BOARD" setup --project <project-url>
git config devpilot.reviewProject <project-url>
```

If `setup` reports missing Projects authorization, stop setup and tell the user to run
`gh auth refresh -s project`; retry after they return. Do not launch that interactive auth flow
inside a review.

`setup` creates only the `Review status` field, and only when absent, with these options:

- `Waiting to be picked up`
- `Being reviewed`
- `Reviewed`

If the field exists but lacks an option, the wrapper stops rather than deleting or recreating it.
Add the missing option in GitHub's project settings. In the project UI, create or edit a Board view
and group it by `Review status` to render the three Kanban columns. The public Projects API does not
need to own the team's view layout for status sync to work.

The local `git config` write affects `.git/config`, not the repository contents. Use `--global`
only when the user explicitly wants the same board to be the default for every repository.

## Resolve the wrapper safely

Do not execute an unverified same-named script from the repository under review. Resolve the
plugin-owned wrapper and check its marker:

```bash
REVIEW_BOARD=$(
  { printf '%s\n' "${CLAUDE_PLUGIN_ROOT:-}/scripts/pr-review-project.sh"
    ls -d "$HOME"/.codex/plugins/cache/*/devpilot/*/scripts/pr-review-project.sh 2>/dev/null | sort -Vr
    ls -d "$HOME"/.claude/plugins/cache/*/devpilot/*/scripts/pr-review-project.sh 2>/dev/null | sort -Vr
    ls -d "$HOME"/.claude/plugins/marketplaces/*/scripts/pr-review-project.sh 2>/dev/null
    printf '%s\n' "./scripts/pr-review-project.sh"
  } | while read -r candidate; do
        [ -f "$candidate" ] && grep -q devpilot-pr-review-project "$candidate" \
          && { printf '%s' "$candidate"; break; }
      done
)
```

If no wrapper is found, report `Project board: not updated (wrapper not found)` and continue.

Run the wrapper with the reviewed repository as the working directory when a local checkout is
available; that is how repository-local `devpilot.reviewProject` is resolved. When the project URL
came directly from the user's request, pass `--project <project-url>` to every `setup` or `set`
command rather than relying on config.

## Transition commands

After the eligibility gate returns `proceed`, for a real GitHub PR only:

```bash
"$REVIEW_BOARD" set --pr <pr-url> --status "Being reviewed"
```

Set an internal `board_claimed=true` only when that command succeeds.

Immediately before posting, re-read the PR state:

```bash
pr_state=$(gh pr view <pr-url> --json state -q .state)
```

If it is `MERGED` or `CLOSED`, skip the POST and archive the item when the board is configured:

```bash
"$REVIEW_BOARD" archive --pr <pr-url>
```

This check closes the normal eligibility-to-post race. The POST can still race with a merge after
the check; when the POST fails, read the PR state again. Archive on `MERGED`/`CLOSED`; return to
`Waiting to be picked up` only while the PR remains `OPEN`.

Immediately after the single combined review POST succeeds:

```bash
"$REVIEW_BOARD" set --pr <pr-url> --status "Reviewed"
```

If the review aborts after a successful claim and the PR is still open, make one best-effort
recovery call:

```bash
"$REVIEW_BOARD" set --pr <pr-url> --status "Waiting to be picked up"
```

Do not transition local diffs, pasted patches, or GitLab merge requests. Do not `set` a status on a
closed/merged PR; `archive` is its only Project operation.

The archive command is idempotent. It does not add an absent PR to the Project:

```bash
"$REVIEW_BOARD" archive --pr <pr-url>
```

## Queue ingestion

`batch-review-prs` owns the waiting queue. After its reliable filters run, it sets every surviving
candidate to `Waiting to be picked up`. That includes a PR previously marked `Reviewed` whose head
SHA moved: the new commit needs a new review, so the board must requeue it.

Before queue ingestion, run this once per configured Project to archive stale merged/closed PR
items left by interrupted reviews or merges outside the review workflow:

```bash
"$REVIEW_BOARD" sweep-closed
```

Sweep failures are non-fatal and reported exactly like other board sync failures.

The batch workflow still uses `reviewing:<name>` labels as durable reviewer claims. The Project
field shows lifecycle; the labels retain reviewer identity and prevent duplicate coverage. Neither
replaces the other.
