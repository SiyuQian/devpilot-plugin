# Rationalizations and Self-Check

Common shortcuts the reviewer may reach for, and what to do instead. The "Reality" column is the rule.

## Table

| Excuse | Reality |
|---|---|
| "This PR is small, skip the five questions." | Small PRs change defaults, delete branches, flip flags. Answer all five; "N/A" is fine. |
| "The author explained intent in the description." | Intent ≠ actual behavior. Trace one input through the code. |
| "Diff looks clean, no need to look at callers." | Diff shows what changed, not the blast radius. Check Unknown-Unknowns Sweep question 2. |
| "I recognize the pattern, I can assert the right way." | Training can be 6–18 months stale. Do question 4 first. |
| "Writing a retry loop / cache / parser here is fine." | Usually there is a mature off-the-shelf option. Do question 5. |
| "LGTM, nothing jumps out." | Trace at least one input through at least one change first. |
| "This feels minor, I'll leave it out to keep the review tidy." | Report it with Confidence + Severity labels. Filtering happens downstream, not here. |
| "I'm unsure, I'll file it as Should-fix to be safe." | Severity is impact-if-true; Confidence is how sure you are. Keep them separate. |
| "I'll just print the review in chat, user can paste it." | Post by default. Only skip when the user opts out or no real PR exists. |
| "Blocking finding, but I'll post as `COMMENT` to be polite." | Event follows severity: a Blocking finding goes with `REQUEST_CHANGES`. |
| "I'll list all findings in the body — easier to read than scrolling inline." | Findings tied to a line go inline so the author can act on each one in place. The body is for TL;DR, sweep summary, counts, and overall observations only. |
| "No clean line for this one, so I'll put it in the body." | Anchor to the most representative line and say so in the comment. The author can ask for a different anchor; they cannot resolve a body bullet. |
| "This is a code-quality nit, not behavior — skip it." | The skill runs both passes: behavior sweep *and* the quality checklist. Code quality, architecture, testing, requirements, production-readiness are in scope. |
| "Behavior trace is the whole point — checklist items are filler." | Behavior sweep is what makes the review more than style; the checklist is what makes it more than a behavior trace. Run both. |
| "I'll post the inline comments as standalone PR comments via `gh pr comment`." | Standalone comments aren't part of the review and don't show up in the right pane. Use one combined `POST .../pulls/:num/reviews` with body + `comments[]` + event. |
| "I'll split blockers and nits into two reviews." | One review per pass. The author gets one notification, one set of comments, one verdict. |
| "I'll skip the eligibility gate and just review." | The gate is 1–2 `gh` calls. Skipping it wastes a fanout on a dependabot PR or duplicates a review you already posted. |
| "I'll run the passes myself instead of dispatching subagents." | The fanout is parallel for a reason — the agents finish in the time of one, and the main session keeps its context for filtering and drafting. Sequential single-thread defeats the design. |
| "I'll skip one of the core agents — Agent D/E rarely finds anything." | The angles are independent. Skipping an angle by hunch is how silent defects survive. Run all 5 core agents (plus F when dependencies were added); the filter step is where you discard noise. |
| "Confidence 65, but the bug feels real — I'll round up to 75." | Don't bargain with yourself. Open the file that would raise confidence to 85, or drop it. The rubric exists so 70 means something. |
| "All findings are below threshold — I'll lower it to surface something." | A clean fanout is allowed to produce zero findings. Approve and move on. Lowering the thresholds (`confidence.md`) to fill space is noise. |
| "Same defect on 4 lines — I'll post 4 nearly-identical comments." | One consolidated inline comment anchored to the worst occurrence, with the other `path:line`s listed inside. Recurrence count goes in the body sweep summary. Four near-identical comments is the noise inline-first is meant to avoid. |
| "I'll put the body link in short-SHA form, the reader can figure it out." | GitHub Markdown previews require the full 40-char SHA. Short SHA or branch name → no rendered preview. Use `git rev-parse HEAD`. |
| "I'll skip the Verdict — readers can infer it from the counts." | The Verdict is the one thing every reader looks at. State it explicitly: Yes / With fixes / No. |
| "I'll skip Strengths — sounds performative." | Accurate praise gates trust in the rest of the review. Two specific bullets, not generic compliments. |
| "I'll ask 'what happens when X?' so the author clarifies." | If the code can answer it, state the answer. Author questions live in Open Questions only. |
| "I have a better approach but I'll stay neutral." | Name it, one sentence on why, ask the author to confirm. |
| "Graph says this symbol has 0 callers — must be dead code, skip it." | `callers.count: 0` means *no static caller in the indexed languages*. Reflection, codegen, RPC, CLI dispatch tables, and test main files are invisible to the graph. Confirm with one grep before claiming dead code. |
| "Graph says change_type=modified, so the symbol's behavior changed." | `change_type` is line-overlap based; neighboring edits can mark a struct/function "modified" without changing its shape. Diff the symbol body before treating it as a behavior change. |
| "Graph is unavailable, so I'll skip the blast-radius question." | Fall back to grep and note `grep-only fallback` in the sweep summary. The question still has to be answered; only the source of the answer changes. |
| "Graph corroborated my finding, so I'll skip reading the caller file." | Graph confirms the edge exists; it does not confirm the caller still satisfies the new contract. Open the caller. |
| "The graph tool errored, so I'll explain in the body why it's missing." | You know it failed; you do not know why. "This plugin install doesn't ship the wrapper" and "that backend doesn't exist" have both been published and both been wrong. Quote the tool's own reason verbatim (`graph unavailable: <reason>`) and stop there. A cause you have not checked with a path listing or a `--help` exit code does not go in a posted artifact. |
| "`preflight` says `index_stale`, so the graph can't help on this PR." | Almost always a missing `--at <head-sha>`: `gh pr view`/`gh pr diff` never check head out, so the index describes the default branch. Re-run `ensure --repo . --at <head-sha>` and pass the returned `.repo` to the preflight before falling back. |
| "The graph payload has `callers.confident: true`, so a zero count kills this finding." | Not on every backend. When `data.contradiction_allowed` is `false` (the `devpilot` backend), the count may corroborate but must never contradict — that backend does not expose per-symbol resolution diagnostics. Treat the finding as Unsupported and leave its score alone. |

## Self-check before posting

Before running `gh pr review`, run through this list. A "yes" on any item means the review is not ready; fix the underlying issue and re-check.

- Eligibility gate skipped — PR turned out to be draft / merged / dependabot / already reviewed.
- Fanout collapsed: some core agents didn't run (or F skipped despite new dependencies), or the agents ran sequentially in the main session.
- Findings below their severity's confidence threshold (`confidence.md`) made it into the review, or more than 3 Consider findings posted.
- Verdict (`Ready to merge: ...`) missing from the body.
- Diff has concrete strengths but the Strengths section is missing, or it's filled with generic compliments. (Zero genuine strengths → omitting the section is correct, not a failure.)
- Writing findings before the five blind-spot questions were answered.
- Findings are all naming / formatting / "could be cleaner".
- Comparing two options the author already listed instead of surfacing ones they did not consider.
- "LGTM" without a single traced input.
- Only files in the diff were opened; no callers, tests, or configs.
- Findings tied to a line dumped into the body instead of attached as inline comments. Mechanical form of this check: the POST payload has findings but an empty (or missing) `comments[]` array.
- Body was free-composed instead of rendered from `template.md` — missing the `<!-- devpilot:pr-review` marker, the `### Inline findings` counts, or the disclaimer's `Code graph / AST facts:` slot (which must state `used`, `partial: <gap>`, or `not available` for this review).
- An inline comment that repeats the file path or line number inside its text.
- A cross-cutting finding promoted to the body because "no line fit" — should have anchored to the most representative line.
- Author questions about behavior the code could have answered.
- Known-better alternatives hidden as vague questions.
- Findings missing a `Confidence` line.
- Review event does not match the highest-severity finding.
- Inline comments and body posted as separate API calls instead of one combined POST.
- Review is not in the PR's language end-to-end (including the disclaimer and inline-comment field labels).
