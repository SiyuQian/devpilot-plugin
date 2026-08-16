#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../scripts/refresh-default-branch.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/refresh-default-branch.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass_count=0

fail() {
  echo "not ok - $1" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  [ "$expected" = "$actual" ] || fail "$message (expected $expected, got $actual)"
}

assert_contains() {
  local text="$1"
  local expected="$2"
  local message="$3"

  [[ "$text" == *"$expected"* ]] || fail "$message"
}

new_fixture() {
  local name="$1"

  FIXTURE="$TEST_ROOT/$name"
  REMOTE="$FIXTURE/remote.git"
  PUBLISHER="$FIXTURE/publisher"
  LOCAL="$FIXTURE/local"

  mkdir -p "$FIXTURE"
  git init --quiet --bare "$REMOTE"
  git init --quiet --initial-branch=main "$PUBLISHER"
  git -C "$PUBLISHER" config user.name "Hook Test"
  git -C "$PUBLISHER" config user.email "hook-test@example.com"
  echo "initial" >"$PUBLISHER/tracked.txt"
  git -C "$PUBLISHER" add tracked.txt
  git -C "$PUBLISHER" commit --quiet -m "initial"
  git -C "$PUBLISHER" remote add origin "$REMOTE"
  git -C "$PUBLISHER" push --quiet -u origin main
  git -C "$REMOTE" symbolic-ref HEAD refs/heads/main
  git clone --quiet "$REMOTE" "$LOCAL"
}

advance_remote() {
  echo "remote update" >>"$PUBLISHER/tracked.txt"
  git -C "$PUBLISHER" add tracked.txt
  git -C "$PUBLISHER" commit --quiet -m "remote update"
  git -C "$PUBLISHER" push --quiet origin main
  REMOTE_HEAD="$(git -C "$PUBLISHER" rev-parse HEAD)"
}

run_test() {
  local name="$1"
  shift

  "$@"
  pass_count=$((pass_count + 1))
  echo "ok $pass_count - $name"
}

test_updates_clean_local_main() {
  new_fixture "local-main"
  advance_remote

  (cd "$LOCAL" && bash "$HOOK") >/dev/null

  assert_equal "$REMOTE_HEAD" "$(git -C "$LOCAL" rev-parse HEAD)" \
    "clean local main should fast-forward"
}

test_updates_detached_worktree_created_from_stale_main() {
  new_fixture "detached-main"
  local stale_head
  stale_head="$(git -C "$LOCAL" rev-parse HEAD)"
  advance_remote
  git -C "$LOCAL" worktree add --quiet --detach "$FIXTURE/worktree" "$stale_head"

  (cd "$FIXTURE/worktree" && bash "$HOOK") >/dev/null

  assert_equal "$REMOTE_HEAD" "$(git -C "$FIXTURE/worktree" rev-parse HEAD)" \
    "detached worktree created from main should move to origin/main"
}

test_preserves_detached_feature_commit() {
  new_fixture "detached-feature"
  git -C "$LOCAL" config user.name "Hook Test"
  git -C "$LOCAL" config user.email "hook-test@example.com"
  git -C "$LOCAL" switch --quiet -c feature
  echo "feature" >"$LOCAL/feature.txt"
  git -C "$LOCAL" add feature.txt
  git -C "$LOCAL" commit --quiet -m "feature"
  local feature_head
  feature_head="$(git -C "$LOCAL" rev-parse HEAD)"
  advance_remote
  git -C "$LOCAL" worktree add --quiet --detach "$FIXTURE/worktree" "$feature_head"

  (cd "$FIXTURE/worktree" && bash "$HOOK") >/dev/null

  assert_equal "$feature_head" "$(git -C "$FIXTURE/worktree" rev-parse HEAD)" \
    "detached feature commit should not be rewritten"
  assert_equal "$REMOTE_HEAD" "$(git -C "$FIXTURE/worktree" rev-parse origin/main)" \
    "detached feature worktree should still fetch origin/main"
}

test_blocks_dirty_detached_worktree_on_stale_main() {
  new_fixture "dirty-detached-main"
  local stale_head
  stale_head="$(git -C "$LOCAL" rev-parse HEAD)"
  advance_remote
  git -C "$LOCAL" worktree add --quiet --detach "$FIXTURE/worktree" "$stale_head"
  echo "local change" >>"$FIXTURE/worktree/tracked.txt"

  local output
  output="$(cd "$FIXTURE/worktree" && bash "$HOOK")"

  assert_equal "$stale_head" "$(git -C "$FIXTURE/worktree" rev-parse HEAD)" \
    "dirty detached worktree should not be reset"
  assert_contains "$output" '"continue":false' \
    "dirty stale worktree should stop the session"
}

test_blocks_when_fetch_fails() {
  new_fixture "fetch-failure"
  git -C "$LOCAL" remote set-url origin "$FIXTURE/missing.git"

  local output
  output="$(cd "$LOCAL" && bash "$HOOK")"

  assert_contains "$output" '"continue":false' \
    "fetch failure should stop the session"
}

run_test "updates clean local main" test_updates_clean_local_main
run_test "updates detached worktree created from stale main" test_updates_detached_worktree_created_from_stale_main
run_test "preserves detached feature commit" test_preserves_detached_feature_commit
run_test "blocks dirty detached worktree on stale main" test_blocks_dirty_detached_worktree_on_stale_main
run_test "blocks when fetch fails" test_blocks_when_fetch_fails

echo "1..$pass_count"
