# Posting the Review

Default flow: show the user the drafted body and the inline comments, then post **everything in a single combined POST** to GitHub's review API. Body + inline comments + event in one call so they show up grouped under one review (not as standalone PR comments).

## Post without asking

**Posting is automatic. Never ask permission, never stop for approval, never wait for a "go ahead."**

Invoking this skill *is* the instruction to post. A review that stops at "here's the draft — want me
to post it?" has delivered nothing: the findings are the deliverable, and they are only useful on
the PR where the author sees them anchored to their lines. Rendering the review in chat and waiting
converts a finished job into a pending one and forces the user to authorize the same thing twice.

Show the drafted body and comments in chat if it helps the user follow along — but show them
**alongside the POST, not as a gate in front of it**. The user can always delete or edit the review
afterward; they cannot act on a review that was never posted.

The **only** things that stop a post are the mechanical conditions under
[Skip posting and say so](#skip-posting-and-say-so) — an explicit opt-out, no real PR, or a
closed/merged PR. "It felt polite to check first", "the findings are harsh", "the event is
REQUEST_CHANGES", "it's the user's own PR", and "there are a lot of comments" are **not** among
them. Severity does not gate posting; it only picks the event.

## CLI-first: one post call replaces the manual jq build

If the devpilot CLI supports it (`devpilot pr-review post --help` exits 0), write the findings and body to files and post with ONE command instead of hand-building the jq payload:

```bash
devpilot pr-review post "$url" \
  --findings "$SCRATCH/pr_${num}_findings.json" \
  --body "$SCRATCH/pr_${num}_body.md" \
  --event "$event"
```

The CLI validates every anchor against the diff at head SHA (the 422 pre-check), handles quoting/newline escaping, and issues the single combined POST. On any validation error it prints which finding failed and posts nothing — fix and re-run.

**Fallback:** if the subcommand is missing, use the manual `jq` + `gh api` path below. The manual path is the contract; the CLI is an optimization of it.

## Manual path (fallback)

## GitHub — single combined POST

Build a JSON payload and pipe it to `gh api --input -`:

```bash
owner=...   # e.g. SiyuQian
repo=...    # e.g. devpilot
num=...     # PR number

# $body holds the rendered review body (template.md → "Review body template").
# $event is REQUEST_CHANGES | COMMENT | APPROVE (see mapping below).

jq -n \
  --arg event "$event" \
  --arg body  "$body" \
  --argjson comments "$comments_json" \
  '{event: $event, body: $body, comments: $comments}' \
| gh api -X POST "repos/$owner/$repo/pulls/$num/reviews" --input -
```

`$comments_json` is a JSON array, one object per inline finding. Build it with `jq` so quoting and newlines in markdown bodies are handled safely:

```bash
comments_json=$(jq -n '
  [
    { path: "internal/auth/client.go", line: 72, side: "RIGHT", body: $c1 },
    { path: "internal/auth/client.go", line: 68, side: "RIGHT", body: $c2 },
    { path: "internal/auth/client.go", line: 83, side: "RIGHT", body: $c3 }
  ]
' --arg c1 "$comment_blocking" \
  --arg c2 "$comment_should_fix" \
  --arg c3 "$comment_consider")
```

Each comment body uses the inline-comment template from `template.md`. Severity tag goes inside the comment text; the API does not have a per-comment severity field.

### Event mapping

See `confidence.md` → "Severity rubric" for the severity → `$event` mapping.

### Anchor fields

- **`path`** — repo-relative path of the changed file.
- **`line`** — line in the file at the head SHA. Use the new line for added or changed lines.
- **`side`** — `RIGHT` for added / changed (default), `LEFT` for deleted lines (then `line` refers to the base file).
- **Multi-line comments** — add `start_line` (and `start_side` when commenting across both sides). `start_line` ≤ `line`.
- **Avoid `position`** — deprecated; `line` + `side` is the supported form.

### Resolving `owner`, `repo`, `num`

```bash
gh pr view "$url" --json url,number,baseRepository \
  -q '"\(.baseRepository.owner.login) \(.baseRepository.name) \(.number)"'
```

…or split the URL `https://github.com/<owner>/<repo>/pull/<num>`.

### Link format for the body

Links in the **body** (TL;DR, Strengths, sweep summary, Open Questions) MUST use the full-SHA `blob` form so GitHub renders the snippet preview:

```
https://github.com/<owner>/<repo>/blob/<full-40-char-sha>/<path>#L<start>-L<end>
```

Rules:
- **Full SHA only** — `git rev-parse HEAD` output. `main`, `HEAD`, `$(git rev-parse HEAD)`, or short SHAs do NOT render in Markdown previews.
- `#` separator after the path; line range as `L<start>-L<end>`.
- Provide ≥ 1 line of context before and after the line you're citing. Commenting about line 12? Link `L11-L13`.
- The repo segment must match the PR's repo, not a fork.

Inline comments do NOT need these links — their anchor (`path`, `line`) is structured metadata. Use links only in the body.

### Pre-post sanity check

Before the POST, these are hard gates — a failed check means the payload is malformed and MUST NOT be posted:

- Re-read `gh pr view <url> --json state -q .state` immediately before POST. If the PR is now
  `MERGED` or `CLOSED`, skip the POST and follow `project-board.md` to archive its review-board item.
- **`comments[]` is non-empty whenever any finding survived filtering.** Zero inline comments is only legal when the review has zero findings (clean approve). Findings rendered as body sections with `path:line` references instead of `comments[]` entries is the single most common failure of this skill — if you catch yourself doing it, go back to step 4 and re-read `template.md`.
- **The body is the rendered `template.md` skeleton**, verifiable mechanically: it contains the leading `<!-- devpilot:pr-review` marker, a `### Verdict` heading, an `### Inline findings` count section, and the disclaimer line with the `Code graph / AST facts: <used | partial | not available>` slot filled in. A body missing any of these was free-composed, not drafted from the template — redraft it.
- Every inline comment's `(path, line)` exists in the diff at `head_sha` (`gh pr diff` output). Posting against a non-diff line returns 422.
- The combined body length is well under GitHub's review-body limit (65 KB). Trim if needed; per-finding detail lives inline anyway.
- The event matches the highest-severity finding (table above).

## GitLab — discussions API

GitLab merge requests use `glab api` for inline (positional) discussions and `glab mr note` for the body summary. There is no `request-changes` state; severity stays in the body.

```bash
# One request per inline finding
glab api -X POST "projects/:id/merge_requests/:iid/discussions" \
  -F "body=$comment_body" \
  -F "position[base_sha]=$BASE_SHA" \
  -F "position[head_sha]=$HEAD_SHA" \
  -F "position[start_sha]=$START_SHA" \
  -F "position[position_type]=text" \
  -F "position[new_path]=$path" \
  -F "position[new_line]=$line"

# Summary body
glab mr note <iid> --message "$body"
```

Resolve `BASE_SHA`, `HEAD_SHA`, `START_SHA` from `glab mr view --json diff_refs`.

## Skip posting and say so

Skip posting and tell the user explicitly that the review is local-only when any of these hold:

- The user opted out **in their own words, in this conversation** ("don't post", "dry run", "local only", "just draft"). Absence of an explicit "yes, post it" is not an opt-out — the default is to post.
- The review is on a patch pasted into chat with no real PR behind it.
- The PR is already merged or closed. If it was claimed on the configured review Project, archive
  the Project item instead of returning it to the waiting queue.

This list is exhaustive. If none of the three holds, post — do not invent a fourth reason and do not
ask the user to supply one.

In any of those cases, render the body and the inline comments in chat (each comment prefixed with its `path:line` so the user can read it without the API anchor).

## Anti-shortcuts

- **Don't post via `gh pr review --body/-b`** — that command cannot carry `comments[]`, so every finding silently collapses into the body and the review loses its inline anchors. Always build the combined payload and POST to `.../pulls/:num/reviews` (or use `devpilot pr-review post`).
- **Don't post inline comments via `gh pr comment`** — those are PR conversation comments, not review comments. They show up in a different pane and can't be resolved as part of a review.
- **Don't post inline comments outside a review** (`POST .../pulls/:num/comments` directly). Always route through `POST .../pulls/:num/reviews` so they land grouped under one review with the right event.
- **Don't split into multiple reviews** ("one for blockers, one for nits"). One review per pass; the author sees one notification, one set of comments, one verdict.
