#!/usr/bin/env bash
# Gating logic for the Stop hook. Cheap (no API): asserts WHEN it speaks.
# The expensive end-to-end counterpart is:
#   .claude/skills/run-devpilot-plugin/driver.sh select finished
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../scripts/pr-on-finish.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pr-on-finish.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

# gh would make these tests depend on network + auth state. Shadow it with a
# stub that reports "no open PR", so the tests exercise the local gating only.
mkdir -p "$TEST_ROOT/bin"
printf '#!/usr/bin/env bash\necho 0\n' > "$TEST_ROOT/bin/gh"
chmod +x "$TEST_ROOT/bin/gh"
export PATH="$TEST_ROOT/bin:$PATH"

n=0
fail() { echo "not ok $n - $1" >&2; exit 1; }
ok()   { n=$((n+1)); echo "ok $n - $1"; }

# speaks <dir> <stdin-json> -> "yes"/"no"
speaks() {
  local out; out=$(cd "$1" && printf '%s' "$2" | bash "$HOOK" 2>/dev/null)
  # Tolerant of JSON spacing — the hook serialises via python json.dumps.
  case $out in *'"decision"'*'"block"'*) echo yes ;; *) echo no ;; esac
}

# A repo on a feature branch with committed work ahead of origin/main.
make_repo() {
  local d="$TEST_ROOT/$1"
  git init -q --bare "$d.origin.git"
  git init -q -b main "$d"
  git -C "$d" remote add origin "$d.origin.git"
  echo seed > "$d/f.txt"
  git -C "$d" add -A
  git -C "$d" -c user.email=t@t -c user.name=t commit -qm seed
  git -C "$d" push -q origin main
  git -C "$d" remote set-head origin -a >/dev/null 2>&1
  echo "$d"
}

r=$(make_repo finished)
git -C "$r" checkout -qb feat/x
echo more >> "$r/f.txt"
git -C "$r" -c user.email=t@t -c user.name=t commit -qam "feat: x"
[ "$(speaks "$r" '{}')" = yes ] || fail "should nudge: feature branch, 1 commit ahead, no PR"
ok "nudges on a finished feature branch"

[ "$(speaks "$r" '{"stop_hook_active":true}')" = no ] || fail "must not re-enter"
ok "re-entry guard silences the loop"

# Same repo, same commits — but a PR already exists.
printf '#!/usr/bin/env bash\necho 1\n' > "$TEST_ROOT/bin/gh"
[ "$(speaks "$r" '{}')" = no ] || fail "PR already open"
ok "silent when a PR is already open"
printf '#!/usr/bin/env bash\necho 0\n' > "$TEST_ROOT/bin/gh"

# On the default branch: pr-creator's own auto-recover owns that case.
git -C "$r" checkout -q main
[ "$(speaks "$r" '{}')" = no ] || fail "on default branch"
ok "silent on the default branch"

# Feature branch with no commits ahead: nothing to ship.
r2=$(make_repo nothing)
git -C "$r2" checkout -qb feat/empty
[ "$(speaks "$r2" '{}')" = no ] || fail "no commits ahead"
ok "silent with no commits ahead"

# Uncommitted work only is mid-edit, not finished.
echo dirty >> "$r2/f.txt"
[ "$(speaks "$r2" '{}')" = no ] || fail "dirty tree is not finished"
ok "silent on uncommitted-only changes"

# Not a git repo at all.
mkdir -p "$TEST_ROOT/plain"
[ "$(speaks "$TEST_ROOT/plain" '{}')" = no ] || fail "non-git dir"
ok "silent outside a git repo"

# No origin/HEAD to resolve a base from.
git init -q -b main "$TEST_ROOT/noremote"
git -C "$TEST_ROOT/noremote" checkout -qb feat/y 2>/dev/null
[ "$(speaks "$TEST_ROOT/noremote" '{}')" = no ] || fail "no origin/HEAD"
ok "silent when the default branch cannot be resolved"

echo "1..$n"
