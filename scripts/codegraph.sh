#!/usr/bin/env bash
# devpilot-codegraph-wrapper — do not remove this marker. Callers that must find
# this file without a reliable ${CLAUDE_PLUGIN_ROOT} grep for it to confirm that
# a candidate `scripts/codegraph.sh` is *this* wrapper and not a same-named file
# in the repo under review. See skills/pr-review/references/graph.md.
#
# codegraph.sh — the plugin's only entry point to the code graph.
#
# Two backends, in preference order:
#
#   1. CodeGraph (https://github.com/colbymchenry/codegraph) — a tree-sitter
#      indexer over 20+ languages that writes a SQLite graph into `.codegraph/`.
#      Preferred because it needs no build manifest and no compiler.
#   2. `devpilot graph` — used when CodeGraph is not installed AND devpilot can
#      index this particular repo. It cannot index a repo whose module graph it
#      can't resolve (a Go tree without go.mod fails with `go_no_module`), which
#      is why it is not the default. But when it *does* work it is already on
#      PATH, so probing it before offering a ~57 MB download is free.
#
# Its payload is NOT field-compatible with CodeGraph's — no `lines`, no
# `callers.confident`/`caveats`, `freshness.covers_base_sha` instead of
# `covers_head_sha` — so `-- preflight` routes it through
# scripts/devpilot_graph_adapter.py, which normalises it and marks the fields it
# cannot supply. Callers read `backend` from the JSON and never assume.
#
# Skills MUST NOT call `codegraph` directly. They call this wrapper, which owns
# five things the skills should not each reimplement:
#
#   1. Resolution   — finds the CLI in the places it can actually live (the
#                     bundle installer's symlink, npm global, Homebrew), not
#                     just $PATH, and enforces a minimum version.
#   2. Bootstrap    — when nothing is installed, reports `needs_install`, and on
#                     an explicit `install --yes` runs the official upstream
#                     installer into a writable dir.
#   3. Cold cache   — `ensure` indexes the repo when the CLI is present but the
#                     repo has no `.codegraph/` yet, and syncs it when the index
#                     has drifted. Without this, a fresh install still yields
#                     mode:"fallback" on the first review.
#   4. Consent      — a per-repo opt-out marker so a user who says "no" once is
#                     never asked again in that repo.
#   5. Preflight    — CodeGraph ships per-symbol primitives, not the diff-shaped
#                     risk envelope pr-review needs. `-- preflight/context/impact`
#                     is synthesized by scripts/codegraph_preflight.py from the
#                     SQLite index; anything else after `--` passes through to
#                     the CodeGraph CLI verbatim.
#
# NON-INTERACTIVE BY DESIGN. This script never prompts. A `read` here would hang
# any headless (`claude -p`) session forever. The *agent* asks the user for
# consent and then calls `install --yes`. `status` and `ensure` are always safe
# to run unattended: neither downloads nor installs anything.
#
# PRIVACY / SIDE EFFECTS. Every CodeGraph invocation here runs with telemetry
# off and the background watcher daemon disabled — a review must not phone home
# about a private repo, and must not leave a file watcher running after it ends.
# The index lives in the repo at `.codegraph/`, so `ensure` also adds it to
# `.git/info/exclude` (local, uncommitted) rather than dirtying `git status`.
#
# Every subcommand prints one line of JSON on stdout and human-readable notes on
# stderr, so callers can `| python3 -c ...` without stripping chatter.
#
# Usage:
#   codegraph.sh status  [--repo DIR] [--at SHA]
#   codegraph.sh ensure  [--repo DIR] [--at SHA]
#   codegraph.sh install --yes [--dir DIR] [--version X.Y.Z]
#   codegraph.sh opt-out [--repo DIR]
#   codegraph.sh reset-consent [--repo DIR]
#   codegraph.sh -- preflight --repo DIR --base A --head B   # synthesized
#   codegraph.sh -- query Foo --json                         # straight through
#
# `--at SHA` is the answer to "the preflight always says index_stale". Preflight
# requires the index to describe the revision under review, but a reviewer who
# ran `gh pr view` / `gh pr diff` never checked the head branch out — the
# worktree is still on the default branch, so every changed file mismatches.
# With `--at`, `ensure` materialises the revision under review as a detached
# shared clone under ${XDG_STATE_HOME:-~/.local/state}/devpilot-plugin/
# graph-trees/, indexes THAT, and returns its path in the JSON `repo` field.
# Callers MUST pass the returned `.repo` to `-- preflight --repo`, not their own
# cwd. The user's checkout is never touched. Trees are cached per (repo, SHA);
# `rm -rf` that directory to reclaim the space.
#
# Exit codes: 0 = the requested action succeeded (for status/ensure: JSON is
# valid and describes reality, even when action != "ready"); 1 = the wrapper
# itself failed; 2 = usage error. Callers should branch on the JSON `action`
# field, not on the exit code, for the ready/needs_install/declined distinction.

set -uo pipefail

INSTALLER_URL="https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh"

# The floor, not a pin. 1.5.0 is the first release with `--json` on the query
# commands and the `unresolved_refs.name_tail` column the preflight synthesizer
# reads. Newer is welcome; codegraph_preflight.py asserts the DB schema itself
# and degrades loudly if upstream moves it.
MIN_VERSION="1.5.0"

REPO_DIR="$PWD"
INSTALL_DIR=""
INSTALL_VERSION=""
ASSUME_YES="no"

REPO_ARG=""      # what the caller asked for, before --at redirects REPO_DIR
AT_SHA=""
WORKTREE=""      # non-empty when --at built one; reported in the JSON
BACKEND=""       # codegraph | devpilot, decided by resolution
DEVPILOT_REASON=""  # why the devpilot backend was not usable, if it was tried

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFLIGHT_PY="$HERE/codegraph_preflight.py"
DEVPILOT_ADAPTER_PY="$HERE/devpilot_graph_adapter.py"

# Applies to every child `codegraph` process. DO_NOT_TRACK is honoured too; set
# both so neither an upstream rename nor a stale bundle re-enables reporting.
export CODEGRAPH_TELEMETRY=0
export DO_NOT_TRACK=1
export CODEGRAPH_NO_DAEMON=1
export NO_COLOR=1

note() { printf '%s\n' "$*" >&2; }
die() { note "codegraph.sh: $*"; exit "${2:-1}"; }

# Minimal JSON string escaping — enough for the paths, versions, and reason
# strings this script produces (backslash, double quote, tab, newline).
jstr() {
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\n'/\\n}
  printf '"%s"' "$s"
}

jbool() { [ "${1:-no}" = "yes" ] && printf 'true' || printf 'false'; }

# --- consent marker ----------------------------------------------------------
# Prefer the repo's own .git dir: repo-scoped, never committed, and it
# disappears with the clone. Outside a repo, fall back to a global state file.
#
# Use the COMMON git dir, not the per-worktree one. Two reasons: a decision the
# user made in one worktree should hold in the others (they are one repo and one
# CodeGraph install), and `--at` indexes a detached worktree — resolving the
# marker there would silently forget an opt-out and re-ask on every review.
consent_marker() {
  local gitdir
  if gitdir=$(git -C "${REPO_ARG:-$REPO_DIR}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
     && [ -n "$gitdir" ]; then
    printf '%s/devpilot-codegraph-optout' "$gitdir"
  elif gitdir=$(git -C "${REPO_ARG:-$REPO_DIR}" rev-parse --absolute-git-dir 2>/dev/null); then
    printf '%s/devpilot-codegraph-optout' "$gitdir"
  else
    printf '%s/devpilot-plugin/codegraph-optout-global' \
      "${XDG_STATE_HOME:-$HOME/.local/state}"
  fi
}

opted_out() { [ -f "$(consent_marker)" ]; }

# --- resolution --------------------------------------------------------------
# A binary only counts if it is new enough to answer the queries the preflight
# synthesizer needs, so compare the version rather than merely finding a file.
version_ok() {
  local have=$1
  [ -n "$have" ] || return 1
  printf '%s\n%s\n' "$MIN_VERSION" "$have" |
    sort -t. -k1,1n -k2,2n -k3,3n -C 2>/dev/null && return 0
  # sort -C succeeds only when already sorted, i.e. MIN <= have.
  return 1
}

bin_version() {
  "$1" version 2>/dev/null | tr -d '\r' | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

graph_capable() {
  local bin=$1
  [ -x "$bin" ] && [ ! -d "$bin" ] || return 1
  version_ok "$(bin_version "$bin")"
}

resolve_bin() {
  local candidate npm_bin
  # Explicit override wins, and is how the driver tests the not-installed path.
  if [ -n "${CODEGRAPH_BIN:-}" ]; then
    graph_capable "$CODEGRAPH_BIN" && { printf '%s' "$CODEGRAPH_BIN"; return 0; }
    return 1
  fi
  if candidate=$(command -v codegraph 2>/dev/null); then
    graph_capable "$candidate" && { printf '%s' "$candidate"; return 0; }
  fi
  # `~/.codegraph/current/bin` is where the bundle installer puts the real
  # launcher; ~/.local/bin/codegraph is its symlink. Check both so a broken
  # symlink (or a PATH-less shell) still resolves.
  for candidate in \
    "${CODEGRAPH_BIN_DIR:-$HOME/.local/bin}/codegraph" \
    "${CODEGRAPH_INSTALL_DIR:-$HOME/.codegraph}/current/bin/codegraph" \
    "/usr/local/bin/codegraph" \
    "/opt/homebrew/bin/codegraph"
  do
    graph_capable "$candidate" && { printf '%s' "$candidate"; return 0; }
  done
  # npm global installs land outside all of the above under asdf/nvm/volta.
  if npm_bin=$(npm prefix -g 2>/dev/null); then
    candidate="$npm_bin/bin/codegraph"
    graph_capable "$candidate" && { printf '%s' "$candidate"; return 0; }
  fi
  return 1
}

# --- backend 2: devpilot graph -----------------------------------------------
# `devpilot graph preflight` predates this wrapper and is already on PATH for
# anyone using the CLI. It is the cheaper backend when it works at all, so probe
# it before telling the user to download 280 MB. It is second, not first, because
# it refuses whole repos: no go.mod in a Go tree, no resolvable module graph.
devpilot_bin() {
  local candidate
  candidate=${DEVPILOT_BIN:-$(command -v devpilot 2>/dev/null)} || return 1
  [ -n "$candidate" ] && [ -x "$candidate" ] || return 1
  "$candidate" graph preflight --help >/dev/null 2>&1 || return 1
  printf '%s' "$candidate"
}

devpilot_version() {
  { "$1" version 2>/dev/null; "$1" --version 2>/dev/null; } \
    | tr -d '\r' | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# Read `.ok` / `.error.code: message` out of a devpilot JSON envelope.
devpilot_envelope() {
  printf '%s' "$1" | python3 -c '
import json,sys
raw = sys.stdin.read()
# devpilot prints one JSON object; tolerate leading chatter.
i = raw.find("{")
try:
    d = json.loads(raw[i:]) if i >= 0 else {}
except Exception:
    print("parse_error\tcould not parse devpilot output"); raise SystemExit
if d.get("ok"):
    print("ok\t")
else:
    e = d.get("error") or {}
    print("%s\t%s" % (e.get("code") or "unknown", e.get("message") or ""))
' 2>/dev/null || printf 'parse_error\tcould not parse devpilot output'
}

# try_devpilot_backend <may_build:yes|no>
# On success sets BACKEND=devpilot and emits `ready`; returns 0 either way, with
# 1 meaning "not usable here" so the caller falls through to needs_install.
try_devpilot_backend() {
  local may_build=$1 bin version out state code msg
  # Always leave a reason behind, even for "not installed": `needs_install` has
  # to say whether the fallback was probed and came up empty, or was never
  # reachable at all. A bare reason reads as "not probed".
  bin=$(devpilot_bin) || {
    DEVPILOT_REASON="no_graph_capable_devpilot: no devpilot on PATH with \`graph preflight\`"
    return 1
  }
  version=$(devpilot_version "$bin")

  out=$("$bin" graph status --repo "$REPO_DIR" 2>&1)
  state=$(devpilot_envelope "$out")
  code=${state%%$'\t'*}; msg=${state#*$'\t'}

  if [ "$code" != "ok" ]; then
    [ "$may_build" = "yes" ] || { DEVPILOT_REASON="$code: $msg"; return 1; }
    note "devpilot graph: building cache for ${REPO_DIR}…"
    out=$("$bin" graph build --repo "$REPO_DIR" 2>&1)
    state=$(devpilot_envelope "$out")
    code=${state%%$'\t'*}; msg=${state#*$'\t'}
  fi

  if [ "$code" != "ok" ]; then
    # go_no_module and friends: this repo is exactly what CodeGraph exists for.
    DEVPILOT_REASON="$code: $msg"
    return 1
  fi
  BACKEND=devpilot
  emit ready "devpilot graph cache ready (no CodeGraph install needed)" \
    "$bin" "$version" built
  return 0
}

# install.sh publishes bundles for exactly these triples. On anything else there
# is nothing to download, so say so instead of failing mid-curl.
platform_supported() {
  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  case "$(uname -m)" in
    x86_64 | amd64) arch=x64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) return 1 ;;
  esac
  case "${os}-${arch}" in
    darwin-arm64 | darwin-x64 | linux-arm64 | linux-x64) return 0 ;;
    *) return 1 ;;
  esac
}

# --- --at: index the revision under review, not whatever the worktree is on ---
# The documented review flow is `gh pr view` + `gh pr diff` — neither checks the
# head branch out. So the index describes the default branch while the diff
# describes the PR head, and the preflight synthesizer (correctly) refuses with
# `index_stale`. Rather than tell every skill to juggle checkouts, the wrapper
# materialises a detached worktree at the reviewed SHA and indexes that.
#
# Two decisions here, both forced by how CodeGraph resolves a project root.
#
# 1. It is a `git clone --shared`, not a `git worktree add`. A linked worktree
#    keeps pointing at the parent's git dir, and CodeGraph resolves a project by
#    walking to the *main* worktree root — so indexing a linked worktree silently
#    indexes and reads the user's checkout, and reports `ready` while serving the
#    exact stale data --at exists to avoid. `--shared` copies no objects and
#    `--no-checkout` keeps the one checkout we do explicit.
# 2. It lives OUTSIDE the repo, under the user's state dir. Inside `.git/` was
#    the tidier place, but CodeGraph keeps walking past a nested repo's own
#    `.git` to the outermost one, so anything under the parent still resolved to
#    the parent. (`cache_state` now returns `mismatch` when that happens, so a
#    future backend change surfaces as a loud build_failed, not a wrong review.)
#
# Trees are keyed by repo path + SHA and reused across reviews of the same SHA,
# so a re-review costs nothing. They are deliberately not deleted afterwards:
# that would throw away the index that makes the next incremental review cheap.
graph_tree_root() {
  printf '%s/devpilot-plugin/graph-trees' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

resolve_at_worktree() {
  local sha=$1 head short wt slug
  git -C "$REPO_ARG" rev-parse --git-dir >/dev/null 2>&1 || {
    note "codegraph: --at $sha ignored — $REPO_ARG is not a git repo"
    return 1
  }
  # Nothing to do when the checkout is already the revision under review.
  head=$(git -C "$REPO_ARG" rev-parse HEAD 2>/dev/null)
  if [ -n "$head" ] && [ "${head#"$sha"}" != "$head" ]; then return 1; fi

  git -C "$REPO_ARG" cat-file -e "${sha}^{commit}" 2>/dev/null || {
    note "codegraph: --at $sha is not a commit in this repo (fetch it first)"
    return 1
  }
  short=$(git -C "$REPO_ARG" rev-parse --short=12 "$sha")
  # Key on the repo path too: two clones of the same upstream reviewed at the
  # same SHA are still two different trees to the user.
  slug="$(basename "$REPO_ARG")-$(printf '%s' "$REPO_ARG" | cksum | cut -d' ' -f1)"
  wt="$(graph_tree_root)/$slug/$short"

  # NOTE: this runs inside $( ), so any variable set here is lost. The path goes
  # out on stdout and the caller assigns both REPO_DIR and WORKTREE.
  if [ -d "$wt/.git" ]; then printf '%s' "$wt"; return 0; fi

  rm -rf "$wt" 2>/dev/null   # a half-built tree from an interrupted run
  mkdir -p "$(dirname "$wt")" 2>/dev/null
  note "codegraph: materialising the reviewed revision $short for indexing…"
  if ! git clone --shared --no-checkout --quiet "$REPO_ARG" "$wt" 2>/dev/null; then
    note "codegraph: could not clone $REPO_ARG to $wt — indexing the current tree instead"
    return 1
  fi
  # --detach: the clone has no branch at this SHA and never needs one. Nothing
  # here can touch a ref in the user's repo — a --shared clone shares objects,
  # not refs.
  if ! git -C "$wt" checkout --detach --quiet "$sha" 2>/dev/null; then
    note "codegraph: could not check out $short in $wt — indexing the current tree instead"
    rm -rf "$wt" 2>/dev/null
    return 1
  fi
  printf '%s' "$wt"
}

# --- index state -------------------------------------------------------------
index_dir() { printf '%s/%s' "$REPO_DIR" "${CODEGRAPH_DIR:-.codegraph}"; }

# `codegraph status --json` is the only honest answer to "is this repo usable".
# Prints one of: built | stale | cold | empty | unknown
#   built  — complete index with nodes and nothing pending
#   stale  — indexed, but files changed since (needs `sync`)
#   cold   — never indexed here
#   empty  — indexed and found nothing: no supported source files
#   mismatch — CodeGraph redirected the project root somewhere else, so this
#              index does not describe the tree we asked about
cache_state() {
  local bin=$1 out
  out=$("$bin" status "$REPO_DIR" --json 2>/dev/null)
  [ -n "$out" ] || { printf 'unknown'; return; }
  printf '%s' "$out" | python3 -c '
import json,os,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("unknown"); sys.exit()
# CodeGraph resolves a project by walking to the main worktree root, so asking
# about a linked worktree silently answers about its parent — and would report
# `built` for an index of a different revision. Never let that read as ready.
asked = os.path.realpath(sys.argv[1])
got = d.get("projectPath")
if got and os.path.realpath(got) != asked:
    print("mismatch"); sys.exit()
if not d.get("initialized"):
    print("cold"); sys.exit()
idx = d.get("index") or {}
pending = d.get("pendingChanges") or {}
drift = sum(v for v in pending.values() if isinstance(v, int))
if (d.get("nodeCount") or 0) == 0:
    print("empty")
elif idx.get("state") != "complete" or idx.get("reindexRecommended"):
    print("stale")
elif drift > 0:
    print("stale")
else:
    print("built")
' "$REPO_DIR" 2>/dev/null || printf 'unknown'
}

# `.codegraph/` is written into the repo under review. Excluding it locally
# keeps `git status` clean for the user without committing anything: a review
# must not make the working tree look dirty to the developer we are reviewing.
exclude_index_locally() {
  local gitdir exclude entry
  # Common git dir: git reads $GIT_COMMON_DIR/info/exclude, so writing the
  # per-worktree path would leave `.codegraph/` visible in `git status`.
  gitdir=$(git -C "$REPO_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  [ -n "$gitdir" ] || gitdir=$(git -C "$REPO_DIR" rev-parse --absolute-git-dir 2>/dev/null) || return 0
  exclude="$gitdir/info/exclude"
  entry="/${CODEGRAPH_DIR:-.codegraph}/"
  mkdir -p "$(dirname "$exclude")" 2>/dev/null || return 0
  grep -qxF "$entry" "$exclude" 2>/dev/null && return 0
  printf '%s\n' "$entry" >>"$exclude" 2>/dev/null || true
}

# Pull the failure out of CodeGraph's own chatter. Its CLI prints a boxed
# progress log rather than a JSON envelope, so take the last non-empty line —
# which is where its errors land — and cap it. The skill quotes this verbatim as
# `graph unavailable: <reason>`, so a user seeing "grep-only" learns why.
last_error_line() {
  printf '%s' "$1" | tr -d '\r' \
    | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^[│┌└●◆◇▲ ]*//' \
    | grep -v '^[[:space:]]*$' | tail -3 | tr '\n' ' ' | cut -c1-300
}

emit() {
  # emit <action> <reason> [bin] [version] [cache]
  # `repo` is the directory the index actually describes — with --at that is the
  # detached worktree, NOT what the caller passed as --repo. Callers must feed
  # `.repo` back into `-- preflight --repo`; `repo_arg` is kept for diagnostics.
  printf '{"action":%s,"reason":%s,"backend":%s,"bin":%s,"version":%s,"graph_cache":%s,"index_dir":%s,"opted_out":%s,"repo":%s,"repo_arg":%s,"at_sha":%s,"worktree":%s}\n' \
    "$(jstr "$1")" "$(jstr "$2")" "$(jstr "${BACKEND:-}")" \
    "$(jstr "${3-}")" "$(jstr "${4-}")" \
    "$(jstr "${5-unknown}")" "$(jstr "$(index_dir)")" \
    "$(jbool "$(opted_out && echo yes || echo no)")" "$(jstr "$REPO_DIR")" \
    "$(jstr "${REPO_ARG:-$REPO_DIR}")" "$(jstr "$AT_SHA")" "$(jstr "$WORKTREE")"
}

# --- subcommands -------------------------------------------------------------

cmd_status() {
  # cmd_status [may_build] — `ensure` passes yes so the devpilot fallback is
  # allowed to build its cache; bare `status` stays side-effect free.
  local may_build=${1:-no}
  local bin version cache
  if bin=$(resolve_bin); then
    BACKEND=codegraph
    version=$(bin_version "$bin")
    cache=$(cache_state "$bin")
    case $cache in
      built) emit ready "index is built and current for this repo" "$bin" "$version" "$cache" ;;
      empty) emit build_failed \
        "no_supported_sources: codegraph indexed this repo and found no symbols" \
        "$bin" "$version" "$cache" ;;
      stale) emit needs_build "index exists but has drifted from the working tree" \
        "$bin" "$version" "$cache" ;;
      mismatch) emit build_failed \
        "worktree_mismatch: codegraph resolved this path to a different project root, so its index describes another revision" \
        "$bin" "$version" "$cache" ;;
      *) emit needs_build "CLI found but this repo has no index yet" \
        "$bin" "$version" "$cache" ;;
    esac
    return 0
  fi
  # No CodeGraph. Before asking the user to download 280 MB — or before honouring
  # an opt-out that was only ever about that download — see whether the devpilot
  # already on PATH can index this repo. When it can, the review gets a graph for
  # free, and an opted-out repo gets one too.
  try_devpilot_backend "$may_build" && return 0

  local dp_note=""
  [ -n "$DEVPILOT_REASON" ] && dp_note=" (devpilot graph fallback unusable: $DEVPILOT_REASON)"

  if opted_out; then
    emit declined \
      "user previously declined the codegraph install in this repo$dp_note" \
      "" "" unknown
  elif platform_supported; then
    emit needs_install "no codegraph CLI >= $MIN_VERSION found$dp_note" "" "" unknown
  else
    emit unsupported_platform \
      "no codegraph bundle for $(uname -s)/$(uname -m)$dp_note" "" "" unknown
  fi
  return 0
}

cmd_ensure() {
  local bin version cache started elapsed run_out
  if opted_out; then
    # The opt-out covers the CodeGraph download only. devpilot graph installs
    # nothing, so trying it here does not reopen a question the user closed.
    try_devpilot_backend yes && return 0
    emit declined "user previously declined the codegraph install in this repo" \
      "" "" unknown
    return 0
  fi
  if ! bin=$(resolve_bin); then
    cmd_status yes
    return 0
  fi
  BACKEND=codegraph
  version=$(bin_version "$bin")
  cache=$(cache_state "$bin")
  if [ "$cache" = "empty" ]; then
    emit build_failed \
      "no_supported_sources: codegraph indexed this repo and found no symbols" \
      "$bin" "$version" "$cache"
    return 0
  fi

  exclude_index_locally
  # The build. pr-review used to forbid auto-building; ensure() is the sanctioned
  # place for it, because a review that installs the CLI and then still reports
  # "graph unavailable" is worse than a few seconds of indexing.
  #
  # `cold` gets a full init. EVERY other state gets a sync — including `built`.
  # Do not "optimize" that into an early return: `built` only means CodeGraph's
  # own `pendingChanges` was 0, and that counter has been observed reporting 0
  # for files whose content had in fact changed (it is mtime//watcher-shaped, and
  # the watcher is deliberately off here). The preflight synthesizer catches the
  # drift by hashing the head blob, but by then the choice is already between a
  # grep-only review and stale line numbers. `sync` is incremental — sub-second
  # on a clean index — so paying it on every review is the cheap half of the deal.
  started=$(date +%s)
  local verb
  if [ "$cache" != "cold" ]; then
    verb=synced
    # Braces are load-bearing: bash's identifier scan swallows the following
    # multibyte "…" into the variable name, and under `set -u` that aborts
    # `ensure` on every warm-index review. Keep ${} around any var before it.
    note "codegraph: syncing index for ${REPO_DIR}…"
    run_out=$("$bin" sync "$REPO_DIR" 2>&1)
  else
    verb=built
    note "codegraph: indexing $REPO_DIR (first run only)…"
    run_out=$("$bin" init "$REPO_DIR" 2>&1)
  fi
  elapsed=$(( $(date +%s) - started ))
  cache=$(cache_state "$bin")

  # Do NOT branch on the exit code: CodeGraph can exit 0 having indexed nothing
  # usable (an unsupported-language tree), and can exit non-zero after a partial
  # index. The re-read state is the truth.
  case $cache in
    built)
      note "codegraph: index ready in ${elapsed}s"
      emit ready "index $verb in ${elapsed}s" "$bin" "$version" "$cache" ;;
    empty)
      emit build_failed \
        "no_supported_sources: codegraph indexed this repo and found no symbols" \
        "$bin" "$version" "$cache" ;;
    mismatch)
      emit build_failed \
        "worktree_mismatch: codegraph resolved $REPO_DIR to a different project root, so its index describes another revision" \
        "$bin" "$version" "$cache" ;;
    stale)
      # A sync that leaves drift behind usually means a lock held by another
      # session, which `unlock` clears — but that is the user's call, not ours.
      emit build_failed \
        "index still reports pending changes after sync: $(last_error_line "$run_out")" \
        "$bin" "$version" "$cache" ;;
    *)
      emit build_failed "$(last_error_line "$run_out")" "$bin" "$version" "$cache" ;;
  esac
  return 0
}

cmd_install() {
  [ "$ASSUME_YES" = "yes" ] || die "install requires --yes (ask the user first)" 2
  platform_supported || {
    emit unsupported_platform \
      "no codegraph bundle for $(uname -s)/$(uname -m)" "" "" unknown
    return 0
  }

  # Default to dirs we can write without sudo. The bundle (~50 MB, vendored Node
  # runtime) goes in CODEGRAPH_INSTALL_DIR; the launcher is symlinked into
  # CODEGRAPH_BIN_DIR. ~/.local/bin needs no PATH entry to work here:
  # resolve_bin() looks there directly.
  local bindir=${INSTALL_DIR:-$HOME/.local/bin}
  local bundle=${CODEGRAPH_INSTALL_DIR:-$HOME/.codegraph}
  [ -n "$INSTALL_DIR" ] && bundle="$INSTALL_DIR/codegraph-bundle"
  mkdir -p "$bindir" || die "cannot create install dir $bindir"
  [ -w "$bindir" ] || die "install dir $bindir is not writable (pick another with --dir)"

  note "codegraph: installing the CodeGraph CLI into $bindir via the official installer…"
  # Piped straight to sh, as upstream documents. NOTE: the installer does not
  # verify a checksum — it curls the release tarball over TLS and untars it. If
  # you need supply-chain verification, install from npm with a lockfile instead
  # and point CODEGRAPH_BIN at it.
  # The env goes on `sh`, NOT on `curl`. Putting it on the left of the pipe sets
  # it for the download and leaves the installer reading its own defaults —
  # which silently installs into ~/.codegraph and ~/.local/bin no matter what
  # --dir said, and then reports install_failed because nothing landed in --dir.
  if ! curl -fsSL "$INSTALLER_URL" |
       CODEGRAPH_INSTALL_DIR="$bundle" CODEGRAPH_BIN_DIR="$bindir" \
       CODEGRAPH_VERSION="${INSTALL_VERSION:-}" sh >&2; then
    emit install_failed "official installer failed - see stderr above" "" "" unknown
    return 1
  fi

  local bin
  if ! bin=$(CODEGRAPH_BIN="$bindir/codegraph" resolve_bin); then
    emit install_failed \
      "installed CLI at $bindir/codegraph is missing or older than $MIN_VERSION" \
      "" "" unknown
    return 1
  fi
  note "codegraph: installed $(bin_version "$bin")"
  # Belt and braces: the env var above covers our own child processes, but the
  # user will run this CLI outside the plugin too. Make the opt-out persistent.
  "$bin" telemetry off >/dev/null 2>&1 || true
  # Freshly installed means the index is certainly cold; ensure() builds it.
  # Pin CODEGRAPH_BIN to what we just installed: with a custom --dir outside the
  # resolution list, a bare ensure() would silently report on some *other*
  # codegraph (or none) instead of the one this install just produced.
  CODEGRAPH_BIN="$bin" cmd_ensure
}

cmd_opt_out() {
  local marker
  marker=$(consent_marker)
  mkdir -p "$(dirname "$marker")" || die "cannot create $(dirname "$marker")"
  printf 'User declined the CodeGraph install for this repo.\nDelete this file (or run codegraph.sh reset-consent) to be asked again.\n' \
    >"$marker"
  note "codegraph: recorded opt-out at $marker"
  emit declined "opt-out recorded - will not ask again in this repo" "" "" unknown
}

cmd_reset_consent() {
  local marker
  marker=$(consent_marker)
  rm -f "$marker"
  note "codegraph: cleared opt-out marker $marker"
  cmd_status
}

# Which backend answers a synthesized query for this repo. An explicit
# --backend from the caller wins; otherwise prefer a real CodeGraph index and
# only reach for devpilot when there isn't one. Never *builds* anything here:
# `ensure` owns that, and a preflight that silently indexes would blow the 30 s
# budget the skill allows it.
preflight_backend() {
  [ -n "$BACKEND" ] && { printf '%s' "$BACKEND"; return; }
  if resolve_bin >/dev/null && [ -d "$(index_dir)" ]; then
    printf 'codegraph'; return
  fi
  if devpilot_bin >/dev/null 2>&1; then printf 'devpilot'; return; fi
  printf 'codegraph'   # nothing usable; let the synthesizer report it properly
}

# devpilot graph speaks a different payload dialect. Run it, then normalise.
# Only `preflight`, `context`, `impact` and `hubs` have devpilot equivalents;
# `callers_of` / `tests_for` do not, so say so instead of returning a shape the
# skill would read as real data.
run_devpilot_synth() {
  local sub=$1; shift
  local bin dp_sub out
  bin=$(devpilot_bin) || {
    printf '{"ok":false,"data":{"mode":"fallback","reason":"no_backend: neither a CodeGraph index nor a graph-capable devpilot is available"}}\n'
    return 0
  }
  case $sub in
    preflight) dp_sub=preflight ;;
    context)   dp_sub=context ;;
    impact)    dp_sub=impact ;;
    hubs)      dp_sub=hubs ;;
    *)
      printf '{"ok":false,"data":{"mode":"fallback","reason":"unsupported_on_devpilot_backend: %s has no devpilot graph equivalent; install CodeGraph for it"}}\n' "$sub"
      return 0 ;;
  esac
  # The adapter recomputes `covers_head_sha` by comparing the indexed tree's HEAD
  # against the revision under review, so it needs that SHA. Prefer the caller's
  # --head over --at: without this the freshness field comes back null and the
  # staleness this whole path exists to catch goes unreported.
  local head_sha="$AT_SHA" i args=("$@")
  for i in "${!args[@]}"; do
    if [ "${args[$i]}" = "--head" ] && [ -n "${args[$((i+1))]:-}" ]; then
      head_sha=${args[$((i+1))]}
      break
    fi
  done

  out=$("$bin" graph "$dp_sub" --repo "$REPO_DIR" "$@" 2>/dev/null)
  printf '%s' "$out" | python3 "$DEVPILOT_ADAPTER_PY" \
    --command "$sub" --repo "$REPO_DIR" ${head_sha:+--head-sha "$head_sha"}
}

# Passthrough with a synthesized layer in front. `preflight`, `context`, and
# `impact` are the pr-review contract and do not exist in the CodeGraph CLI —
# codegraph_preflight.py computes them from the SQLite index. Everything else
# goes to the CLI untouched, so `-- query Foo --json` still works.
cmd_passthrough() {
  local sub=${1-}
  case $sub in
    preflight | context | impact | hubs | callers_of | callers-of | tests_for | tests-for)
      shift
      # REPO_DIR is already resolved (including any --at redirect) by the `--`
      # branch below, and --repo/--at have been stripped from "$@" there — so
      # always pass our own --repo. A caller that forgets to thread the `repo`
      # from `ensure` back in gets the right tree anyway.
      if [ "$(preflight_backend)" = "devpilot" ]; then
        run_devpilot_synth "$sub" "$@"
        return $?
      fi
      exec python3 "$PREFLIGHT_PY" "$sub" --repo "$REPO_DIR" "$@"
      ;;
    "") die "-- needs a subcommand (preflight|context|impact|<codegraph args>)" 2 ;;
    *)
      local bin
      bin=$(resolve_bin) ||
        die "no codegraph CLI >= $MIN_VERSION; run 'codegraph.sh status' first"
      exec "$bin" "$@"
      ;;
  esac
}

# --- arg parsing -------------------------------------------------------------
[ $# -gt 0 ] || die "usage: codegraph.sh {status|ensure|install|opt-out|reset-consent|-- <args>}" 2

SUB=$1
shift
if [ "$SUB" = "--" ]; then
  # `-- preflight --repo X` must resolve REPO_DIR the same way the state
  # subcommands do. For the synthesized subcommands, pull --repo/--at/--backend
  # out of the arg list here (cmd_passthrough re-adds --repo itself); everything
  # else is forwarded to the CLI byte-for-byte.
  case ${1-} in
    preflight | context | impact | hubs | callers_of | callers-of | tests_for | tests-for)
      kept=("$1"); shift
      while [ $# -gt 0 ]; do
        case $1 in
          --repo) REPO_DIR=$2; shift 2 ;;
          --at) AT_SHA=$2; shift 2 ;;
          --backend) BACKEND=$2; shift 2 ;;
          *) kept+=("$1"); shift ;;
        esac
      done
      set -- "${kept[@]}"
      ;;
  esac
  if [ -d "$REPO_DIR" ]; then REPO_DIR=$(cd "$REPO_DIR" && pwd); fi
  REPO_ARG="$REPO_DIR"
  # Same --at contract as `ensure`: index/query the revision under review. A
  # caller that threads `ensure`'s `repo` through instead is already correct and
  # this is a no-op for them.
  if [ -n "$AT_SHA" ] && at_wt=$(resolve_at_worktree "$AT_SHA"); then
    REPO_DIR="$at_wt"
    WORKTREE="$at_wt"
  fi
  # cmd_passthrough `exec`s on the CodeGraph path but only *returns* on the
  # devpilot path, so exit explicitly — otherwise control falls into the flag
  # parser below and dies with "unknown flag: preflight".
  cmd_passthrough "$@"
  exit $?
fi

while [ $# -gt 0 ]; do
  case $1 in
    --repo) REPO_DIR=$2; shift 2 ;;
    --at) AT_SHA=$2; shift 2 ;;
    --dir) INSTALL_DIR=$2; shift 2 ;;
    --version) INSTALL_VERSION=$2; shift 2 ;;
    --yes | -y) ASSUME_YES=yes; shift ;;
    --) shift; break ;;
    *) die "unknown flag: $1" 2 ;;
  esac
done

# Normalise --repo so the consent marker and index lookups agree on one path.
if [ -d "$REPO_DIR" ]; then
  REPO_DIR=$(cd "$REPO_DIR" && pwd)
else
  die "--repo $REPO_DIR is not a directory" 2
fi
REPO_ARG="$REPO_DIR"

# --at redirects everything downstream at the detached worktree. A failure to
# materialise one is not fatal: index the current tree and let the preflight
# report `index_stale` as before, which is strictly better than aborting.
if [ -n "$AT_SHA" ] && [ "$SUB" != "install" ]; then
  if at_wt=$(resolve_at_worktree "$AT_SHA"); then
    REPO_DIR="$at_wt"
    WORKTREE="$at_wt"
  fi
fi

case $SUB in
  status) cmd_status ;;
  ensure) cmd_ensure ;;
  install) cmd_install ;;
  opt-out | optout) cmd_opt_out ;;
  reset-consent) cmd_reset_consent ;;
  *) die "unknown subcommand: $SUB" 2 ;;
esac
