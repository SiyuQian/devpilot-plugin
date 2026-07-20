# Parallel Fanout: Dispatching the Six Review Agents

The six subagent briefs live as **plugin agent definitions** under `agents/` at the plugin root — each is a dedicated agent type with a fixed system prompt and a read-only tool whitelist (no write tools, so "subagents must not post" is enforced mechanically, not by prompt):

| Agent | subagent_type | Focus |
|---|---|---|
| A | `devpilot:pr-review-behavior-sweep` | Behavior-level defects, five blind-spot questions, blast radius |
| B | `devpilot:pr-review-bug-scan` | Obvious bugs in the diff + Security/Performance checklist coverage |
| C | `devpilot:pr-review-conventions` | Repo's own written rules (CLAUDE.md / AGENTS.md / rule files) |
| D | `devpilot:pr-review-git-history` | git blame/log + prior-PR review comments on touched files |
| E | `devpilot:pr-review-in-file-comments` | In-file comments, invariants, neighboring naming conventions |
| F | `devpilot:pr-review-dependency-check` | Existence check on newly-added dependencies (conditional) |

Dispatch all of them in a **single message with parallel `Agent` tool calls** (named `Task` in older harness versions) so they run concurrently. Dispatch with `run_in_background: false`; if the harness runs them in the background anyway, wait until every dispatched agent has returned before moving to filtering — never predict, fabricate, or summarize a pending agent's results.

Agent F dispatch is gated on the dispatcher's pre-extracted dependency manifest per `references/import-verifier.md` → "What the dispatcher pre-extracts": if the manifest is empty, skip F entirely.

## What each agent's prompt must contain

Each agent's system prompt already carries its brief, output shape, and confidence calibration — your dispatch prompt only supplies the per-PR data:

1. **Shared PR header:** URL, title, body, head SHA, base SHA, files changed list, full diff.
2. **Shared graph header** (below).
3. **Agent F only:** the pre-extracted dependency manifest.

## Shared graph header (injected into every prompt)

When graph is available, prepend this block:

```
GRAPH_PREFLIGHT (authoritative for callers, hubs, untested public surface):
- changed_symbols: <id, kind, is_exported, callers.count, callers.sample[], in_hub, tests.has_tests, risk_factors[]>
- cross_community_edges: <from → to, count_added, samples[]>
- risk_summary: <hub_nodes_modified, untested_public_changes, interface_changes, new_cross_community_edges>
Source of truth for "who calls X" and "is X a hub". Do NOT re-derive these via grep.
```

When graph fell back, the block instead reads `graph_unavailable: <reason>; use grep, expect lower confidence on blast-radius claims`. See `references/graph.md` for the full payload schema and fallback rules.

## Finding shape (what every agent returns)

Each subagent returns a JSON-ish list of findings:

```
- path: <repo-relative>
  line: <int, head SHA>     # use new-side line for added/changed; old-side for deleted (note `side: LEFT`)
  side: RIGHT | LEFT
  severity: Blocking | Should-fix | Consider | Nit
  confidence: 0–100
  title: <≤80 chars>
  behavior: <what the code actually does today on this branch>
  why: <impact on users / data / operability>
  fix: <concrete direction, name the helper/package/function>
  agent: <A | B | C | D | E | F>
```

Agent B additionally returns a `coverage` block (Security/Performance), Agent A a `sweep_summary` block, Agent F a `coverage.dependencies` block — see each agent definition.

Subagents MUST NOT post anything; their output is purely returned to the main session for filtering and merging.

## Dispatch template (main session)

```python
# Pseudocode — actually invoked as parallel Agent tool calls in a single message.
agents = {
    "A": "devpilot:pr-review-behavior-sweep",
    "B": "devpilot:pr-review-bug-scan",
    "C": "devpilot:pr-review-conventions",
    "D": "devpilot:pr-review-git-history",
    "E": "devpilot:pr-review-in-file-comments",
}
manifest = extract_dependency_manifest(diff)   # see import-verifier.md
if manifest:
    agents["F"] = "devpilot:pr-review-dependency-check"
for letter, agent_type in agents.items():
    parallel_calls.append(
        Agent(
            description=f"PR review fanout agent {letter}",
            subagent_type=agent_type,
            run_in_background=False,
            prompt=SHARED_PR_HEADER + GRAPH_HEADER + (DEPENDENCY_MANIFEST if letter == "F" else ""),
        )
    )
```

**Fallback — plugin agents unavailable** (skill copied standalone, or agent types not registered): dispatch a read-only generic agent instead (`Explore` in current Claude Code; `general-purpose` only if no read-only type exists), and for each agent Read the corresponding `agents/pr-review-*.md` file at the plugin root and prepend its body (below the frontmatter) to the prompt as the brief.

Wait until **all** dispatched agents have returned, then proceed to `references/confidence.md` for filtering and merging. If any agent dies or is skipped, note it in the body's sweep summary (`agent <X> did not return`) rather than inventing its findings.
