# Changelog

## 1.6.0 — 2026-07-29

- **Removed the `pr-review-queue` skill.** It duplicated `batch-review-prs` with a
  thinner feature set — no claim labels, no already-reviewed-at-HEAD dedup, no
  local-checkout syncing — and its overlapping description made queue requests
  route unpredictably between the two. `batch-review-prs` is now the only
  review-queue skill. The one capability lost is discovery via the `devpilot
  github prs review-queue` CLI; `batch-review-prs` discovers with `gh api
  search/issues` instead.

- **The codegraph backend is now [CodeGraph](https://github.com/colbymchenry/codegraph),
  not `devpilot graph`.** The old backend could only index a repo whose module
  graph it could resolve, so a Go tree without `go.mod`, or any Python / Java /
  Ruby / PHP repo, returned `build_failed` and the review silently became
  grep-only — the single most common reason the graph "didn't work". CodeGraph is
  tree-sitter based across 20+ languages and needs no manifest and no compiler.
  `scripts/codegraph.sh` keeps the exact same contract (`status` / `ensure` /
  `install --yes` / `opt-out` / `reset-consent` / `-- <args>`, one line of JSON on
  stdout, notes on stderr), so skills did not have to learn a new interface.
  - **New `scripts/codegraph_preflight.py`** synthesizes the diff-shaped payload
    the skills actually consume — `preflight`, `context`, `impact`, `hubs`,
    `callers_of`, `tests_for` — in one pass over CodeGraph's SQLite index.
    CodeGraph ships per-symbol primitives only; shelling out per symbol would
    cost more in process launches than the whole index.
  - **Caller counts are graded, not asserted.** CodeGraph binds references by
    name and does not type-check receivers, which produces confident nonsense
    (`store.go::Close` with 93 "callers" — every `.Close()` in the tree; a Python
    `.get(...)` bound to a Go method named `get`). Every count now carries
    `confident` and `caveats` (`unresolved_call_sites`,
    `cross_community_method_binding`, `ambiguous_name`); cross-language edges are
    dropped with the count reported. `confidence.md`'s rules were tightened to
    match: a caveated caller set can corroborate nothing and **contradict
    nothing**, so a name-collision artifact can no longer kill a real finding.
  - **A stale index fails closed.** `preflight` sha256-compares every changed
    file against the blob at `head` and returns `mode:"fallback"` with
    `index_stale` rather than reporting line numbers from a different revision.
    Correspondingly `ensure` re-syncs on *every* call: CodeGraph's own
    pending-change counter is watcher-shaped and was observed reporting 0 for
    files whose content had changed.
  - **No side effects on the reviewed repo.** Every CodeGraph child process runs
    with telemetry off (`CODEGRAPH_TELEMETRY=0`, `DO_NOT_TRACK=1`) and the watcher
    daemon disabled (`CODEGRAPH_NO_DAEMON=1`), and the in-repo `.codegraph/` index
    is added to `.git/info/exclude` so a review never dirties `git status`.
  - Honest about the install path: the upstream installer downloads a ~57 MB
    release tarball over TLS (~280 MB unpacked — it vendors a Node runtime) and
    does **not** verify a checksum (the old README claimed
    checksum verification for devpilot's installer). `npm i -g
    @colbymchenry/codegraph` with a lockfile plus `CODEGRAPH_BIN` is the
    verifiable route, and both `graph.md` and the README now say so.
- **`devpilot:repo-scan` finally goes through the wrapper too** (the open TODO
  from 1.5.0). Step 2.4 runs `codegraph.sh ensure` + `-- hubs` and branches on the
  JSON `action`; `security-scanner`, `edge-case-hunter`, and `coverage-auditor`
  now call `"$CG" -- callers_of / tests_for / context`. Their verdict rules learned
  the caveat semantics: an empty caller set with `confident:false` is a resolution
  gap, not dead code, and a hub with non-empty `caveats` earns no severity
  upgrade. **Nothing in the plugin invokes `devpilot graph` any more.**
- `driver.sh codegraph` grew to 11 assertions, adding the two regressions this
  change is most likely to reintroduce: the index must not dirty the fixture's
  `git status`, and a stale index must return `mode:"fallback"`.

## 1.5.0 — 2026-07-28

- **`devpilot:pr-review` now bootstraps the codegraph instead of silently
  degrading.** Previously, a user who had never installed the `devpilot` CLI got
  a grep-only review forever and was never told the graph existed. Step 1.5 now
  goes through the new `scripts/codegraph.sh`, which resolves a graph-capable
  binary from five locations (feature-probing `graph preflight` rather than
  comparing version strings), reports `needs_install` when there is none so the
  skill can *offer* the install, runs the official checksum-verified upstream
  installer on explicit consent, builds a cold graph cache, and records a
  per-repo opt-out so anyone who declines is never asked again. The wrapper is
  strictly non-interactive — a prompt inside it would hang every `claude -p`
  session, so the agent asks and the script acts.
  - Reverses the old "do **not** auto-run `devpilot graph build`" rule: `ensure`
    builds. A review that talks the user into installing the binary and then
    still reports "graph unavailable" is worse than a few seconds of indexing.
  - Fallback lines now quote the wrapper's real reason
    (`graph unavailable: go_no_module: repo contains .go files but no go.mod`)
    instead of an unactionable "graph unavailable".
  - `references/graph.md` documents the full action table, consent script, and
    three payload traps (whole-file `kind:"file"` entries that always look
    untested and uncalled; `null`-instead-of-`[]` fields; `graph build` exiting
    0 while reporting `ok:false`).
  - `pr-review`'s other two devpilot touchpoints (`pr-review preflight`,
    `pr-review post`) are unchanged and remain optimizations with `gh` as the
    contract. Nothing in the skill invokes `devpilot graph` directly any more.
- **New `/run-devpilot-plugin` skill** (`.claude/skills/run-devpilot-plugin/`)
  with a committed `driver.sh` that actually drives this repo: `smoke` asserts
  the nine `codegraph.sh` states against a generated Go fixture repo, and
  `headless present|missing|declined` runs a real `claude -p` session executing a
  skill from the working tree. The headless path deliberately shadows via a
  scratch *project* skill, because `--plugin-dir` loses to any installed copy of
  this plugin and will report success while testing stale code.

## 1.4.0 — 2026-07-28

- **New skill `devpilot:batch-review-prs`** + `/batch-review-prs` command: sweeps
  your GitHub review inbox using only `gh` — unions `review-requested:@me`,
  `reviewed-by:@me`, and `author:@me`; drops drafts, bots, PRs already reviewed at
  the current HEAD SHA, and PRs already claimed by two other reviewers; syncs local
  checkouts; then claims each PR with a `reviewing:<name>` label and hands it to
  `devpilot:pr-review` sequentially. All discovery/filtering runs in one subagent so
  raw `gh api` JSON never enters the main context. Ported from `sq-vsdevx`.
  Complements `devpilot:pr-review-queue`, which uses the `devpilot` CLI for discovery.
- **New skill `devpilot:grilling`** + `/grill` command: stress-tests a plan, decision,
  or design by interviewing you one question at a time, walking the decision tree
  branch by branch. Landed in PR #6 without a changelog entry; recorded here since
  1.3.0 was the last release before it.

## 1.3.0 — 2026-07-21

- **New SessionStart hook** (`hooks/hooks.json` + `scripts/refresh-default-branch.sh`):
  on every session start, keeps the local default branch up to date with the
  remote without touching the current branch or working tree. On a feature
  branch it fast-forwards the local default ref via refspec (no checkout); on a
  clean default branch it `--ff-only` updates; on a dirty tree it skips and
  prints a hint. Ships with the plugin, so every install gets it.

## 1.2.0 — 2026-07-21

- **New skill `devpilot:pr-guard`** + `/pr-guard` command: after a PR/MR exists,
  drives it to a mergeable, green state — polls CI/GitHub Actions, resolves merge
  conflicts against the base branch (merge, never force-push), reads failing-check
  logs, applies scoped fixes, pushes, and re-polls in a bounded loop with
  no-progress and round caps. Hard-stops on semantic conflicts, missing
  secrets/approvals, or required human review.
- `devpilot:pr-creator` now documents an optional hand-off to `devpilot:pr-guard`
  after creating a PR.

## 1.1.0 — 2026-07-21

- **agents/**: the six pr-review fanout briefs (A–F) are now plugin agent
  definitions (`devpilot:pr-review-*`) with fixed system prompts and read-only
  tool whitelists; `skills/pr-review/references/fanout.md` slimmed to dispatch
  instructions with a standalone fallback.
- **commands/**: thin slash-command entry points — `/pr-review`, `/repo-scan`,
  `/dead-code`, `/resolve-issues`, `/pr`.
- **CI**: GitHub Action (`validate.yml`) runs `scripts/validate.py` — checks
  plugin manifests, skill/agent/command frontmatter, `devpilot:<skill>`
  cross-references, residual old-style `devpilot-` prefixes, and README skill
  table drift.
- Fixed a migration artifact in `skills/harness-engineering/evals/README.md`
  (a workspace directory name mis-rewritten as a skill reference).
- Consolidated 11 identical per-skill Apache-2.0 `LICENSE.txt` copies into a
  single root `LICENSE-APACHE-2.0.txt`.
- De-duplicated plugin/marketplace descriptions.

## 1.0.0

- Initial plugin packaging: 25 skills migrated from `devpilot/skills/` with the
  `devpilot-` prefix dropped and cross-references rewritten to
  `devpilot:<skill>`.
