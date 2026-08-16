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

assert_not_contains() {
  local text="$1"
  local unexpected="$2"
  local message="$3"

  [[ "$text" != *"$unexpected"* ]] || fail "$message"
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

test_leaves_feature_branch_untouched() {
  new_fixture "feature-branch"
  git -C "$LOCAL" switch --quiet -c feature
  local feature_head
  feature_head="$(git -C "$LOCAL" rev-parse HEAD)"
  advance_remote

  local output
  output="$(cd "$LOCAL" && bash "$HOOK")"

  assert_equal "$feature_head" "$(git -C "$LOCAL" rev-parse HEAD)" \
    "feature branch HEAD should not move"
  assert_equal "$REMOTE_HEAD" "$(git -C "$LOCAL" rev-parse origin/main)" \
    "feature branch should still fetch origin/main"
  assert_equal "$REMOTE_HEAD" "$(git -C "$LOCAL" rev-parse refs/heads/main)" \
    "local main ref should fast-forward without a checkout"
  assert_not_contains "$output" '"continue":false' \
    "feature branch should never stop the session"
}

test_feature_branch_survives_fetch_failure() {
  new_fixture "feature-branch-offline"
  git -C "$LOCAL" switch --quiet -c feature
  local feature_head
  feature_head="$(git -C "$LOCAL" rev-parse HEAD)"
  git -C "$LOCAL" remote set-url origin "$FIXTURE/missing.git"

  local output
  output="$(cd "$LOCAL" && bash "$HOOK")"

  assert_equal "$feature_head" "$(git -C "$LOCAL" rev-parse HEAD)" \
    "offline feature branch HEAD should not move"
  assert_not_contains "$output" '"continue":false' \
    "fetch failure off the default branch should not stop the session"
}

test_blocks_diverged_detached_worktree() {
  new_fixture "diverged-detached-main"
  git -C "$LOCAL" config user.name "Hook Test"
  git -C "$LOCAL" config user.email "hook-test@example.com"
  echo "local only" >"$LOCAL/mywork.txt"
  git -C "$LOCAL" add mywork.txt
  git -C "$LOCAL" commit --quiet -m "local only work"
  local diverged_head
  diverged_head="$(git -C "$LOCAL" rev-parse HEAD)"
  advance_remote
  git -C "$LOCAL" worktree add --quiet --detach "$FIXTURE/worktree" "$diverged_head"

  local output
  output="$(cd "$FIXTURE/worktree" && bash "$HOOK")"

  assert_equal "$diverged_head" "$(git -C "$FIXTURE/worktree" rev-parse HEAD)" \
    "diverged detached worktree should not be reset"
  [ -f "$FIXTURE/worktree/mywork.txt" ] || \
    fail "diverged detached worktree should keep its local commit content"
  assert_contains "$output" '"continue":false' \
    "diverged detached worktree should stop the session"
}

test_untracked_file_does_not_block() {
  new_fixture "untracked-detached-main"
  local stale_head
  stale_head="$(git -C "$LOCAL" rev-parse HEAD)"
  advance_remote
  git -C "$LOCAL" worktree add --quiet --detach "$FIXTURE/worktree" "$stale_head"
  echo "scratch" >"$FIXTURE/worktree/scratch.log"

  local output
  output="$(cd "$FIXTURE/worktree" && bash "$HOOK")"

  assert_equal "$REMOTE_HEAD" "$(git -C "$FIXTURE/worktree" rev-parse HEAD)" \
    "an untracked-only worktree should still be updated"
  [ -f "$FIXTURE/worktree/scratch.log" ] || \
    fail "the update should not remove untracked files"
  assert_not_contains "$output" '"continue":false' \
    "untracked files alone should not stop the session"
}

run_test "updates clean local main" test_updates_clean_local_main
run_test "updates detached worktree created from stale main" test_updates_detached_worktree_created_from_stale_main
run_test "preserves detached feature commit" test_preserves_detached_feature_commit
run_test "blocks dirty detached worktree on stale main" test_blocks_dirty_detached_worktree_on_stale_main
run_test "blocks when fetch fails" test_blocks_when_fetch_fails
run_test "leaves feature branch untouched" test_leaves_feature_branch_untouched
run_test "feature branch survives fetch failure" test_feature_branch_survives_fetch_failure
run_test "blocks diverged detached worktree" test_blocks_diverged_detached_worktree
run_test "untracked file does not block" test_untracked_file_does_not_block

echo "1..$pass_count"
