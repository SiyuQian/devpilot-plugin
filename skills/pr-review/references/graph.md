# Graph Enrichment (codegraph)

Graph is the **fact bed** under the fanout. It does not produce findings on its own. It tells every subagent, before they read code, exactly which symbols this PR changed, who calls them, whether any of them are hubs, and which public surface lacks tests. Subagents stop guessing about blast radius; the main session can corroborate or contradict findings against ground truth.

Pre-fanout, run the preflight once. Inject the result into the shared header that every Agent A–E brief sees. Subagents do **not** call the graph themselves — they consume the structured payload.

## Two backends, and which one you got

The wrapper resolves one of two backends and reports which in the JSON `backend` field. **Read it. The payloads are not interchangeable.**

1. **`codegraph`** — [CodeGraph](https://github.com/colbymchenry/codegraph), a tree-sitter indexer covering 20+ languages that needs **no build manifest and no compiler**. Preferred, and the schema documented below is its schema.
2. **`devpilot`** — `devpilot graph preflight`, used when CodeGraph is not installed and devpilot can index this particular repo. It is already on PATH for anyone using the devpilot CLI, so the wrapper probes it before offering a ~57 MB download — including in a repo where the user previously declined that download, since this backend installs nothing.

CodeGraph is *preferred*, not *better at everything*: devpilot resolves callers through the language's real module graph, but it refuses repos it cannot resolve (a Go tree without `go.mod` fails with `go_no_module`; so does this plugin's own repo). That refusal is why CodeGraph is the default and why the fallback is a probe rather than a first choice.

Where the devpilot payload differs, `scripts/devpilot_graph_adapter.py` normalises it and marks what it cannot supply. Two consequences you must honour:

- **`changed_symbols[].lines` is `null`** on this backend. Anchor on the diff hunk instead.
- **`data.contradiction_allowed: false`** is present on this backend. `callers.confident` is `true` because devpilot binds structurally, but it exposes no per-symbol resolution diagnostics — so a count here may **corroborate** a finding (floor 85) and must **never contradict** one. See the confidence-weighting section.

## Never call `codegraph` — or `devpilot graph` — directly

The wrapper — not this skill — owns binary resolution, backend choice, install bootstrap, index building, the user's consent decision, and the synthesized preflight. Calling a backend CLI directly reintroduces the bug this design exists to kill (**a user who never installed the CLI silently gets a grep-only review forever, and is never told the graph was available**) and skips three protections the wrapper adds: telemetry off, watcher daemon off, and `.codegraph/` excluded from the reviewed repo's `git status`.

### Resolving the wrapper — do not write `${CLAUDE_PLUGIN_ROOT:-.}`

**`CLAUDE_PLUGIN_ROOT` is not reliably set in the bash calls a skill makes.** It is injected for plugin-shipped hooks, not for the review session's shell — so `${CLAUDE_PLUGIN_ROOT:-.}/scripts/codegraph.sh` expands to `./scripts/codegraph.sh`, i.e. **a path inside the repo under review**, which almost never exists. What comes back is a bare `No such file or directory` from the shell, which is indistinguishable from "the plugin doesn't ship this script" unless you go looking.

Resolve it by searching the places it can live and confirming each candidate is really this wrapper, via the `devpilot-codegraph-wrapper` marker on its second line:

```bash
CG=$(
  { printf '%s\n' "${CLAUDE_PLUGIN_ROOT:-}/scripts/codegraph.sh"
    ls -d "$HOME"/.claude/plugins/cache/*/devpilot/*/scripts/codegraph.sh 2>/dev/null | sort -Vr
    ls -d "$HOME"/.claude/plugins/marketplaces/*/scripts/codegraph.sh 2>/dev/null
    printf '%s\n' "./scripts/codegraph.sh"
  } | while read -r c; do
        [ -f "$c" ] && grep -q devpilot-codegraph-wrapper "$c" && { printf '%s' "$c"; break; }
      done
)
[ -n "$CG" ] || echo "wrapper_not_found"
```

The marker check is the point: `./scripts/codegraph.sh` is last in the list precisely because a same-named script in the reviewed repo would otherwise be executed as if it were ours.

## Step 1.5, in full

### 1. Ask the wrapper what's available

```bash
"$CG" ensure --repo . --at <head-sha>
```

**Always pass `--at <head-sha>`.** Step 1 loads the PR with `gh pr view` / `gh pr diff`, neither of which checks the head branch out — so the checkout is still on the default branch while the diff describes the PR head, and the preflight correctly refuses with `index_stale`. Following this skill's steps literally, without `--at`, produces `mode: fallback` on essentially every remote PR. With `--at`, the wrapper materialises that revision as a detached shared clone under `~/.local/state/devpilot-plugin/graph-trees/`, indexes that, and returns its path as `.repo`.

Three rules that go with it:

- **Feed `.repo` from the `ensure` output into the preflight's `--repo`**, not your own cwd. The index describes that tree, not the user's checkout.
- **The user's checkout is never modified** — no branch, no detached HEAD, no refs touched. Don't offer to check the PR out yourself; that is the thing this replaces.
- The tree is cached per (repo, SHA) and reused across re-reviews. Do not clean it up: it is what makes an incremental re-review cheap.

It lives outside the repo because CodeGraph resolves a project by walking to the outermost git root — anything placed inside the repo (linked worktree *or* nested clone) resolved back to the user's checkout and returned `ready` over a stale index. If you ever see `build_failed` with `worktree_mismatch`, that guard is what caught it; fall back to grep and quote the reason.

`ensure` is **safe to run unattended** — it never downloads, installs, or prompts. It resolves a graph-capable backend, indexes the repo (or syncs an existing index), and prints one line of JSON. Branch on `.action`:

| `action` | What it means | What you do |
|---|---|---|
| `ready` | Backend found, index built and current. | Go to step 3. Read `.backend`. |
| `needs_install` | No CodeGraph CLI ≥ 1.5.0 on this machine. | Step 2 — **ask the user.** |
| `needs_build` | Only from `status`; `ensure` builds instead of returning this. | Run `ensure`. |
| `declined` | The user already said no in this repo. | Fall back to grep. Do **not** ask again. |
| `build_failed` | Backend works, but this repo can't be indexed usefully — including `worktree_mismatch`, where the index turned out to describe a different tree than the one asked about. | Fall back to grep, quoting `.reason`. |
| `unsupported_platform` | No bundle for this OS/arch. | Fall back to grep. Don't offer the install. |
| `install_failed` | The installer itself failed. | Fall back to grep, quoting `.reason`. |
| `wrapper_not_found` | **Not emitted by the wrapper — this is the resolver above returning nothing.** No `codegraph.sh` with the marker exists on this machine. | Fall back to grep. Report it as `graph unavailable: wrapper_not_found (could not locate the plugin's codegraph.sh)`. See the rule below before writing anything about *why*. |

`needs_install` and `declined` both mean the devpilot fallback was probed and also came up empty; `.reason` carries why, as `(devpilot graph fallback unusable: <code>: <message>)`. That is worth quoting — `go_no_module` tells the user something actionable.

The JSON also carries `backend`, `bin`, `version`, `graph_cache`, `index_dir`, `opted_out`, `repo`, `repo_arg`, `at_sha`, and `worktree`. Human-readable progress goes to **stderr**, JSON to **stdout** — so `"$CG" ensure --repo . --at <sha> 2>/dev/null` is a clean parse.

### Never state a cause you did not verify

A shell `No such file or directory`, a non-`ready` action, or a `fallback` payload tells you the graph is **unavailable**. It does not tell you **why**, and the two most tempting explanations — "this plugin install does not ship the wrapper", "this backend does not exist" — are exactly the ones that have been wrong in practice. Both have been published in a real PR body.

So:

- In the review body, state only what the tool returned: `graph unavailable: <verbatim reason>`. Never the diagnosis.
- Before asserting a file, script, or subcommand is absent, check the actual paths (the resolver above) or run `--help` on the actual command. `devpilot graph preflight --help` exiting 0 is what "it exists" looks like.
- If you have not verified it, it does not go in the body. An unverified diagnosis in a posted PR body is a wrong conclusion published under the author's nose — worse than saying nothing about the cause.

`ensure` re-syncs on every call, even when the index looks current. That is deliberate: CodeGraph's own pending-change counter is watcher-shaped and has been observed reporting zero for files whose content had in fact changed. A sync costs about a second; reviewing stale line numbers costs a wrong review.

### 2. When it's missing: offer the install, once

The wrapper deliberately cannot prompt (a `read` would hang any headless session). **You** ask, in one short message, then act on the answer:

> This PR touches indexable code, so I can ground the review in a real call graph — who calls each changed symbol, which are hubs, what's untested — instead of grepping. That needs the CodeGraph CLI (a ~57 MB download that unpacks to ~280 MB, because it bundles its own Node runtime; installed to `~/.local/bin`, with the bundle under `~/.codegraph`). Indexing this repo takes a few seconds and is incremental afterwards; telemetry is disabled and nothing leaves the machine. Install it?

- **Yes** → `"$CG" install --yes --repo .` — runs the official upstream installer, feature-probes the result, disables telemetry persistently, then indexes and re-emits the `ensure` JSON. On `ready`, continue to step 3.
- **No** → `"$CG" opt-out --repo .` — records a marker in the repo's git dir so no future review in this repo asks again. Then fall back to grep.

Do not install without an explicit yes; `install` without `--yes` refuses with exit 2 by design. Do not offer the install when `action` is `unsupported_platform` — there is nothing to download.

Two things to be straight about, if the user asks: the installer downloads a release tarball over TLS and untars it — it does **not** verify a checksum (`npm i -g @colbymchenry/codegraph` with a lockfile is the verifiable route, and `CODEGRAPH_BIN` points the wrapper at whatever it produced). And the index is written into the repo at `.codegraph/`; the wrapper adds it to `.git/info/exclude` so it never shows up in their `git status` or a commit.

Ask **at most once per review**. Unlike the old backend there is no language gate worth pre-checking — CodeGraph indexes Go, TS/JS, Python, Rust, Java, C#, PHP, Ruby, C/C++, Swift, Kotlin, Scala, Dart, Lua, R, Solidity, Terraform, Nix and more. Skip the offer only for a diff with no code at all (docs-only, config-only): the graph adds nothing there, so an install prompt is pure noise.

### 3. Run the preflight

```bash
"$CG" -- preflight --repo <.repo from ensure> --base <base-sha> --head <head-sha>
```

`preflight`, `context`, `impact`, `hubs`, `callers_of`, and `tests_for` are **synthesized** by `scripts/codegraph_preflight.py` from the SQLite index — CodeGraph itself ships per-symbol primitives, not a diff-shaped envelope. On the `devpilot` backend they are served by `devpilot graph` and normalised by `scripts/devpilot_graph_adapter.py`; `callers_of` and `tests_for` have no devpilot equivalent and return `mode: fallback` with `unsupported_on_devpilot_backend` rather than an invented shape. Anything else after `--` is passed to the CodeGraph CLI verbatim (`"$CG" -- query Foo --json`).

If you did not thread `ensure`'s `.repo` through, passing `--at <head-sha>` here does the same redirect as a safety net.

Cache the JSON to `$SCRATCH/pr_${num}_graph.json`. For an incremental re-review (see eligibility.md), pass `--base <last_reviewed_sha> --head <head_sha>` instead of PR base.

## Fallback triggers (skip graph, fall through to grep)

Fall back and tell the body why if **any** of:

- `ensure` returns any `action` other than `ready` (see the table above).
- `ok:false` or `data.mode != "built"` in the preflight payload.
- Preflight exits non-zero or takes > 30 s.

Note the fallback in the body's sweep summary, quoting the wrapper's `reason` verbatim so the user learns the actual cause:

```
Behavior trace: grep-only (graph unavailable: index_stale: 2 changed file(s) differ between the index and 4f21ab8c…)
```

`graph unavailable: <reason>` with a real reason is the point. "graph unavailable" alone tells the user nothing they can act on.

Two failure reasons are worth recognizing on sight:

- **`index_stale`** — the indexed copy of a changed file is not the revision under review, so every line number and edge below it would be confidently wrong. **The cause is almost always a missing `--at`**: the worktree is on the default branch because step 1 never checked head out. Re-run `"$CG" ensure --repo . --at <head-sha>` and pass the returned `.repo` to the preflight. Only if it persists *with* `--at` is grep the correct path.
- **`no_indexed_changed_files`** — the diff touches nothing CodeGraph indexed (generated files, a vendored tree, an unsupported language). Not an error; the graph simply has nothing to say about this PR.

## Payload — what each field means for the review

```jsonc
{
  "ok": true,
  "data": {
    "mode": "built",                       // anything else → skip graph; see above
    "backend": "codegraph",
    "graph": {
      "freshness": { "covers_head_sha": true, "stale_files": 0, "head_sha": "…" },
      "indexed_files": 186,
      "hub_threshold": 13,                 // this repo's p95 fan-in, floored at 8
      "unindexed_changed_files": null,     // changed files the index doesn't hold
      "cross_language_edges_ignored": 9    // discarded as unreliable; see below
    },
    "changed_symbols": [
      {
        "id": "internal/auth/oauth.go::StartFlow",
        "kind": "function",
        "is_exported": true,
        "change_type": "modified",
        "lines": [41, 68],
        "callers": {
          "count": 2,
          "same_community": 0,             // callers inside the defining package
          "in_hub": false,
          "sample": ["internal/gmail/service.go::Login"],
          "unresolved_candidates": 1,      // call sites CodeGraph saw but couldn't bind
          "caveats": ["unresolved_call_sites"],
          "confident": false               // ← read this before quoting `count`
        },
        "tests": { "has_tests": false, "test_symbols": null },
        "community": "internal/auth",
        "risk_factors": ["untested_public"]
      }
    ],
    "cross_community_edges": [
      { "from": "internal/gmail", "to": "internal/auth",
        "count_added": 7, "samples": ["…"] }
    ],
    "risk_summary": {
      "hub_nodes_modified": 0,
      "untested_public_changes": 15,
      "interface_changes": 0,
      "new_cross_community_edges": 8,
      "symbols_with_unresolved_callers": 2
    }
  }
}
```

`changed_symbols[]` also contains whole-file entries (`"kind": "file"`) for added files, alongside the symbol entries. Those carry `callers.count: 0` and `tests.has_tests: false` **by construction**, so never read them as "dead code" or "untested". Only reason about entries whose `kind` is a symbol kind (`function`, `method`, `struct`, `class`, …). Several fields (`risk_factors`, `callers.sample`, `callers.caveats`, `test_symbols`) are `null` rather than `[]` when empty.

| Field | What Agent A–E does with it |
|---|---|
| `changed_symbols[].callers.count` | Agent A's blast-radius answer — **authoritative only when `callers.confident` is true.** Then skip the grep step. |
| `changed_symbols[].callers.confident` | `false` → the count is an **upper bound**. Use it to decide where to look, never as a claim inside a finding. |
| `changed_symbols[].callers.caveats` | Why confidence dropped. See the table below. |
| `changed_symbols[].callers.in_hub` | If `true`, Agent A escalates that symbol's review and notes it in `sweep_summary.blast_radius`. Never set on a caveated symbol. |
| `changed_symbols[].tests` | Agent A and Agent B both consult. `has_tests:false` on an exported behavior change is a Should-fix finding — unless `caveats` is non-empty, in which case check the test dir before writing it up. |
| `changed_symbols[].risk_factors` | `untested_public`, `hub`, `interface_change`, `unresolved_callers` — each gates a specific finding pattern. May be `null`. |
| `cross_community_edges` | Agent A's "is this PR widening the contract between two packages?" question. A Consider-level finding only when the edge reverses the repo's existing dependency direction AND is unmentioned in the PR description; at most one consolidated finding per review (see fanout.md Agent A step 3). Otherwise a sweep-summary line. |
| `risk_summary.untested_public_changes` | Aggregate count for the body's sweep summary. |
| `risk_summary.interface_changes` | If > 0, Agent A traces implementors via `"$CG" -- context --repo . --id <iface>`. |

### `callers.caveats` — the three ways a count lies

CodeGraph binds references by name when it cannot bind them structurally, and it does not type-check receivers. The synthesizer detects the three resulting failure modes and grades the count rather than hiding them. **An empty `caveats` (`confident: true`) means the count is a fact. A non-empty one means "upper bound, go read the code".**

| Caveat | What happened | How to use the count |
|---|---|---|
| `unresolved_call_sites` | Call sites exist that CodeGraph could not bind to this symbol (a Go cross-package call with no `go.mod`, dynamic dispatch, a decorator). | The count is a **lower** bound. **Never** claim dead code or "no callers" here — that is the one wrong finding this field exists to prevent. |
| `cross_community_method_binding` | A method's callers include other packages, and bare-method-name binding across a package boundary is not receiver-typed. Observed on a real repo: `store.go::Close` with 93 "callers" — every `.Close()` in the tree. | Trust `same_community`; treat the rest as candidates. |
| `ambiguous_name` | More than one definition in the repo shares this bare name, and at least one caller lives outside the defining file. | Verify the specific caller you want to cite. |

Two whole classes of edge are dropped before you ever see them, with counts reported so you know filtering happened: cross-language edges (`graph.cross_language_edges_ignored` — a Python `.get(...)` binding to a Go method named `get` is never real) and, in the `hubs` list, symbols defined in test files.

## Confidence weighting (consumed by `confidence.md` merge step)

After the fanout returns, the main session reconciles each finding against the graph payload:

- **Corroborated** — the finding names a symbol whose callers/risk_factors match the defect, **and that symbol's `callers.confident` is true**. Confidence floor raised to 85. (Cap stays at 95 unless literal-string evidence pushes it to 100.)
- **Contradicted** — the finding asserts "X calls Y" but the graph shows Y has zero callers **with `confident: true`**, or asserts "this is a hub" but `in_hub:false`. Confidence capped at 50, which drops it under the default threshold. **Not available when `data.contradiction_allowed` is `false`** (the `devpilot` backend): treat those findings as Unsupported instead. A backend that cannot show its per-symbol resolution work does not get to kill a finding.
- **Unsupported** — the finding sits outside the graph's coverage (no symbol match, graph in fallback mode, **or the symbol's `callers.confident` is false**). No adjustment. Original score stands.

A caveated caller set can never contradict a finding — that rule is what keeps a name-collision artifact from killing a real bug. A finding can be both corroborated on one dimension and contradicted on another: take the more conservative outcome.

## Optional follow-ups

Used only when a specific surviving finding needs a deeper trace; not run by default.

```bash
"$CG" -- context    --repo . --id <symbol-id> [--depth 1]  # source + callers/callees
"$CG" -- impact     --repo . --files <path,path>           # caller union for those files
"$CG" -- callers_of --repo . --id <symbol-id> --depth 2    # transitive, level by level
"$CG" -- tests_for  --repo . --id <symbol-id>              # test symbols that reach it
"$CG" -- hubs       --repo . [--threshold N]               # repo-wide fan-in ranking
```

Symbol ids are `path/to/file.go::Name`; a bare `Name` also resolves when unambiguous. Output is appended to the inline comment as evidence, not posted as a separate finding.

## Known noise / limits

Common graph-misreading traps (dead-code claims, `change_type` false positives, dynamic dispatch invisibility) are enumerated in `rationalizations.md` rows — that's the active self-check. Graph does not replace reading code; it removes the "did I miss a caller?" anxiety.

Backend-specific limits, all by design rather than bugs to file:

- **Deleted symbols are invisible.** The index describes `head`; a symbol removed by this PR has no node. `graph.deleted_files` lists whole deleted files, but a function deleted from a surviving file never appears in `changed_symbols`. Read the diff for removals.
- **`change_type` is name-based.** "Added" means the name did not exist in that file at `base`. A symbol moved between files reads as `added` in one and simply vanishes from the other.
- **`community` is the directory.** There is no clustering pass, so a package split across directories reads as several communities.
- **`cross_community_edges[].count_added` counts call sites inside this diff's changed lines**, not edges diffed against a base-revision graph. An unchanged call site that always crossed the boundary is not reported.
- **Go resolves better with `go.mod`.** Without it a cross-package call lands in `unresolved_refs` → `unresolved_call_sites`. Indexing still succeeds, which is the whole point of the backend swap, but expect lower-confidence counts in a manifest-less tree.
- **`is_exported` is syntactic.** For Python/Ruby/Lua/Elixir and friends, where no syntax marks visibility, the synthesizer falls back to the leading-underscore convention.
- **`untested_public` only fires on behavior kinds** (function, method, class, struct, interface, …). A changed public constant is reported as a changed symbol but never scored as untested.
- **The opt-out marker is repo-wide**, keyed on the common git dir, so declining in one worktree holds in the others and in the `--at` indexing worktree. (It used to be per-worktree, which re-asked on every worktree.)
- **On the `devpilot` backend**, `lines`, `same_community`, `unresolved_candidates`, `indexed_files`, `hub_threshold`, and `cross_language_edges_ignored` are all `null` — devpilot does not compute them. `symbols_with_unresolved_callers` is `0` by construction, not by measurement: a repo devpilot cannot resolve fails to index at all. And it holds only whole-repo `freshness.covers_base_sha`; the adapter recomputes `covers_head_sha` from git and fails the payload closed with `index_stale` when the indexed tree is not the reviewed revision.
- **A schema change upstream fails the payload closed.** `codegraph_preflight.py` asserts the tables and columns it reads and returns `mode:"fallback"` with `schema_drift` rather than quoting invented facts. If you see that, the CLI outran the synthesizer — update `scripts/codegraph_preflight.py`.
