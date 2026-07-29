---
name: pr-review
description: >-
  Use when the user asks to review a pull request, merge request, or a diff —
  "review this PR", "review PR #123", "look over these changes", "check my diff
  before I merge", "/review", or when they share a PR URL and ask for thoughts.
  Findings are posted as inline comments anchored to specific lines so the
  author can act on each one in place. Do NOT use for pure style/lint review,
  formatting-only changes, or language-specific idiom review (defer to style
  skills like devpilot:google-go-style).
---

# PR Review (Eligibility-Gated, Parallel-Fanout, Inline-First)

## Overview

A PR review the author can act on: every concrete finding is posted as an **inline comment anchored to the line it talks about**, drawn from a **parallel multi-angle scan** and filtered through an explicit **confidence rubric** so the author sees signal, not noise. The body holds a short verdict, strengths, the blind-spot sweep, and counts.

Three structural ideas drive this skill:

1. **Eligibility gate** — decide the PR is worth a full review before spending tokens on it. Dependabot, drafts, generated-file PRs, "already reviewed" all stop here.
2. **Parallel fanout** — five core subagents (A–E) plus an optional sixth (F) look at the change from independent angles in parallel. Coverage comes from diversity of angle, not depth of a single pass. The main session dispatches and merges; subagents read code. Agent F (Dependency Reality Check) is dispatched only when the dispatcher's pre-extracted dependency manifest is non-empty — it verifies imports/packages resolve on their public registry, catching hallucinated names that pass every text-based agent.
3. **Confidence filtering** — every finding carries `Confidence: 0–100`. Findings below the threshold defined in `references/confidence.md` are dropped by default. Coverage at collection, filtering at posting.

## When NOT to Use

- Pure formatting / lint / rename PRs — defer to the relevant style skill.
- No PR, diff, or branch given — ask the user for one.
- Everything else that shouldn't get a full review (closed, draft, automation-only, generated-only, already reviewed) is handled by the eligibility gate in step 0 — enter the skill and let the gate decide.

## Three rules that govern every finding

<coverage_in_collection_filtering_at_posting>
Subagents report every finding they reach, including uncertain ones — that is the only way to get coverage. The main session filters by Confidence and Severity at posting time. A finding silently dropped by a subagent because it "felt minor" is a defect in the review; a finding scored 40 and filtered out at the gate is fine.
</coverage_in_collection_filtering_at_posting>

<investigate_before_asserting>
State how the code behaves only after opening and reading the relevant files. When a finding depends on a caller or test the subagent did not locate, it MUST score Confidence ≤ 50 and record the gap. No speculation passed off as fact.
</investigate_before_asserting>

<inline_by_default>
Every finding tied to a specific line goes in as an inline review comment, never in the body. The body holds only the Verdict, TL;DR, Strengths, the sweep summary, finding counts, and Open Questions. If a finding has no obvious anchor (cross-cutting concern, missing-but-not-present code), anchor it to the most representative line and say so in the comment — do not promote it to the body.
</inline_by_default>

## Workflow

```
0. Eligibility gate         → references/eligibility.md
1. Load PR                  → gh / git / pasted patch
1.5 Graph enrichment        → references/graph.md (codegraph.sh ensure → preflight; offer install if absent)
2. Parallel fanout          → references/fanout.md (5 core agents in parallel, +F if deps added)
3. Filter + merge + reconcile against graph → references/confidence.md
4. Draft review             → references/template.md
5. Post one combined POST   → references/posting.md
Self-check before post      → references/rationalizations.md
```

**Working files:** cache intermediate JSON in the session scratchpad directory with the PR number in the filename (`<scratchpad>/pr_<num>_*.json`), never in bare `/tmp` — fixed paths leak stale data between PRs and concurrent reviews.

**No hard dependency on the devpilot CLI.** Two different relationships to that binary, do not conflate them:

- **Steps 0 and 5 are CLI-*optional*.** They collapse into one `devpilot pr-review preflight` / `devpilot pr-review post` call when the installed devpilot supports them (`--help` exits 0). The manual `gh` paths in `references/eligibility.md` and `references/posting.md` are the contract and the fallback; the CLI is a token optimization and nothing is lost without it.
- **Step 1.5 is CLI-*bootstrapped*, and its CLI is not devpilot.** The graph comes from [CodeGraph](https://github.com/colbymchenry/codegraph) (tree-sitter, 20+ languages, no build manifest required). It is a real capability, not a shortcut, so when the CLI is missing the skill offers to install it rather than shrugging. All graph access goes through `${CLAUDE_PLUGIN_ROOT}/scripts/codegraph.sh`, which resolves, installs (with consent), indexes, and synthesizes the preflight payload. **Never invoke `codegraph` directly.**

Steps 2–4 (fanout, filtering, drafting) are judgment work and always run in the model.

### 0. Eligibility gate

Before anything else, run the gate in `references/eligibility.md`. If the PR is closed, draft, automation-only, generated-only, or already reviewed by you **at the current head SHA**, stop and tell the user. Cheap; saves an entire fanout.

The gate also produces two outputs the later steps consume:

- **Review mode** — `full` (no prior devpilot review) or `incremental` (prior review exists but head has moved; fanout runs against `last_reviewed_sha..head_sha`, not the full PR diff).
- **Existing review comments** — `<scratchpad>/pr_<num>_existing_review_comments.json`, every prior inline comment on this PR from any reviewer. Used by step 3 to drop findings that duplicate an existing comment.

### 1. Load the PR

```bash
gh pr view <url> --json title,body,files,baseRefName,headRefOid,author
gh pr diff <url>
```

Or `git diff <base>...HEAD` for a local branch, or read a pasted patch directly. Capture the **head SHA** — link rendering depends on it (see `references/posting.md`). A PR with no stated intent is itself a finding.

### 1.5. Graph enrichment

Only when the PR touches a graph-supported language (Go, TypeScript/JavaScript, Rust). Skip entirely for docs-only, Python-only, or shell-only PRs — including the install prompt below.

```bash
CG="${CLAUDE_PLUGIN_ROOT:-.}/scripts/codegraph.sh"
"$CG" ensure --repo .                                   # safe unattended: never installs, never prompts
"$CG" -- preflight --repo . --base <base-sha> --head <head-sha>   # when ensure says action=ready
```

Cache the preflight JSON to `<scratchpad>/pr_<num>_graph.json` and inject it into the shared header that every fanout brief sees. The payload tells subagents — before they read any code — which symbols changed, who calls each, which are hubs, which lack tests, and which cross-community edges this PR adds. Agent A's blast-radius answer comes from this payload, not from grep.

**When the CLI isn't installed** (`action: needs_install`), do not silently degrade — that is the whole point of this step. Tell the user what the graph buys them and what it costs (~57 MB download unpacking to ~280 MB under `~/.codegraph`, launcher in `~/.local/bin`, a few seconds to index, telemetry off, index excluded from their `git status`), and ask once:

- Yes → `"$CG" install --yes --repo .`, then continue with the graph.
- No → `"$CG" opt-out --repo .`, which records the refusal so **no future review in this repo asks again**, then fall back to grep.

For any other non-`ready` action (`declined`, `build_failed`, `unsupported_platform`, `install_failed`), **fall back** to the grep-only path and note `Behavior trace: grep-only (graph unavailable: <reason>)` in the body's sweep summary, quoting the wrapper's `reason` verbatim. `ensure` auto-builds a cold index — the old "do not auto-run `graph build`" rule now lives inside the wrapper.

**Read `callers.confident` before quoting any caller count.** `false` means the count is a graded upper bound (name collision, unresolved call sites, or cross-package method binding), not a fact — it steers where you look but must never become a claim in a finding, and it can never contradict one. See `references/graph.md` for the action table, full payload schema, the caveat semantics, fallback triggers, and confidence-weighting rules.

### 2. Parallel fanout (5 core + F conditional)

Dispatch all in a single message so they run in parallel, synchronously (`run_in_background: false`), and wait for every agent to return before step 3. Each receives the PR metadata, the diff, and one focused brief. Each returns findings with `Confidence: 0–100` and `Severity`. See `references/fanout.md` for the prompts. Agent F is conditional: the dispatcher pre-extracts the dependency manifest per `references/import-verifier.md` → "What the dispatcher pre-extracts"; F is dispatched only when that manifest is non-empty.

In **incremental mode**, the diff passed to subagents is the range diff (`last_reviewed_sha..head_sha`), not the full PR diff — agents should look at the new commits only. Agent A still grounds its blast-radius checks in the full repo, but findings must be anchored to lines changed in the new commits.

| Agent | Angle |
|---|---|
| A | Behavior sweep (5 blind-spot questions + behavior trace) |
| B | Shallow bug scan on the diff + Security/Performance [REQUIRED CHECKS] coverage |
| C | Repo convention compliance (CLAUDE.md / AGENTS.md / cursor & copilot rules / repo skills, read-only) |
| D | Git blame & history + comments on prior PRs touching these files |
| E | Code comments & in-file conventions in modified files |
| F | Dependency reality check — verifies added imports/packages resolve on public registry (conditional: only dispatched when the diff adds dependencies) |

The main session does NOT also do these passes itself. Subagent context savings are the point.

### 3. Filter, dedupe, merge

Graph-reconcile each finding (corroborated → floor 85; contradicted → cap 50) → drop findings below the confidence threshold (`references/confidence.md`) → drop matches against `eligibility.md` false-positive list, including duplicates of existing inline comments at the same anchor (from step 0) → dedupe across agents; same defect across multiple files → one consolidated comment listing the other `path:line`s → anchor each survivor to `(path, line)`. Full procedure incl. graph-injected missing-test findings: `references/confidence.md`.

### 4. Draft the review

One inline comment per anchored finding: severity-tagged title + Behavior today / Why that's a problem / Suggested change / Confidence. One body: Verdict + TL;DR + Strengths + Unknown-Unknowns Sweep summary (from Agent A) + Security/Performance coverage line + inline-finding counts + Open Questions. Templates, field rules, and tone/stance/language are in `references/template.md`. Calibrate against `references/example-review.md` on first use.

### 5. Post

Single combined POST to `repos/:owner/:repo/pulls/:num/reviews` carrying `{event, body, comments[]}` in one call — never split into multiple reviews and never post inline findings via `gh pr comment`. Event derived from highest severity (`confidence.md` → "Severity rubric"). Links in the body use full-SHA `blob` URLs so GitHub renders the snippet preview.

Payload shape:

```bash
jq -n --arg event "$event" --arg body "$body" --argjson comments "$comments_json" \
  '{event:$event, body:$body, comments:$comments}' \
| gh api -X POST "repos/$owner/$repo/pulls/$num/reviews" --input -
# each entry in $comments_json: {path, line, side:"RIGHT"|"LEFT", body}
```

Two invariants gate the POST — violating either means the draft step failed and must be redone, not posted:

1. **Findings survived filtering ⇒ `comments[]` is non-empty.** A review whose findings appear as body prose with `path:line` references has collapsed into a body-only review; never use `gh pr review --body/-b`, which cannot carry `comments[]`.
2. **The body is the rendered `template.md` skeleton** — including the `<!-- devpilot:pr-review -->` marker and the disclaimer's `Code graph / AST facts: <used | partial | not available>` slot, filled honestly from step 1.5's outcome.

See `references/posting.md` for the full `jq` build, anchor field rules (multi-line / LEFT side / `start_line`), GitLab equivalent, and the local-only "skip posting" mode. Before posting, walk `references/rationalizations.md` self-check.

## Cross-References

- Code quality at the naming / function / class level → `devpilot:clean-code-principles`.
- Go-specific idiom review → `devpilot:google-go-style`.
- Defer to those skills rather than duplicating their content.

## Reference Index

| File | What's in it |
|---|---|
| `references/eligibility.md` | Gate rules + false-positive list (when to skip review entirely, what to never flag). |
| `references/graph.md` | Codegraph bootstrap via `scripts/codegraph.sh` (action table, install consent, opt-out), preflight payload schema, fallback triggers, confidence-weighting rules consumed by step 3. |
| `references/fanout.md` | Subagent prompts A–F (Behavior, Bug scan + sec/perf coverage, Repo conventions, Git history, In-file comments, Dependency reality) — A–E receive the graph payload; F receives the pre-extracted dependency manifest. |
| `references/import-verifier.md` | Agent F spec: per-ecosystem registry-check commands (Go / npm / Python / Rust), finding shape, typosquat heuristic, fallback rules. |
| `references/confidence.md` | 0–100 rubric, tiered thresholds by severity, security severity floor, severity vs. confidence axes, dedupe rules, graph reconciliation. |
| `references/unknown-unknowns.md` | Behavior sweep details — Agent A's playbook. |
| `references/checklist.md` | Quality dimensions referenced by Agent B's bug scan and Agent A's checklist tail. |
| `references/template.md` | Inline comment template + review body template (Verdict, Strengths, sweep, counts) + tone/stance/language rules. |
| `references/posting.md` | One combined POST (`gh api`), full-SHA link format, GitLab equivalent. |
| `references/example-review.md` | Worked example: body + inline comments. |
| `references/rationalizations.md` | Common shortcuts + pre-post self-check. |
