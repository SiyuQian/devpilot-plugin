# Eligibility Gate and False-Positive List

Run this gate **before** dispatching the fanout. It is cheap and prevents wasting tokens on PRs that don't benefit from a full review.

## CLI-first: one preflight call replaces the manual gate

If the devpilot CLI supports it (`devpilot pr-review preflight --help` exits 0), run the entire gate + data collection as ONE command instead of the manual `gh` sequence below:

```bash
devpilot pr-review preflight "$url" --out "$SCRATCH/pr_${num}_preflight.json"
```

The output JSON carries everything steps 0–1.5 need: `gate.decision` (proceed / stop with reason), `review_mode` (full / incremental + `last_reviewed_sha`), PR metadata, the diff written to a file path (not inlined), existing review comments, the graph preflight payload, and the pre-extracted dependency manifest for Agent F. Trust its gate decision and skip the rest of this file's command blocks — the false-positive list below still applies at filter time.

**Fallback:** if the subcommand is missing (older devpilot, or not installed), run the manual path below. The manual path is the contract; the CLI is an optimization of it.

## Manual path (fallback)

## Gate: when to stop and not review

Stop and tell the user explicitly when any of the following hold. Do **not** silently skip — the user asked for a review; tell them why you're not running one.

| Condition | How to check | What to say |
|---|---|---|
| PR is **closed or merged** | `gh pr view --json state -q .state` | "PR is `MERGED`/`CLOSED`; nothing to review." |
| PR is a **draft** and the user did not explicitly ask | `gh pr view --json isDraft -q .isDraft` | "PR is a draft. Want me to review it anyway?" |
| **Already reviewed by you at the current head SHA** (devpilot marker present AND `commit_id` of the latest devpilot review == current `headRefOid`) | See "Already-reviewed check" below | "I already reviewed this exact commit. Want me to re-run anyway?" |
| **Automation-only PR** (Dependabot, Renovate, release-please, sync bots) | `gh pr view --json author -q .author.login` matches known bot handle | "Looks like an automated PR. Quick sanity check only, or full review?" |
| **Generated-files-only diff** (lockfiles, mocks, generated code) | All paths in `gh pr view --json files` match a generator pattern (`*.lock`, `**/generated/**`, `**/*.pb.go`, etc.) | "Diff is generated files only; no behavior to review." |
| **Empty diff** | `gh pr diff` returns no hunks | "Empty diff." |
| **No PR / diff / branch** given | n/a | Ask the user for one. |

If none apply, proceed to the fanout.

## Already-reviewed check (incremental re-review)

A prior devpilot review is **not** a stop condition on its own — only a stop condition when the PR head has not moved since. Resolve it with:

```bash
# $SCRATCH = the session scratchpad directory; $num = the PR number.
# Filenames carry the PR number so concurrent/successive reviews never read stale data.
head_sha=$(gh pr view "$url" --json headRefOid -q .headRefOid)

# Pull every review you (devpilot) have left, newest first, with its commit_id.
# NOTE: must use the REST endpoint — `gh pr view --json reviews` (GraphQL) has no
# `commit_id` field, which silently breaks incremental re-review detection.
gh api "repos/$owner/$repo/pulls/$num/reviews" \
  --jq '[.[] | select(.body | test("<!-- devpilot:pr-review"))] | sort_by(.submitted_at) | reverse | .[0] // empty' \
  > "$SCRATCH/pr_${num}_last_devpilot_review.json"

last_reviewed_sha=$(jq -r '.commit_id // empty' "$SCRATCH/pr_${num}_last_devpilot_review.json")
```

Decision:

| State | Action |
|---|---|
| No prior devpilot review | Full review of the entire PR diff. |
| `last_reviewed_sha == head_sha` | Stop per the gate row above. |
| `last_reviewed_sha` set and `!= head_sha` | **Incremental re-review.** Diff the new commits only: `gh pr diff "$url" --patch` against the *range* `last_reviewed_sha..head_sha` (e.g. `git diff "$last_reviewed_sha".."$head_sha"`). Run the fanout on that range, not the full PR diff. The review body's TL;DR must say "Re-reviewing commits since `<short_sha>`". |

In incremental mode, also load every existing review comment on the PR (from anyone, not just devpilot) so the filter step can drop duplicates — see the false-positive list below.

```bash
gh api "repos/$owner/$repo/pulls/$num/comments" \
  --jq '[.[] | {path, line, side, body, user: .user.login, commit_id}]' \
  > "$SCRATCH/pr_${num}_existing_review_comments.json"
```

## False-positive list (filtered out at step 3, not surfaced)

These never become inline findings. Subagents may surface them; the main session drops them before drafting. Match against this list explicitly when filtering.

- **Pre-existing issues** — the defect already existed on the base branch. Not this PR's job.
- **Already raised by an existing review comment** — if any comment in `$SCRATCH/pr_${num}_existing_review_comments.json` (devpilot's prior runs or another reviewer) anchors at the same `(path, line)` (±3 lines) and discusses the same defect, drop the new finding. Exception: the existing comment was marked resolved/outdated by a later commit and the defect is still present — then it's in scope, and the new comment must reference the prior one ("re-raising — still present after `<short_sha>`"). Treat the existing-comments file as authoritative; do not re-post the same defect to spare the author another notification.
- **Lines the PR did not modify** — even if buggy, not in scope. Exception: the PR's change makes the line reachable / hot for the first time; then it is in scope and the comment must say so.
- **Linter / typechecker / compiler-catchable issues** — missing imports, type errors, formatting, unused-var warnings. CI runs separately; do not duplicate.
- **Broken tests / failing CI** — surfaced separately; not a review finding.
- **Issues explicitly silenced in code** — `//nolint`, `# noqa`, `// eslint-disable-next-line`, in-line `_ = unused`. Trust the silencer unless the silencer itself is wrong.
- **Pedantic style nitpicks** that a senior engineer would not raise (newline placement, single-line ternary vs. if, etc.).
- **General "could have more tests" without a specific risky path** — Agent A and B name a specific untested risky path or it does not count.
- **General "could have better docs"** — unless `CLAUDE.md`/`AGENTS.md` explicitly requires docs for this kind of change.
- **Changes obviously intentional and directly part of the PR's stated purpose**, even if they "look like" a change.
- **Suggestions to add features the PR did not aim to add** — scope creep on the reviewer's side.

Findings that survive this list AND clear the tiered confidence thresholds in `confidence.md` go inline. Everything else is dropped silently.

## Edge case: PR description missing or empty

A PR with no stated intent is itself a finding — surface it in the body's Open Questions, not as an inline comment. Run the rest of the review against your best inference of intent from the diff, and say so in the TL;DR.
