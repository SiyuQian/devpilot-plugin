#!/usr/bin/env bash
# devpilot-verify-wrapper — do not remove this marker. Callers that must find
# this file without a reliable ${CLAUDE_PLUGIN_ROOT} grep for it to confirm that
# a candidate `scripts/verify.sh` is *this* wrapper and not a same-named script
# in the repo being worked on. Same convention as scripts/codegraph.sh.
#
# verify.sh — run the repo's own verification for whatever just changed.
#
# The contract lives in the worked-on repo at `.devpilot/verify.json`: path globs
# mapped to the commands that prove those paths still work, each with a `why`
# recording what behavior the command covers. That file is the answer to "how is
# this feature tested", written once instead of re-derived per change.
#
# No manifest means this is a no-op — every mode exits 0 and prints
# status:"no_manifest". Enabling the gate in a repo is creating that file, and
# nothing else.
#
# Subcommands:
#   plan          resolve the change set to a command list; run nothing (JSON)
#   run           run the resolved commands; exit non-zero if any failed
#   hook          Stop-hook entry: reads hook JSON on stdin, exit 2 blocks
#   init          write a starter .devpilot/verify.json (never overwrites)
#
# Flags: --repo DIR, --all (ignore the change set, run everything),
#        --json (machine-readable result), --no-cache (ignore the green marker).
#
# Escape hatches, checked in this order: DEVPILOT_VERIFY=off, or a
# `.devpilot/verify.off` file in the repo. Both make every mode a no-op.
#
# One line of JSON on stdout; human progress on stderr. Never prompts — a `read`
# would hang `claude -p`.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLANNER="$SELF_DIR/verify_plan.py"

REPO_DIR="."
MODE=""
RUN_ALL="no"
JSON_OUT="no"
USE_CACHE="yes"

note() { printf '%s\n' "$*" >&2; }
die() { note "verify.sh: $*"; exit "${2:-1}"; }

# JSON string escape for the small set of fields we emit ourselves.
jstr() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '"%s"' "$s"
}

emit() { printf '%s\n' "$1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    plan|run|hook|init) MODE="$1" ;;
    --repo) REPO_DIR="${2:?--repo needs a directory}"; shift ;;
    --all) RUN_ALL="yes" ;;
    --json) JSON_OUT="yes" ;;
    --no-cache) USE_CACHE="no" ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
  shift
done
MODE="${MODE:-run}"

cd "$REPO_DIR" 2>/dev/null || die "cannot enter --repo $REPO_DIR" 2
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  emit "{\"status\":\"not_a_repo\"}"; exit 0; }
cd "$REPO_ROOT" || die "cannot enter repo root $REPO_ROOT" 2

# ---------- hook mode: consume stdin before any other decision ----------
# A Stop hook re-fires after it blocks. `stop_hook_active` is true on that second
# pass; blocking again would spin forever, so the gate reports once and yields.
HOOK_STDIN=""
if [ "$MODE" = "hook" ]; then
  HOOK_STDIN="$(cat)"
  if printf '%s' "$HOOK_STDIN" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
    emit '{"status":"skipped","reason":"stop_hook_active"}'
    exit 0
  fi
fi

# ---------- opt-outs ----------
if [ "${DEVPILOT_VERIFY:-}" = "off" ]; then
  emit '{"status":"skipped","reason":"DEVPILOT_VERIFY=off"}'; exit 0
fi
if [ -f ".devpilot/verify.off" ]; then
  emit '{"status":"skipped","reason":"verify.off"}'; exit 0
fi

# ---------- init ----------
if [ "$MODE" = "init" ]; then
  if [ -f ".devpilot/verify.json" ]; then
    emit "{\"status\":\"exists\",\"path\":\".devpilot/verify.json\"}"; exit 0
  fi
  mkdir -p .devpilot || die "cannot create .devpilot/"
  cat > .devpilot/verify.json <<'JSON'
{
  "version": 1,
  "gate": "block",
  "timeout": 600,
  "always": [],
  "rules": [
    {
      "match": ["**"],
      "run": ["echo 'replace me: the command that proves this repo still works'"],
      "why": "placeholder — devpilot:verifying-changes should replace this with real rules"
    }
  ],
  "manual": []
}
JSON
  emit "{\"status\":\"created\",\"path\":\".devpilot/verify.json\"}"
  note "verify.sh: wrote a placeholder .devpilot/verify.json — replace the rules with real ones."
  exit 0
fi

[ -f "$PLANNER" ] || die "planner missing: $PLANNER"
command -v python3 >/dev/null 2>&1 || die "python3 not found; required to read the manifest"

if [ ! -f ".devpilot/verify.json" ]; then
  emit "{\"status\":\"no_manifest\",\"path\":\".devpilot/verify.json\"}"
  exit 0
fi

# ---------- change set ----------
default_branch() {
  local ref
  ref="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" && {
    printf '%s' "${ref#origin/}"; return 0; }
  for b in main master; do
    git show-ref --verify --quiet "refs/remotes/origin/$b" && { printf '%s' "$b"; return 0; }
  done
  printf '%s' ""
}

changed_files() {
  # Everything this branch changed that a reviewer would see: uncommitted,
  # staged, untracked, and already-committed-since-base. An agent that committed
  # mid-session must still be gated on what it committed.
  {
    git diff --name-only HEAD 2>/dev/null
    git diff --name-only --cached 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
    local base
    base="$(default_branch)"
    if [ -n "$base" ] && git show-ref --verify --quiet "refs/remotes/origin/$base"; then
      git diff --name-only "origin/$base...HEAD" 2>/dev/null
    fi
  } | sed '/^$/d' | sort -u
}

# ---------- green cache ----------
# Keyed on the exact content of the change set, so a second Stop with nothing
# touched since the last green run costs one hash instead of a test suite.
state_dir() {
  local gitdir
  gitdir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  printf '%s/devpilot' "$gitdir"
}

tree_fingerprint() {
  {
    git rev-parse HEAD 2>/dev/null
    git diff HEAD 2>/dev/null
    git diff --cached 2>/dev/null
    # Untracked content matters too: a new, never-committed file can break the build.
    git ls-files --others --exclude-standard -z 2>/dev/null |
      while IFS= read -r -d '' f; do
        printf '%s\n' "$f"
        [ -f "$f" ] && cat -- "$f" 2>/dev/null
      done
    cat .devpilot/verify.json 2>/dev/null
  } | (command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum) | awk '{print $1}'
}

FILES_TMP="$(mktemp -t devpilot-verify.XXXXXX)" || die "mktemp failed"
PLAN_TMP="$(mktemp -t devpilot-plan.XXXXXX)" || die "mktemp failed"
trap 'rm -f "$FILES_TMP" "$PLAN_TMP"' EXIT

changed_files > "$FILES_TMP"

PLAN_ARGS=(--repo . --files "$FILES_TMP")
[ "$RUN_ALL" = "yes" ] && PLAN_ARGS+=(--all)
python3 "$PLANNER" "${PLAN_ARGS[@]}" > "$PLAN_TMP" || die "planner failed"
PLAN="$(cat "$PLAN_TMP")"

jq_field() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));v=d.get(sys.argv[2],"");print(v if not isinstance(v,(dict,list)) else json.dumps(v))' "$PLAN_TMP" "$1"; }

STATUS="$(jq_field status)"
if [ "$MODE" = "plan" ]; then emit "$PLAN"; exit 0; fi

case "$STATUS" in
  no_manifest|nothing_to_do)
    emit "$PLAN"
    [ "$STATUS" = "nothing_to_do" ] && note "verify.sh: nothing changed that any rule covers."
    exit 0 ;;
  bad_manifest)
    emit "$PLAN"
    note "verify.sh: .devpilot/verify.json is invalid — $(jq_field error)"
    # An unreadable contract is a failure to report, not a gate to silently pass.
    [ "$MODE" = "hook" ] && exit 2
    exit 1 ;;
esac

GATE="$(jq_field gate)"
TIMEOUT="$(jq_field timeout)"

if [ "$USE_CACHE" = "yes" ] && [ "$RUN_ALL" = "no" ]; then
  FP="$(tree_fingerprint)"
  SD="$(state_dir)" && [ -f "$SD/verify-green" ] && [ "$(cat "$SD/verify-green" 2>/dev/null)" = "$FP" ] && {
    emit "{\"status\":\"cached_green\",\"fingerprint\":$(jstr "${FP:0:12}")}"
    note "verify.sh: unchanged since the last green run — skipping."
    exit 0
  }
fi

# ---------- run ----------
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" bash -c "$1"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" bash -c "$1"
  else bash -c "$1"
  fi
}

COUNT="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["commands"]))' "$PLAN_TMP")"
note "verify.sh: $COUNT command(s) cover what changed."

RESULTS=""
FAILED=0
FIRST_FAIL_CMD=""
FIRST_FAIL_TAIL=""
i=0
while [ "$i" -lt "$COUNT" ]; do
  CMD="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["commands"][int(sys.argv[2])]["run"])' "$PLAN_TMP" "$i")"
  WHY="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["commands"][int(sys.argv[2])].get("why",""))' "$PLAN_TMP" "$i")"
  CMD_TIMEOUT="$(python3 -c 'import json,sys;c=json.load(open(sys.argv[1]))["commands"][int(sys.argv[2])];print(c.get("timeout") or sys.argv[3])' "$PLAN_TMP" "$i" "$TIMEOUT")"

  note "  → $CMD"
  OUT_TMP="$(mktemp -t devpilot-out.XXXXXX)"
  run_with_timeout "$CMD_TIMEOUT" "$CMD" >"$OUT_TMP" 2>&1
  RC=$?
  TAIL="$(tail -n 40 "$OUT_TMP")"
  rm -f "$OUT_TMP"

  if [ "$RC" -eq 0 ]; then
    note "    ok"
  else
    FAILED=$((FAILED + 1))
    note "    FAILED (exit $RC)"
    note "$TAIL"
    if [ -z "$FIRST_FAIL_CMD" ]; then FIRST_FAIL_CMD="$CMD"; FIRST_FAIL_TAIL="$TAIL"; fi
  fi

  [ -n "$RESULTS" ] && RESULTS="$RESULTS,"
  RESULTS="$RESULTS{\"run\":$(jstr "$CMD"),\"why\":$(jstr "$WHY"),\"exit\":$RC}"
  i=$((i + 1))
done

MANUAL="$(jq_field manual)"
RESULT="{\"status\":$([ "$FAILED" -eq 0 ] && printf '"green"' || printf '"red"'),\"gate\":$(jstr "$GATE"),\"ran\":$COUNT,\"failed\":$FAILED,\"results\":[$RESULTS],\"manual\":$MANUAL}"
emit "$RESULT"

if [ "$FAILED" -eq 0 ]; then
  SD="$(state_dir)" && mkdir -p "$SD" && tree_fingerprint > "$SD/verify-green"
  note "verify.sh: green — $COUNT command(s) passed."
  exit 0
fi

# A red run invalidates any stale green marker.
SD="$(state_dir)" && rm -f "$SD/verify-green" 2>/dev/null

if [ "$MODE" = "hook" ]; then
  if [ "$GATE" = "warn" ]; then
    note "verify.sh: $FAILED command(s) failed (gate=warn — not blocking)."
    exit 0
  fi
  # Exit 2 on a Stop hook feeds stderr back to the model and keeps it working.
  note ""
  note "devpilot verify gate: $FAILED of $COUNT verification command(s) FAILED. The change is not done."
  note "First failure: $FIRST_FAIL_CMD"
  note "$FIRST_FAIL_TAIL"
  note ""
  note "Fix the failure, then re-run: scripts/verify.sh run"
  note "If the command itself is wrong (a test moved, a script was renamed), fix it in .devpilot/verify.json and say so."
  note "Do not disable the gate to get past it."
  exit 2
fi

exit 1
