# Graph Enrichment (codegraph)

Graph is the **fact bed** under the fanout. It does not produce findings on its own. It tells every subagent, before they read code, exactly which symbols this PR changed, who calls them, whether any of them are hubs, and which public surface lacks tests. Subagents stop guessing about blast radius; the main session can corroborate or contradict findings against ground truth.

Pre-fanout, run the preflight once. Inject the result into the shared header that every Agent A–E brief sees. Subagents do **not** call the graph themselves — they consume the structured payload.

## Never call `devpilot` directly

Every graph call in this skill goes through the plugin's wrapper:

```bash
CG="${CLAUDE_PLUGIN_ROOT:-.}/scripts/codegraph.sh"
```

The wrapper — not this skill — owns binary resolution, install bootstrap, cold-cache builds, and the user's consent decision. Calling `devpilot graph …` directly reintroduces the bug this design exists to kill: **a user who has never installed the devpilot CLI silently gets a grep-only review forever, and is never told the graph was available to them.**

`${CLAUDE_PLUGIN_ROOT}` is set by Claude Code for plugin-shipped scripts. When running the skill from a bare checkout instead of an installed plugin, point `CG` at `scripts/codegraph.sh` in that checkout.

## Step 1.5, in full

### 1. Ask the wrapper what's available

```bash
"$CG" ensure --repo .
```

`ensure` is **safe to run unattended** — it never downloads, installs, or prompts. It resolves a graph-capable binary, builds the cache if the repo has never been indexed, and prints one line of JSON. Branch on `.action`:

| `action` | What it means | What you do |
|---|---|---|
| `ready` | Binary found, cache built. | Go to step 3. |
| `needs_install` | No graph-capable devpilot on this machine. | Step 2 — **ask the user.** |
| `declined` | The user already said no in this repo. | Fall back to grep. Do **not** ask again. |
| `build_failed` | Binary works, but this repo can't be indexed. | Fall back to grep, quoting `.reason`. |
| `unsupported_platform` | No prebuilt binary for this OS/arch. | Fall back to grep. Don't offer the install. |
| `install_failed` | The installer itself failed. | Fall back to grep, quoting `.reason`. |

The JSON also carries `bin`, `version`, `graph_cache`, `opted_out`, and `repo`. Human-readable progress goes to **stderr**, JSON to **stdout** — so `"$CG" ensure --repo . 2>/dev/null` is a clean parse.

### 2. When it's missing: offer the install, once

The wrapper deliberately cannot prompt (a `read` would hang any headless session). **You** ask, in one short message, then act on the answer:

> This PR touches Go/TS/Rust, so I can ground the review in a real call graph — who calls each changed symbol, which are hubs, what's untested — instead of grepping. That needs the `devpilot` binary (~28 MB, one download from its GitHub releases, installed to `~/.local/bin`, checksum-verified by the official installer). Indexing this repo takes a few seconds and is incremental afterwards. Install it?

- **Yes** → `"$CG" install --yes --repo .` — runs the official upstream installer, verifies the release checksum, feature-probes the result, then builds the cache and re-emits the `ensure` JSON. On `ready`, continue to step 3.
- **No** → `"$CG" opt-out --repo .` — records a marker in the repo's git dir so no future review in this repo asks again. Then fall back to grep.

Do not install without an explicit yes; `install` without `--yes` refuses with exit 2 by design. Do not offer the install when `action` is `unsupported_platform` — there is nothing to download.

Ask **at most once per review**, and only when the PR actually touches a supported language (Go, TypeScript/JavaScript, Rust at time of writing). A docs-only or Python-only PR gets no graph either way, so an install prompt there is pure noise — skip straight to the grep path.

### 3. Run the preflight

```bash
"$CG" -- preflight --base <base-sha> --head <head-sha>
```

`--` passes everything after it straight through to `devpilot graph`, so this is a drop-in for the raw command and returns devpilot's JSON envelope untouched. For an incremental re-review (see eligibility.md), pass `--base <last_reviewed_sha> --head <head_sha>` instead of PR base.

Cache the JSON to `$SCRATCH/pr_${num}_graph.json`.

## Fallback triggers (skip graph, fall through to grep)

Fall back and tell the body why if **any** of:

- `ensure` returns any `action` other than `ready` (see the table above).
- `data.mode != "built"` in the preflight payload.
- Preflight exits non-zero or takes > 30 s.
- PR touches only unsupported languages (e.g. Python-only, shell-only, docs-only).

Note the fallback in the body's sweep summary, quoting the wrapper's `reason` verbatim so the user learns the actual cause:

```
Behavior trace: grep-only (graph unavailable: go_no_module: repo contains .go files but no go.mod/go.work)
```

`graph unavailable: <reason>` with a real reason is the point. "graph unavailable" alone tells the user nothing they can act on.

**On auto-building:** earlier revisions of this skill forbade auto-running `graph build`. That rule now lives in the wrapper's `ensure`, and it builds. A review that gets the user to install the binary and *then* still reports "graph unavailable" is worse than a few seconds of indexing. Builds are incremental after the first, and `ensure` writes only to the graph cache dir (`~/.devpilot/graphs/`), never to the repo.

## Payload — what each field means for the review

```jsonc
{
  "data": {
    "mode": "built",                       // or "fallback" → skip graph; see above
    "graph": { "freshness": { "covers_base_sha": true, "stale_files": 0 } },
    "changed_symbols": [
      {
        "id": "internal/auth/oauth.go::StartFlow",
        "kind": "function",
        "is_exported": true,
        "change_type": "modified",
        "callers": { "count": 2, "in_hub": false,
                     "sample": ["internal/gmail/service.go::Service.Login", ...] },
        "tests": { "has_tests": false, "test_symbols": [] },
        "community": "internal/auth",
        "risk_factors": ["untested_public"]
      }
    ],
    "cross_community_edges": [
      { "from": "internal/gmail", "to": "internal/auth",
        "count_added": 7, "samples": ["..."] }
    ],
    "risk_summary": {
      "hub_nodes_modified": 0,
      "untested_public_changes": 15,
      "interface_changes": 0,
      "new_cross_community_edges": 8
    }
  }
}
```

`changed_symbols[]` also contains whole-file entries (`"kind": "file"`) for added files, alongside the symbol entries. Those carry `callers.count: 0` and `tests.has_tests: false` **by construction**, so never read them as "dead code" or "untested". Only reason about entries whose `kind` is a symbol kind (`function`, `method`, `type`, …). Several fields (`risk_factors`, `callers.sample`, `test_symbols`) are `null` rather than `[]` when empty.

| Field | What Agent A–E does with it |
|---|---|
| `changed_symbols[].callers` | Agent A's blast-radius answer. Authoritative. Skip the grep step. |
| `changed_symbols[].callers.in_hub` | If `true`, Agent A escalates that symbol's review and notes it in `sweep_summary.blast_radius`. |
| `changed_symbols[].tests` | Agent A and Agent B both consult. `has_tests:false` on an exported behavior change is a Should-fix finding. |
| `changed_symbols[].risk_factors` | `untested_public`, `hub`, `interface_change` — each gates a specific finding pattern. May be `null`. |
| `cross_community_edges` | Agent A's "is this PR widening the contract between two packages?" question. A Consider-level finding only when the edge reverses the repo's existing dependency direction AND is unmentioned in the PR description; at most one consolidated finding per review (see fanout.md Agent A step 3). Otherwise a sweep-summary line. |
| `risk_summary.untested_public_changes` | Aggregate count for the body's sweep summary. |
| `risk_summary.interface_changes` | If > 0, Agent A traces implementors via `"$CG" -- context --id <iface>`. |

## Confidence weighting (consumed by `confidence.md` merge step)

After the fanout returns, the main session reconciles each finding against the graph payload:

- **Corroborated** — the finding names a symbol whose callers/risk_factors match the defect. Confidence floor raised to 85. (Cap stays at 95 unless literal-string evidence pushes it to 100.)
- **Contradicted** — the finding asserts "X calls Y" but graph shows Y has zero callers, or asserts "this is a hub" but `in_hub:false`. Confidence capped at 50, which drops it under the default threshold.
- **Unsupported** — finding sits outside the graph's coverage (no symbol match, or graph in fallback mode). No adjustment. Original score stands.

A finding can be both corroborated on one dimension and contradicted on another — take the more conservative outcome.

## Optional follow-ups

Used only when a specific surviving finding needs a deeper trace; not run by default.

```bash
"$CG" -- context --id <symbol-id> --depth 1   # source + immediate callers/callees
"$CG" -- impact  --files <path,path>          # caller union for symbols defined in files
```

Output is appended to the inline comment as evidence, not posted as a separate finding.

## Known noise / limits

Common graph-misreading traps (dead-code claims, `change_type` false positives, dynamic dispatch invisibility) are enumerated in `rationalizations.md` rows — that's the active self-check. Graph does not replace reading code; it removes the "did I miss a caller?" anxiety.

Wrapper-specific traps:

- **`graph build` exits 0 while reporting `ok:false`.** Never judge a build by its exit code; the wrapper reads `graph status`'s `ok` field instead. Calling devpilot directly gets this wrong.
- **A repo with stray source files but no module manifest cannot be indexed.** This plugin repo is itself an example: Go *fixtures* under `skills/harness-engineering/evals/fixtures/` with no `go.mod` make every build fail with `go_no_module`. Expected, not a bug — take the grep path.
- **In a git worktree the opt-out marker lives under `.git/worktrees/<name>/`**, so declining in one worktree does not carry over to the main checkout.
