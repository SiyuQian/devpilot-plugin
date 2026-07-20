# Spec: `devpilot pr-review preflight` / `devpilot pr-review post`

Two subcommands that absorb the deterministic steps of the `devpilot:pr-review` skill so the model spends tokens only on judgment (fanout, filtering, drafting). Implemented in the devpilot CLI repo; this spec lives with the skill that consumes them.

The skill treats these as an optimization: it probes `devpilot pr-review preflight --help` / `post --help` and falls back to the manual `gh` path in `skills/pr-review/references/eligibility.md` and `posting.md` when absent. **The manual path is the behavioral contract** — anything ambiguous here resolves to what those files do.

---

## 1. `devpilot pr-review preflight <pr-url> --out <path>`

Replaces skill steps 0–1.5: eligibility gate, PR load, incremental-review detection, existing-comment collection, graph preflight, dependency-manifest extraction. One invocation, one JSON file out, nothing on stdout except a one-line summary.

### Flags

| Flag | Required | Meaning |
|---|---|---|
| `<pr-url>` | yes | GitHub PR URL. GitLab out of scope for v1 (skill's manual path covers it). |
| `--out <path>` | yes | Where to write the output JSON. |
| `--diff-out <path>` | no | Where to write the diff. Default: `<out-dir>/pr_<num>_diff.patch`. |
| `--force` | no | Skip the `already_reviewed_at_head` stop (user said "re-run anyway"). |

### Behavior

1. Resolve `owner/repo/num` from the URL.
2. Gate checks, in order, mirroring `eligibility.md`'s table: state (closed/merged), draft, automation author (Dependabot/Renovate/release-please/known bots), generated-files-only diff, empty diff. First hit → `gate.decision: "stop"` with reason; still populate whatever metadata was already fetched.
3. Incremental detection: latest review whose body contains `<!-- devpilot:pr-review` via **REST** `GET /repos/{owner}/{repo}/pulls/{num}/reviews` (GraphQL lacks `commit_id`). `commit_id == headRefOid` → stop (unless `--force`); else `review_mode: "incremental"` and the diff written is the range diff `last_reviewed_sha..head`.
4. Fetch all existing inline review comments (any author) via REST.
5. Run `devpilot graph preflight --base <base> --head <head>` internally with a 30 s timeout; on any failure embed `{"mode": "fallback", "reason": "<why>"}` instead of failing the command.
6. Extract the dependency manifest from the diff per `import-verifier.md` "Extraction rules" (Go/npm/Python/Rust, stdlib allowlist applied).
7. Write JSON to `--out`. The diff goes to `--diff-out` as a file, never inlined in the JSON — the model passes the *path* to subagents.

### Output JSON shape

```jsonc
{
  "schema": "devpilot.pr-review.preflight/v1",
  "gate": {
    "decision": "proceed" | "stop",
    "stop_reason": null | "merged" | "closed" | "draft" | "automation_only"
                 | "generated_only" | "empty_diff" | "already_reviewed_at_head",
    "stop_message": null | "<one line the model relays to the user>"
  },
  "review_mode": "full" | "incremental",
  "last_reviewed_sha": null | "<40-char sha>",
  "pr": {
    "owner": "...", "repo": "...", "number": 123,
    "title": "...", "body": "...", "author": "...",
    "base_sha": "...", "head_sha": "...",
    "files": [{ "path": "...", "additions": 1, "deletions": 2 }]
  },
  "diff_path": "<absolute path to the patch file>",
  "existing_comments": [
    { "path": "...", "line": 1, "side": "RIGHT", "body": "...", "user": "...", "commit_id": "..." }
  ],
  "graph": { /* devpilot graph preflight payload verbatim, or {"mode":"fallback","reason":"..."} */ },
  "dependency_manifest": { "go": [...], "npm": [...], "python": [...], "rust": [...] }
}
```

Exit codes: `0` = JSON written (including `decision: stop` — a stop is a successful answer); `1` = infrastructure failure (network, auth, gh missing) with a human-readable stderr line. The model must not treat a stop as an error.

---

## 2. `devpilot pr-review post <pr-url> --findings <path> --body <path> --event <EVENT>`

Replaces skill step 5: anchor validation, payload build, single combined POST.

### Flags

| Flag | Required | Meaning |
|---|---|---|
| `<pr-url>` | yes | Same PR the findings target. |
| `--findings <path>` | yes | JSON array of inline findings (shape below). |
| `--body <path>` | yes | Markdown file with the rendered review body. |
| `--event <EVENT>` | yes | `REQUEST_CHANGES` \| `COMMENT` \| `APPROVE`. |
| `--dry-run` | no | Validate everything, print the payload summary, POST nothing. |

### Findings input shape

```jsonc
[
  {
    "path": "internal/auth/client.go",
    "line": 72,
    "side": "RIGHT",              // or "LEFT" for deleted lines
    "start_line": null,           // optional, multi-line comments; start_line <= line
    "start_side": null,
    "body": "### [Blocking] ...\n\n**Behavior today...**"   // full rendered markdown
  }
]
```

### Validation (all before any network write; any failure → exit 1, POST nothing)

- Every `(path, line, side)` exists in the diff at the PR's current head SHA (prevents the 422). Re-fetch head at post time; if it moved since preflight, fail with `head_moved: <old> -> <new>` so the model can re-run the review gate.
- `--event` is one of the three values; `APPROVE` with a non-empty findings array is rejected (severity/event mismatch).
- Body length under the 65 KB review-body limit.
- `start_line <= line` when present.

### Behavior

Build `{event, body, comments[]}` and issue **one** `POST /repos/{owner}/{repo}/pulls/{num}/reviews`. All quoting/newline escaping is the CLI's job. On success print the review URL on stdout. Never split into multiple reviews; never fall back to `gh pr comment`.

Exit codes: `0` = posted (or dry-run passed); `1` = validation failure (stderr names the failing finding by index + reason); `2` = GitHub rejected the POST (stderr includes the API error verbatim).

---

## Non-goals (v1)

- GitLab (manual path covers it).
- Running any part of the fanout/filtering — judgment stays in the model.
- Auto-running `devpilot graph build` (same rule as the skill: preflight consumes an existing graph or falls back).
- Registry checks for Agent F (the agent runs those itself; preflight only extracts the manifest).
