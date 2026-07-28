#!/usr/bin/env bash
# codegraph.sh — the plugin's only entry point to the code graph.
#
# Skills MUST NOT call `devpilot graph` directly. They call this wrapper, which
# owns four things the skills should not each reimplement:
#
#   1. Resolution   — finds a graph-capable devpilot binary in the places it can
#                     actually live, not just $PATH. A user who installed into
#                     ~/.local/bin without fixing PATH still gets the graph.
#   2. Bootstrap    — when no binary exists, reports `needs_install`, and on an
#                     explicit `install --yes` runs the official upstream
#                     installer (checksum-verified) into a writable dir.
#   3. Cold cache   — `ensure` builds the graph when the binary is present but
#                     the repo has never been indexed. Without this, a fresh
#                     install still yields mode:"fallback" on first review.
#   4. Consent      — a per-repo opt-out marker so a user who says "no" once is
#                     never asked again in that repo.
#
# NON-INTERACTIVE BY DESIGN. This script never prompts. A `read` here would hang
# any headless (`claude -p`) session forever. The *agent* asks the user for
# consent and then calls `install --yes`. `status` and `ensure` are always safe
# to run unattended: neither downloads nor installs anything.
#
# Every subcommand prints one line of JSON on stdout and human-readable notes on
# stderr, so callers can `| python3 -c ...` without stripping chatter.
#
# Usage:
#   codegraph.sh status  [--repo DIR]
#   codegraph.sh ensure  [--repo DIR]
#   codegraph.sh install --yes [--dir DIR] [--version vX.Y.Z]
#   codegraph.sh opt-out [--repo DIR]
#   codegraph.sh reset-consent [--repo DIR]
#   codegraph.sh -- <graph args...>        # e.g. -- preflight --base A --head B
#
# Exit codes: 0 = the requested action succeeded (for status/ensure: JSON is
# valid and describes reality, even when action != "ready"); 1 = the wrapper
# itself failed; 2 = usage error. Callers should branch on the JSON `action`
# field, not on the exit code, for the ready/needs_install/declined distinction.

set -uo pipefail

INSTALLER_URL="https://raw.githubusercontent.com/siyuqian/devpilot/main/install.sh"

REPO_DIR="$PWD"
INSTALL_DIR=""
INSTALL_VERSION=""
ASSUME_YES="no"

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
# Ordered widest-net-last. A binary only counts if it actually speaks graph —
# devpilot releases before v0.17 have no `graph` subcommand at all, and
# `graph preflight` (what pr-review needs) landed later still, so probe the
# exact subcommand rather than parsing a version string.
graph_capable() {
  local bin=$1
  [ -x "$bin" ] || return 1
  "$bin" graph preflight --help >/dev/null 2>&1
}

resolve_bin() {
  local candidate
  # Explicit override wins, and is how the driver tests the not-installed path.
  if [ -n "${DEVPILOT_BIN:-}" ]; then
    graph_capable "$DEVPILOT_BIN" && { printf '%s' "$DEVPILOT_BIN"; return 0; }
    return 1
  fi
  if candidate=$(command -v devpilot 2>/dev/null); then
    graph_capable "$candidate" && { printf '%s' "$candidate"; return 0; }
  fi
  for candidate in \
    "$HOME/.local/bin/devpilot" \
    "/usr/local/bin/devpilot" \
    "/opt/homebrew/bin/devpilot" \
    "${GOBIN:-}/devpilot" \
    "${GOPATH:-$HOME/go}/bin/devpilot"
  do
    case "$candidate" in /devpilot) continue ;; esac
    graph_capable "$candidate" && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

bin_version() {
  "$1" --version 2>/dev/null | head -1 | tr -d '\n' || printf 'unknown'
}

# install.sh publishes prebuilt binaries for exactly these triples. On anything
# else there is nothing to download, so say so instead of failing mid-curl.
platform_supported() {
  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) return 1 ;;
  esac
  case "${os}-${arch}" in
    darwin-arm64 | darwin-amd64 | linux-amd64) return 0 ;;
    *) return 1 ;;
  esac
}

# --- graph cache state -------------------------------------------------------
# `graph status` answers ok:true only once the repo has been indexed. Parse with
# python3 rather than grepping the envelope, so a schema tweak upstream fails
# loudly instead of silently reading as "cold".
cache_state() {
  local bin=$1 out
  out=$("$bin" graph status --repo "$REPO_DIR" 2>/dev/null)
  [ -n "$out" ] || { printf 'unknown'; return; }
  printf '%s' "$out" | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("unknown"); sys.exit()
print("built" if d.get("ok") else "cold")
' 2>/dev/null || printf 'unknown'
}

# Pull the failure out of a devpilot JSON envelope: "<code>: <message>". The
# skill quotes this verbatim as the `graph unavailable: <reason>` line, so a
# user seeing "grep-only" learns *why* (missing go.mod, unsupported language)
# and can act on it, instead of just "graph failed".
envelope_error() {
  python3 -c '
import json,sys
raw = sys.stdin.read().strip()
try:
    d = json.loads(raw.splitlines()[-1]) if raw else {}
except Exception:
    print(raw[:200] if raw else "no output from graph build"); sys.exit()
e = d.get("error") or {}
code, msg = e.get("code") or "", e.get("message") or ""
print(f"{code}: {msg}".strip(": ") or "graph build reported ok:false with no error detail")
' 2>/dev/null <<<"$1" || printf 'graph build failed (unparseable output)'
}

emit() {
  # emit <action> <reason> [bin] [version] [cache]
  printf '{"action":%s,"reason":%s,"bin":%s,"version":%s,"graph_cache":%s,"opted_out":%s,"repo":%s}\n' \
    "$(jstr "$1")" "$(jstr "$2")" "$(jstr "${3-}")" "$(jstr "${4-}")" \
    "$(jstr "${5-unknown}")" "$(jbool "$(opted_out && echo yes || echo no)")" \
    "$(jstr "$REPO_DIR")"
}

# --- subcommands -------------------------------------------------------------

cmd_status() {
  local bin version cache
  if bin=$(resolve_bin); then
    version=$(bin_version "$bin")
    cache=$(cache_state "$bin")
    if [ "$cache" = "built" ]; then
      emit ready "graph cache is built for this repo" "$bin" "$version" "$cache"
    else
      emit needs_build "binary found but this repo has no graph cache yet" \
        "$bin" "$version" "$cache"
    fi
    return 0
  fi
  if opted_out; then
    emit declined "user previously declined the codegraph install in this repo" \
      "" "" unknown
  elif platform_supported; then
    emit needs_install "no graph-capable devpilot binary found" "" "" unknown
  else
    emit unsupported_platform \
      "no prebuilt devpilot binary for $(uname -s)/$(uname -m)" "" "" unknown
  fi
  return 0
}

cmd_ensure() {
  local bin version cache started elapsed
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
  if [ "$cache" = "built" ]; then
    emit ready "graph cache already built" "$bin" "$version" "$cache"
    return 0
  fi
  # The cold-cache build. pr-review used to forbid this ("do NOT auto-run
  # graph build"); ensure() is the sanctioned place for it, because a review
  # that installs the binary and then still reports "graph unavailable" is
  # worse than a few seconds of indexing. Build is incremental after the first.
  note "codegraph: building graph cache for $REPO_DIR (first run only)…"
  started=$(date +%s)
  local build_out
  build_out=$("$bin" graph build --repo "$REPO_DIR" 2>&1)
  elapsed=$(( $(date +%s) - started ))
  cache=$(cache_state "$bin")
  # Do NOT branch on the exit code: `graph build` exits 0 while reporting
  # ok:false in its envelope (e.g. go_no_module). The cache state is the truth.
  if [ "$cache" = "built" ]; then
    note "codegraph: graph built in ${elapsed}s"
    emit ready "graph built in ${elapsed}s" "$bin" "$version" "$cache"
  else
    emit build_failed "$(envelope_error "$build_out")" "$bin" "$version" "$cache"
  fi
  return 0
}

cmd_install() {
  [ "$ASSUME_YES" = "yes" ] || die "install requires --yes (ask the user first)" 2
  platform_supported || {
    emit unsupported_platform \
      "no prebuilt devpilot binary for $(uname -s)/$(uname -m)" "" "" unknown
    return 0
  }

  # Default to a dir we can write without sudo. The upstream installer defaults
  # to /usr/local/bin and shells out to `sudo mv` when that is not writable —
  # a sudo password prompt is exactly the hang this script must never cause.
  # ~/.local/bin needs no PATH entry to work here: resolve_bin() looks there.
  local dir=${INSTALL_DIR:-$HOME/.local/bin}
  mkdir -p "$dir" || die "cannot create install dir $dir"
  [ -w "$dir" ] || die "install dir $dir is not writable (pick another with --dir)"

  local args="--dir $dir"
  [ -n "$INSTALL_VERSION" ] && args="$args --version $INSTALL_VERSION"

  note "codegraph: installing devpilot into $dir via the official installer…"
  # Piped straight to sh, as upstream documents. The installer verifies the
  # release checksum itself before moving the binary into place.
  if ! curl -fsSL "$INSTALLER_URL" | sh -s -- $args >&2; then
    emit install_failed "official installer failed - see stderr above" "" "" unknown
    return 1
  fi

  local bin
  if ! bin=$(DEVPILOT_BIN="$dir/devpilot" resolve_bin); then
    emit install_failed \
      "installed binary at $dir/devpilot does not support 'graph preflight'" \
      "" "" unknown
    return 1
  fi
  note "codegraph: installed $(bin_version "$bin")"
  # Freshly installed means the cache is certainly cold; ensure() builds it.
  # Pin DEVPILOT_BIN to what we just installed: with a custom --dir outside the
  # resolution list, a bare ensure() would silently report on some *other*
  # devpilot (or none) instead of the one this install just produced.
  DEVPILOT_BIN="$bin" cmd_ensure
}

cmd_opt_out() {
  local marker
  marker=$(consent_marker)
  mkdir -p "$(dirname "$marker")" || die "cannot create $(dirname "$marker")"
  printf 'User declined the devpilot codegraph install for this repo.\nDelete this file (or run codegraph.sh reset-consent) to be asked again.\n' \
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

# Passthrough. Callers get devpilot's own JSON envelope on stdout untouched, so
# `-- preflight --base A --head B` is a drop-in for `devpilot graph preflight …`.
cmd_passthrough() {
  local bin
  bin=$(resolve_bin) || die "no graph-capable devpilot binary; run 'codegraph.sh status' first"
  exec "$bin" graph "$@"
}

# --- arg parsing -------------------------------------------------------------
[ $# -gt 0 ] || die "usage: codegraph.sh {status|ensure|install|opt-out|reset-consent|-- <graph args>}" 2

SUB=$1
shift
if [ "$SUB" = "--" ]; then
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

# Normalise --repo so the consent marker and cache lookups agree on one path.
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
