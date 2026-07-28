#!/usr/bin/env bash
# codegraph.sh — the plugin's only entry point to the code graph.
#
# Backed by CodeGraph (https://github.com/colbymchenry/codegraph): a tree-sitter
# indexer over 20+ languages that writes a SQLite graph into `.codegraph/`.
# It replaced the `devpilot graph` backend because devpilot could only index a
# repo with a build manifest — a Go tree without go.mod, or any Python/Java/Ruby
# repo, failed to index and every review silently degraded to grep.
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
#   codegraph.sh status  [--repo DIR]
#   codegraph.sh ensure  [--repo DIR]
#   codegraph.sh install --yes [--dir DIR] [--version X.Y.Z]
#   codegraph.sh opt-out [--repo DIR]
#   codegraph.sh reset-consent [--repo DIR]
#   codegraph.sh -- preflight --repo DIR --base A --head B   # synthesized
#   codegraph.sh -- query Foo --json                         # straight through
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

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFLIGHT_PY="$HERE/codegraph_preflight.py"

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
consent_marker() {
  local gitdir
  if gitdir=$(git -C "$REPO_DIR" rev-parse --absolute-git-dir 2>/dev/null); then
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

# --- index state -------------------------------------------------------------
index_dir() { printf '%s/%s' "$REPO_DIR" "${CODEGRAPH_DIR:-.codegraph}"; }

# `codegraph status --json` is the only honest answer to "is this repo usable".
# Prints one of: built | stale | cold | empty | unknown
#   built  — complete index with nodes and nothing pending
#   stale  — indexed, but files changed since (needs `sync`)
#   cold   — never indexed here
#   empty  — indexed and found nothing: no supported source files
cache_state() {
  local bin=$1 out
  out=$("$bin" status "$REPO_DIR" --json 2>/dev/null)
  [ -n "$out" ] || { printf 'unknown'; return; }
  printf '%s' "$out" | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("unknown"); sys.exit()
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
' 2>/dev/null || printf 'unknown'
}

# `.codegraph/` is written into the repo under review. Excluding it locally
# keeps `git status` clean for the user without committing anything: a review
# must not make the working tree look dirty to the developer we are reviewing.
exclude_index_locally() {
  local gitdir exclude entry
  gitdir=$(git -C "$REPO_DIR" rev-parse --absolute-git-dir 2>/dev/null) || return 0
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
  printf '{"action":%s,"reason":%s,"bin":%s,"version":%s,"graph_cache":%s,"index_dir":%s,"opted_out":%s,"repo":%s}\n' \
    "$(jstr "$1")" "$(jstr "$2")" "$(jstr "${3-}")" "$(jstr "${4-}")" \
    "$(jstr "${5-unknown}")" "$(jstr "$(index_dir)")" \
    "$(jbool "$(opted_out && echo yes || echo no)")" "$(jstr "$REPO_DIR")"
}

# --- subcommands -------------------------------------------------------------

cmd_status() {
  local bin version cache
  if bin=$(resolve_bin); then
    version=$(bin_version "$bin")
    cache=$(cache_state "$bin")
    case $cache in
      built) emit ready "index is built and current for this repo" "$bin" "$version" "$cache" ;;
      empty) emit build_failed \
        "no_supported_sources: codegraph indexed this repo and found no symbols" \
        "$bin" "$version" "$cache" ;;
      stale) emit needs_build "index exists but has drifted from the working tree" \
        "$bin" "$version" "$cache" ;;
      *) emit needs_build "CLI found but this repo has no index yet" \
        "$bin" "$version" "$cache" ;;
    esac
    return 0
  fi
  if opted_out; then
    emit declined "user previously declined the codegraph install in this repo" \
      "" "" unknown
  elif platform_supported; then
    emit needs_install "no codegraph CLI >= $MIN_VERSION found" "" "" unknown
  else
    emit unsupported_platform \
      "no codegraph bundle for $(uname -s)/$(uname -m)" "" "" unknown
  fi
  return 0
}

cmd_ensure() {
  local bin version cache started elapsed run_out
  if opted_out; then
    emit declined "user previously declined the codegraph install in this repo" \
      "" "" unknown
    return 0
  fi
  if ! bin=$(resolve_bin); then
    cmd_status
    return 0
  fi
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
    note "codegraph: syncing index for $REPO_DIR…"
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

# Passthrough with a synthesized layer in front. `preflight`, `context`, and
# `impact` are the pr-review contract and do not exist in the CodeGraph CLI —
# codegraph_preflight.py computes them from the SQLite index. Everything else
# goes to the CLI untouched, so `-- query Foo --json` still works.
cmd_passthrough() {
  local sub=${1-}
  case $sub in
    preflight | context | impact | hubs | callers_of | callers-of | tests_for | tests-for)
      shift
      # Default --repo to the wrapper's own idea of the repo, so a caller that
      # omits it does not silently preflight the process's cwd.
      local has_repo=no arg
      for arg in "$@"; do [ "$arg" = "--repo" ] && has_repo=yes; done
      if [ "$has_repo" = "yes" ]; then
        exec python3 "$PREFLIGHT_PY" "$sub" "$@"
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
  # subcommands do, so scan for --repo before dispatching.
  args=("$@")
  for i in "${!args[@]}"; do
    if [ "${args[$i]}" = "--repo" ] && [ -n "${args[$((i+1))]:-}" ]; then
      REPO_DIR=${args[$((i+1))]}
      break
    fi
  done
  if [ -d "$REPO_DIR" ]; then REPO_DIR=$(cd "$REPO_DIR" && pwd); fi
  cmd_passthrough "$@"
fi

while [ $# -gt 0 ]; do
  case $1 in
    --repo) REPO_DIR=$2; shift 2 ;;
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

case $SUB in
  status) cmd_status ;;
  ensure) cmd_ensure ;;
  install) cmd_install ;;
  opt-out | optout) cmd_opt_out ;;
  reset-consent) cmd_reset_consent ;;
  *) die "unknown subcommand: $SUB" 2 ;;
esac
