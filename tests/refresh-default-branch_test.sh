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

advance_remote_with_new_file() {
  local name="$1"
  local content="$2"

  printf '%s\n' "$content" >"$PUBLISHER/$name"
  git -C "$PUBLISHER" add "$name"
  git -C "$PUBLISHER" commit --quiet -m "add $name"
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
  advance_remote
  # Learn about the newer origin/main, then lose the remote: HEAD is now known
  # to be behind and the hook cannot verify it, which is what must stop.
  git -C "$LOCAL" fetch --quiet origin main
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

test_updates_detached_worktree_after_local_default_advanced() {
  new_fixture "detached-after-local-advance"
  local stale_head
  stale_head="$(git -C "$LOCAL" rev-parse HEAD)"
  advance_remote
  git -C "$LOCAL" worktree add --quiet --detach "$FIXTURE/worktree" "$stale_head"
  # A sibling session runs the hook first and fast-forwards refs/heads/main, so
  # the stale worktree now matches neither refs/heads/main nor origin/main.
  git -C "$LOCAL" switch --quiet -c feature
  (cd "$LOCAL" && bash "$HOOK") >/dev/null
  assert_equal "$REMOTE_HEAD" "$(git -C "$LOCAL" rev-parse refs/heads/main)" \
    "the sibling run should have advanced the local main ref"

  (cd "$FIXTURE/worktree" && bash "$HOOK") >/dev/null

  assert_equal "$REMOTE_HEAD" "$(git -C "$FIXTURE/worktree" rev-parse HEAD)" \
    "a detached worktree in the main line should update even after main advanced"
}

test_untracked_collision_is_not_clobbered() {
  new_fixture "untracked-collision"
  local stale_head
  stale_head="$(git -C "$LOCAL" rev-parse HEAD)"
  advance_remote_with_new_file "collide.txt" "remote version"
  git -C "$LOCAL" worktree add --quiet --detach "$FIXTURE/worktree" "$stale_head"
  echo "my notes" >"$FIXTURE/worktree/collide.txt"

  local output
  output="$(cd "$FIXTURE/worktree" && bash "$HOOK")"

  assert_equal "my notes" "$(cat "$FIXTURE/worktree/collide.txt")" \
    "an untracked file colliding with an incoming path must not be overwritten"
  assert_equal "$stale_head" "$(git -C "$FIXTURE/worktree" rev-parse HEAD)" \
    "the worktree should not move when the update is refused"
  assert_contains "$output" '"continue":false' \
    "an untracked collision should stop the session"
}

test_unset_origin_head_offline_does_not_stop() {
  # `git init` + `git remote add` never sets origin/HEAD, so an unreachable
  # remote leaves the default branch unidentifiable. `git clone` always sets it,
  # which is why new_fixture cannot reach this path.
  FIXTURE="$TEST_ROOT/unset-origin-head"
  LOCAL="$FIXTURE/local"
  mkdir -p "$LOCAL"
  git init --quiet --initial-branch=main "$LOCAL"
  git -C "$LOCAL" config user.name "Hook Test"
  git -C "$LOCAL" config user.email "hook-test@example.com"
  echo "initial" >"$LOCAL/tracked.txt"
  git -C "$LOCAL" add tracked.txt
  git -C "$LOCAL" commit --quiet -m "initial"
  git -C "$LOCAL" switch --quiet -c feature
  git -C "$LOCAL" remote add origin "$FIXTURE/missing.git"

  local output
  output="$(cd "$LOCAL" && bash "$HOOK")"

  assert_not_contains "$output" '"continue":false' \
    "an unidentifiable default branch should not stop the session"
}

test_allows_default_branch_ahead_of_origin() {
  new_fixture "default-ahead"
  git -C "$LOCAL" config user.name "Hook Test"
  git -C "$LOCAL" config user.email "hook-test@example.com"
  echo "unpushed" >"$LOCAL/unpushed.txt"
  git -C "$LOCAL" add unpushed.txt
  git -C "$LOCAL" commit --quiet -m "unpushed local work"
  local ahead_head
  ahead_head="$(git -C "$LOCAL" rev-parse HEAD)"

  local output
  output="$(cd "$LOCAL" && bash "$HOOK")"

  assert_equal "$ahead_head" "$(git -C "$LOCAL" rev-parse HEAD)" \
    "a default branch ahead of origin should not move"
  assert_not_contains "$output" '"continue":false' \
    "unpushed commits on the default branch should not stop the session"
}

test_offline_up_to_date_default_continues() {
  new_fixture "offline-up-to-date"
  local head
  head="$(git -C "$LOCAL" rev-parse HEAD)"
  git -C "$LOCAL" remote set-url origin "$FIXTURE/missing.git"

  local output
  output="$(cd "$LOCAL" && bash "$HOOK")"

  assert_equal "$head" "$(git -C "$LOCAL" rev-parse HEAD)" \
    "an offline up-to-date default branch should not move"
  assert_not_contains "$output" '"continue":false' \
    "a fetch failure on a checkout matching last known origin/main should not stop"
}

test_blocks_dirty_local_default_branch() {
  new_fixture "dirty-local-main"
  local stale_head
  stale_head="$(git -C "$LOCAL" rev-parse HEAD)"
  advance_remote
  echo "local change" >>"$LOCAL/tracked.txt"

  local output
  output="$(cd "$LOCAL" && bash "$HOOK")"

  assert_equal "$stale_head" "$(git -C "$LOCAL" rev-parse HEAD)" \
    "a dirty local default branch should not be fast-forwarded"
  assert_contains "$output" '"continue":false' \
    "a dirty stale default branch should stop the session"
}

test_blocks_diverged_local_default_branch() {
  new_fixture "diverged-local-main"
  git -C "$LOCAL" config user.name "Hook Test"
  git -C "$LOCAL" config user.email "hook-test@example.com"
  echo "local only" >"$LOCAL/mywork.txt"
  git -C "$LOCAL" add mywork.txt
  git -C "$LOCAL" commit --quiet -m "local only work"
  local diverged_head
  diverged_head="$(git -C "$LOCAL" rev-parse HEAD)"
  advance_remote

  local output
  output="$(cd "$LOCAL" && bash "$HOOK")"

  assert_equal "$diverged_head" "$(git -C "$LOCAL" rev-parse HEAD)" \
    "a diverged local default branch should not be reset"
  [ -f "$LOCAL/mywork.txt" ] || \
    fail "a diverged local default branch should keep its local commit content"
  assert_contains "$output" '"continue":false' \
    "a diverged local default branch should stop the session"
}

test_fetch_falls_back_when_default_checked_out_elsewhere() {
  new_fixture "refspec-fallback"
  advance_remote
  # $LOCAL keeps main checked out, so `git fetch origin main:main` from the
  # worktree is refused and the plain-fetch fallback has to carry the session.
  git -C "$LOCAL" worktree add --quiet -b feature "$FIXTURE/worktree"

  local output
  output="$(cd "$FIXTURE/worktree" && bash "$HOOK")"

  assert_equal "$REMOTE_HEAD" "$(git -C "$FIXTURE/worktree" rev-parse origin/main)" \
    "the plain-fetch fallback should still advance origin/main"
  assert_not_contains "$output" '"continue":false' \
    "a refused refspec should not be reported as a fetch failure"
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
run_test "updates detached worktree after local default advanced" test_updates_detached_worktree_after_local_default_advanced
run_test "untracked collision is not clobbered" test_untracked_collision_is_not_clobbered
run_test "unset origin/HEAD offline does not stop" test_unset_origin_head_offline_does_not_stop
run_test "allows default branch ahead of origin" test_allows_default_branch_ahead_of_origin
run_test "offline up-to-date default continues" test_offline_up_to_date_default_continues
run_test "blocks dirty local default branch" test_blocks_dirty_local_default_branch
run_test "blocks diverged local default branch" test_blocks_diverged_local_default_branch
run_test "fetch falls back when default checked out elsewhere" test_fetch_falls_back_when_default_checked_out_elsewhere

echo "1..$pass_count"
