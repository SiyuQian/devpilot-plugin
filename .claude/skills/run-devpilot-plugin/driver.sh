#!/usr/bin/env bash
# driver.sh — drive the devpilot plugin without touching the user's installed copy.
#
# This plugin has no "app window": it is markdown skills plus two shell scripts,
# executed by Claude Code. So there are two layers worth driving, and this driver
# covers both:
#
#   1. Direct invocation (free, fast, deterministic) — run scripts/codegraph.sh
#      through every state a user's machine can be in, inside a sandbox, and
#      assert the JSON `action`. This is the layer most PRs here touch.
#   2. Headless skill execution (costs API tokens) — a real `claude -p` session
#      that loads a skill FROM THIS WORKING TREE and performs it, so you can see
#      whether the prose actually steers the model. Prose that reads fine and
#      steers wrong is this repo's characteristic bug; only this layer catches it.
#
# Everything is sandboxed: the CodeGraph index lives inside the generated fixture
# repo (`$FIXTURE/.codegraph`), never in a repo you care about, and no run ever
# installs into a real bin dir unless you explicitly ask for `install-live`.
# CODEGRAPH_TELEMETRY/CODEGRAPH_NO_DAEMON are forced off by codegraph.sh itself.
#
# Usage:
#   driver.sh smoke                     # validate + codegraph  (no API cost)
#   driver.sh validate                  # scripts/validate.py
#   driver.sh fixture                   # build the Go fixture repo, print refs
#   driver.sh codegraph                 # 11 assertions on the wrapper
#   driver.sh install-live              # REAL ~57MB bundle download into the sandbox
#   driver.sh headless present|missing|declined ["extra prompt"]
#   driver.sh smoke-full                # smoke + all three headless probes
#   driver.sh clean                     # remove the sandbox
#
# Exit 0 = all assertions passed.

set -uo pipefail

# Repo root = three levels up from .claude/skills/run-devpilot-plugin/.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
SANDBOX=${DRIVER_SANDBOX:-/tmp/devpilot-plugin-driver}
FIXTURE="$SANDBOX/fixture"
WORKSPACE="$SANDBOX/workspace"
# The index is per-repo (inside $FIXTURE), so "wipe the cache" means rm -rf that
# directory — there is no global cache dir to redirect any more.
FIXTURE_INDEX="$FIXTURE/.codegraph"

CG="$ROOT/scripts/codegraph.sh"
PASS=0
FAIL=0

c_ok=$'\033[32m'; c_bad=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
[ -t 1 ] || { c_ok=""; c_bad=""; c_dim=""; c_off=""; }

say()  { printf '%s\n' "$*"; }
head2() { printf '\n%s== %s ==%s\n' "$c_dim" "$*" "$c_off"; }
ok()   { PASS=$((PASS+1)); printf '%s  PASS%s %s\n' "$c_ok" "$c_off" "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '%s  FAIL%s %s\n' "$c_bad" "$c_off" "$*"; }

# `claude` is a shell ALIAS in the user's interactive zsh, which does not exist
# inside a script. Resolve the real binary or every headless probe dies with
# "command not found".
find_claude() {
  command -v claude 2>/dev/null && return 0
  for c in "$HOME/.local/bin/claude" /usr/local/bin/claude /opt/homebrew/bin/claude; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

jget() { python3 -c 'import json,sys;print((json.load(sys.stdin) or {}).get(sys.argv[1],""))' "$1"; }

# assert_action <label> <expected-action> <json>
assert_action() {
  local label=$1 want=$2 json=$3 got
  got=$(printf '%s' "$json" | tail -1 | jget action 2>/dev/null)
  if [ "$got" = "$want" ]; then
    ok "$label → $got"
  else
    bad "$label → expected '$want', got '${got:-<unparseable>}'"
    printf '       raw: %s\n' "$(printf '%s' "$json" | tail -1 | cut -c1-200)"
  fi
}

# --- fixture -----------------------------------------------------------------
# A three-file Go module with one exported, called, untested function whose body
# changes between two commits. Small enough to index in ~1s, and rich enough
# that preflight returns a caller, a cross-community edge, and untested_public.
# Generated rather than borrowed from the user's disk so the driver is portable.
cmd_fixture() {
  rm -rf "$FIXTURE"
  mkdir -p "$FIXTURE/internal/greet" "$FIXTURE/cmd/app"
  cat >"$FIXTURE/go.mod" <<'EOF'
module example.com/fixture

go 1.21
EOF
  cat >"$FIXTURE/internal/greet/greet.go" <<'EOF'
package greet

// Hello is exported, called from main, and has no test.
func Hello(name string) string { return "hello " + name }
EOF
  cat >"$FIXTURE/cmd/app/main.go" <<'EOF'
package main

import (
	"fmt"

	"example.com/fixture/internal/greet"
)

func main() { fmt.Println(greet.Hello("world")) }
EOF
  git -C "$FIXTURE" init -q .
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" -c user.email=t@t -c user.name=t commit -qm base
  # Behavior change to the untested exported symbol → a reviewable diff.
  cat >"$FIXTURE/internal/greet/greet.go" <<'EOF'
package greet

import "strings"

// Hello now upper-cases its argument — a behavior change.
func Hello(name string) string { return "hello " + strings.ToUpper(name) }
EOF
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" -c user.email=t@t -c user.name=t commit -qm change
  FIXTURE_BASE=$(git -C "$FIXTURE" rev-parse HEAD~1)
  FIXTURE_HEAD=$(git -C "$FIXTURE" rev-parse HEAD)
  say "fixture: $FIXTURE"
  say "base:    $FIXTURE_BASE"
  say "head:    $FIXTURE_HEAD"
}

# --- validate ----------------------------------------------------------------
# validate.py needs PyYAML. A Homebrew/system python3 refuses `pip install`
# under PEP 668 ("externally-managed-environment"), so provision a sandbox venv
# on first use rather than asking the user to --break-system-packages.
validate_python() {
  if python3 -c 'import yaml' 2>/dev/null; then
    printf 'python3'
    return 0
  fi
  local vpy="$SANDBOX/venv/bin/python3"
  if [ ! -x "$vpy" ]; then
    say "  provisioning venv with PyYAML (first run, needs network)…" >&2
    python3 -m venv "$SANDBOX/venv" >&2 || return 1
    "$SANDBOX/venv/bin/pip" install -q pyyaml >&2 || return 1
  fi
  printf '%s' "$vpy"
}

cmd_validate() {
  head2 "scripts/validate.py"
  local py out
  if ! py=$(validate_python); then
    bad "could not get a python3 with PyYAML"
    return
  fi
  if out=$(cd "$ROOT" && "$py" scripts/validate.py 2>&1); then
    ok "validate.py: ${out##*$'\n'}"
  else
    bad "validate.py failed"
    printf '%s\n' "$out"
  fi
}

# --- codegraph ---------------------------------------------------------------
cmd_codegraph() {
  head2 "scripts/codegraph.sh state machine (sandboxed)"
  cmd_fixture >/dev/null

  # 1. No binary anywhere → needs_install (or unsupported_platform off the
  #    published triples — accept either, they are both correct answers).
  local json got
  json=$(CODEGRAPH_BIN=/nonexistent/codegraph bash "$CG" status --repo "$FIXTURE" 2>/dev/null)
  got=$(printf '%s' "$json" | tail -1 | jget action)
  case $got in
    needs_install | unsupported_platform) ok "no binary → $got" ;;
    *) bad "no binary → expected needs_install/unsupported_platform, got '$got'" ;;
  esac

  # 2. install must refuse without explicit consent.
  if bash "$CG" install --repo "$FIXTURE" >/dev/null 2>&1; then
    bad "install without --yes was ACCEPTED (must refuse)"
  else
    ok "install without --yes refused (exit $?)"
  fi

  # Remaining checks need a real binary. Skip loudly rather than silently.
  if ! bash "$CG" status --repo "$FIXTURE" >/dev/null 2>&1; then
    say "  (no codegraph CLI resolvable; run 'driver.sh install-live' for the rest)"
    return
  fi
  local resolved
  resolved=$(bash "$CG" status --repo "$FIXTURE" 2>/dev/null | tail -1 | jget action)
  if [ -z "$resolved" ]; then
    say "  (status unparseable; skipping binary-dependent checks)"
    return
  fi
  if [ "$resolved" = "needs_install" ] || [ "$resolved" = "unsupported_platform" ]; then
    say "  (no codegraph installed: '$resolved'. Run 'driver.sh install-live' for the rest.)"
    return
  fi

  # 3. Binary present, index never built → needs_build.
  rm -rf "$FIXTURE_INDEX"
  assert_action "cold index" needs_build \
    "$(bash "$CG" status --repo "$FIXTURE" 2>/dev/null)"

  # 4. ensure builds it → ready. This is the reversed "never auto-build" rule.
  assert_action "ensure builds cold index" ready \
    "$(bash "$CG" ensure --repo "$FIXTURE" 2>/dev/null)"

  # 5. Second ensure re-syncs and stays ready (it does NOT skip the sync).
  assert_action "ensure idempotent" ready \
    "$(bash "$CG" ensure --repo "$FIXTURE" 2>/dev/null)"

  # 5b. The index must not dirty the repo under review.
  if [ -n "$(git -C "$FIXTURE" status --porcelain 2>/dev/null)" ]; then
    bad "indexing dirtied the fixture: $(git -C "$FIXTURE" status --porcelain | head -1)"
  else
    ok "index excluded from git status (.git/info/exclude)"
  fi

  # 6. Passthrough returns a real preflight payload, not just an exit code.
  local pf
  pf=$(bash "$CG" -- preflight --repo "$FIXTURE" \
        --base "$(git -C "$FIXTURE" rev-parse HEAD~1)" \
        --head "$(git -C "$FIXTURE" rev-parse HEAD)" 2>/dev/null)
  local verdict
  verdict=$(printf '%s' "$pf" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("unparseable"); raise SystemExit
data=d.get("data") or {}
syms=[s for s in (data.get("changed_symbols") or []) if s.get("kind")!="file"]
hello=[s for s in syms if s["id"].endswith("::Hello")]
if data.get("mode")!="built": print("mode="+str(data.get("mode")))
elif not hello: print("Hello symbol absent")
elif (hello[0].get("callers") or {}).get("count")!=1: print("caller count wrong")
elif not (hello[0].get("callers") or {}).get("confident"): print("caller set should be confident here")
elif "untested_public" not in (hello[0].get("risk_factors") or []): print("risk_factors missing untested_public")
else: print("ok")
' 2>/dev/null)
  [ "$verdict" = "ok" ] \
    && ok "preflight payload: mode=built, Hello has 1 confident caller + untested_public" \
    || bad "preflight payload wrong: $verdict"

  # 6b. A stale index must fail closed rather than report stale line numbers.
  printf '\n// appended after indexing\nfunc Unindexed() {}\n' \
    >>"$FIXTURE/internal/greet/greet.go"
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" -c user.email=t@t -c user.name=t commit -qm stale
  local stale_mode
  stale_mode=$(bash "$CG" -- preflight --repo "$FIXTURE" \
        --base "$(git -C "$FIXTURE" rev-parse HEAD~1)" \
        --head "$(git -C "$FIXTURE" rev-parse HEAD)" 2>/dev/null |
        python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print("unparseable"); raise SystemExit
print((d.get("data") or {}).get("mode","<none>"))')
  [ "$stale_mode" = "fallback" ] \
    && ok "stale index → mode=fallback (fails closed)" \
    || bad "stale index → expected mode=fallback, got '$stale_mode'"

  # 7. opt-out is sticky and suppresses both status and ensure.
  bash "$CG" opt-out --repo "$FIXTURE" >/dev/null 2>&1
  assert_action "after opt-out, status" declined \
    "$(CODEGRAPH_BIN=/nonexistent/codegraph bash "$CG" status --repo "$FIXTURE" 2>/dev/null)"
  assert_action "after opt-out, ensure does not build" declined \
    "$(CODEGRAPH_BIN=/nonexistent/codegraph bash "$CG" ensure --repo "$FIXTURE" 2>/dev/null)"

  # 8. reset-consent clears it.
  bash "$CG" reset-consent --repo "$FIXTURE" >/dev/null 2>&1
  local after
  after=$(bash "$CG" status --repo "$FIXTURE" 2>/dev/null | tail -1 | jget opted_out)
  [ "$after" = "False" ] || [ "$after" = "false" ] \
    && ok "reset-consent clears the marker" \
    || bad "reset-consent left opted_out=$after"
}

# --- live install ------------------------------------------------------------
# Opt-in: really downloads the ~57 MB CodeGraph bundle from GitHub releases
# (~280 MB unpacked — it vendors a Node runtime).
# Installs into the sandbox, never into ~/.local/bin or /usr/local/bin, so it
# cannot disturb whatever codegraph the user already has.
cmd_install_live() {
  head2 "live install into sandbox (~57 MB download, ~280 MB unpacked)"
  cmd_fixture >/dev/null
  rm -rf "$SANDBOX/bin"
  local json
  json=$(bash "$CG" install --yes --dir "$SANDBOX/bin" --repo "$FIXTURE" 2>&1)
  assert_action "install --yes --dir sandbox" ready "$json"
  if [ -x "$SANDBOX/bin/codegraph" ]; then
    ok "CLI present: $("$SANDBOX/bin/codegraph" version 2>/dev/null | head -1)"
  else
    bad "no CLI at $SANDBOX/bin/codegraph"
  fi
}

# --- headless skill execution ------------------------------------------------
# Runs a REAL claude -p session against the skill in this working tree.
#
# Why the temp workspace instead of --plugin-dir: the user's installed
# devpilot plugin registers the same `devpilot:pr-review` name, and it WINS —
# a --plugin-dir run silently exercises the stale installed copy. Copying the
# skill into a scratch workspace as a PROJECT skill gives it the unnamespaced
# name `pr-review`, which cannot collide, so what runs is certainly this tree.
cmd_headless() {
  local state=${1:-present}; shift || true
  local extra=${1:-}
  local claude_bin
  claude_bin=$(find_claude) || { bad "claude CLI not found"; return 1; }

  head2 "headless: pr-review step 1.5, codegraph state = $state"
  cmd_fixture >/dev/null

  rm -rf "$WORKSPACE"
  mkdir -p "$WORKSPACE/.claude/skills"
  cp -R "$ROOT/skills/pr-review" "$WORKSPACE/.claude/skills/pr-review"
  git -C "$WORKSPACE" init -q . 2>/dev/null

  # CLAUDE_PLUGIN_ROOT is normally injected by Claude Code for plugin scripts.
  # A project skill gets no such injection, so export it — this is also what
  # makes `${CLAUDE_PLUGIN_ROOT:-.}/scripts/codegraph.sh` resolve to this tree.
  export CLAUDE_PLUGIN_ROOT="$ROOT"
  case $state in
    present) unset CODEGRAPH_BIN ;;
    missing) export CODEGRAPH_BIN=/nonexistent/codegraph ;;
    declined)
      unset CODEGRAPH_BIN
      bash "$CG" opt-out --repo "$FIXTURE" >/dev/null 2>&1 ;;
    *) bad "unknown state '$state' (present|missing|declined)"; return 1 ;;
  esac

  local prompt="Use the pr-review skill. Do NOT review anything, do NOT post \
anything, and do NOT install anything without being told to. Execute ONLY step \
1.5 (graph enrichment) against the git repo at $FIXTURE, with \
base=$(git -C "$FIXTURE" rev-parse HEAD~1) and head=$(git -C "$FIXTURE" rev-parse HEAD). \
Then report, as three short labelled lines: (a) the exact ensure command you \
ran, (b) the JSON it printed, (c) the single next action step 1.5 prescribes \
for that action value. $extra"

  local out result
  out=$(cd "$WORKSPACE" && "$claude_bin" -p "$prompt" --output-format json \
        --allowedTools Read Grep Glob Bash Skill 2>&1)
  result=$(printf '%s' "$out" | python3 -c '
import json,sys
try: print((json.load(sys.stdin) or {}).get("result",""))
except Exception: print(sys.stdin.read()[:400] if False else "")
' 2>/dev/null)
  [ -n "$result" ] || { bad "no result from claude -p"; printf '%s\n' "$(printf '%s' "$out" | tail -c 400)"; return 1; }

  printf '%s\n' "$result" | sed 's/^/    /'

  # Assertions are on machine-checkable facts, not on the model's prose, which
  # varies run to run.
  local want
  case $state in
    present)  want='"action":"ready"' ;;
    missing)  want='"action":"needs_install"' ;;
    declined) want='"action":"declined"' ;;
  esac
  case $result in
    *"$want"*) ok "session reported $want" ;;
    *) bad "session did not report $want" ;;
  esac

  # Side-effect assertions: the agent must not have installed anything, and
  # must not have recorded a refusal the user never gave.
  if [ "$state" = "missing" ]; then
    if [ -f "$FIXTURE/.git/devpilot-codegraph-optout" ]; then
      bad "agent recorded an opt-out without user consent"
    else
      ok "no opt-out recorded without consent"
    fi
    case $result in
      *"install --yes"*"Installing CodeGraph"*) bad "agent appears to have installed unprompted" ;;
      *) ok "no unprompted install" ;;
    esac
  fi
  bash "$CG" reset-consent --repo "$FIXTURE" >/dev/null 2>&1
}

cmd_clean() { rm -rf "$SANDBOX"; say "removed $SANDBOX"; }

report() {
  printf '\n%s\n' "----------------------------------------"
  if [ "$FAIL" -eq 0 ]; then
    printf '%sALL PASS%s — %d checks\n' "$c_ok" "$c_off" "$PASS"
    exit 0
  fi
  printf '%s%d FAILED%s, %d passed\n' "$c_bad" "$FAIL" "$c_off" "$PASS"
  exit 1
}

case ${1:-smoke} in
  validate)     cmd_validate; report ;;
  fixture)      cmd_fixture ;;
  codegraph)    cmd_codegraph; report ;;
  install-live) cmd_install_live; report ;;
  headless)     shift; cmd_headless "$@"; report ;;
  smoke)        cmd_validate; cmd_codegraph; report ;;
  smoke-full)
    cmd_validate; cmd_codegraph
    cmd_headless present; cmd_headless missing; cmd_headless declined
    report ;;
  clean)        cmd_clean ;;
  *) say "usage: driver.sh {smoke|smoke-full|validate|fixture|codegraph|install-live|headless <state>|clean}"; exit 2 ;;
esac
