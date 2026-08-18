#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/pr-review-project.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/bin"
cat >"$TEST_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_CALLS"

case "$1 $2" in
  "project view")
    if [[ "${MISSING_SCOPE:-0}" == 1 ]]; then
      printf 'error: your authentication token is missing required scopes [read:project]\n' >&2
      exit 1
    fi
    printf '{"id":"PVT_project","url":"https://github.com/orgs/acme/projects/7"}\n'
    ;;
  "project field-list")
    if [[ "${FIELD_MISSING:-0}" == 1 && ! -f "$GH_STATE/field-created" ]]; then
      printf '{"fields":[]}\n'
    else
      printf '{"fields":[{"id":"PVTSSF_status","name":"Review status","options":[{"id":"opt_waiting","name":"Waiting to be picked up"},{"id":"opt_reviewing","name":"Being reviewed"},{"id":"opt_reviewed","name":"Reviewed"}]}]}\n'
    fi
    ;;
  "project field-create")
    touch "$GH_STATE/field-created"
    printf '{"id":"PVTSSF_status"}\n'
    ;;
  "project item-list")
    if [[ "${ITEM_EXISTS:-0}" == 1 ]]; then
      printf '{"items":[{"id":"PVTI_existing","content":{"url":"https://github.com/acme/widgets/pull/42"}}]}\n'
    else
      printf '{"items":[]}\n'
    fi
    ;;
  "project item-add")
    printf '{"id":"PVTI_new"}\n'
    ;;
  "project item-edit")
    printf '{}\n'
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$TEST_DIR/bin/gh"

export PATH="$TEST_DIR/bin:$PATH"
export GH_CALLS="$TEST_DIR/gh-calls"
export GH_STATE="$TEST_DIR/state"
mkdir -p "$GH_STATE"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_call() {
  grep -F -- "$1" "$GH_CALLS" >/dev/null || fail "missing gh call: $1"
}

assert_no_call() {
  if grep -F -- "$1" "$GH_CALLS" >/dev/null; then
    fail "unexpected gh call: $1"
  fi
}

"$SCRIPT" --help | grep -F "pr-review-project.sh set" >/dev/null \
  || fail "top-level help should succeed"

: >"$GH_CALLS"
FIELD_MISSING=1 "$SCRIPT" setup --project https://github.com/orgs/acme/projects/7 >/dev/null
assert_call "project field-create 7 --owner acme --name Review status --data-type SINGLE_SELECT --single-select-options Waiting to be picked up,Being reviewed,Reviewed --format json"

: >"$GH_CALLS"
ITEM_EXISTS=1 "$SCRIPT" set \
  --project acme/7 \
  --pr https://github.com/acme/widgets/pull/42 \
  --status "Being reviewed" >/dev/null
assert_no_call "project item-add"
assert_call "project item-edit --id PVTI_existing --field-id PVTSSF_status --project-id PVT_project --single-select-option-id opt_reviewing --format json"

: >"$GH_CALLS"
"$SCRIPT" set \
  --project acme/7 \
  --pr https://github.com/acme/widgets/pull/42 \
  --status "Reviewed" >/dev/null
assert_call "project item-add 7 --owner acme --url https://github.com/acme/widgets/pull/42 --format json"
assert_call "project item-edit --id PVTI_new --field-id PVTSSF_status --project-id PVT_project --single-select-option-id opt_reviewed --format json"

: >"$GH_CALLS"
if MISSING_SCOPE=1 "$SCRIPT" setup --project acme/7 >"$TEST_DIR/scope-out" 2>"$TEST_DIR/scope-error"; then
  fail "missing project scope should fail"
fi
grep -F "gh auth refresh -s project" "$TEST_DIR/scope-error" >/dev/null \
  || fail "missing project scope should print the remediation"

printf 'PASS: pr-review-project\n'
