#!/usr/bin/env bash
# SessionStart hook: verify that work based on the default branch starts from
# its latest remote commit.
#
# Shipped with the devpilot plugin; registered via hooks/hooks.json.
#
# - Not in a git repo             -> silently exit
# - On the default branch         -> fast-forward a clean checkout
# - In a detached worktree created
#   from the default branch       -> reset a clean checkout to origin/<default>
# - On a feature branch           -> fetch only; never rewrite the branch
# - Fetch failure, divergence, or
#   a dirty stale checkout        -> stop before the agent edits old code

set -euo pipefail

stop_session() {
  local reason="$1"

  printf '{"continue":false,"stopReason":"%s","systemMessage":"%s"}\n' \
    "$reason" "$reason"
  exit 0
}

# Bail quietly if not inside a git work tree.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
git remote get-url origin >/dev/null 2>&1 || exit 0

# Resolve the remote's default branch (origin/HEAD -> e.g. "main").
default_branch="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/origin/##')"
if [ -z "$default_branch" ]; then
  # origin/HEAD not set locally; ask the remote once.
  default_branch="$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p')"
fi
if [ -z "$default_branch" ]; then
  stop_session "The remote default branch could not be identified. Codex stopped before editing."
fi

starting_head="$(git rev-parse HEAD)"
local_default_head="$(git rev-parse "refs/heads/$default_branch" 2>/dev/null || true)"
remote_default_head_before_fetch="$(git rev-parse "refs/remotes/origin/$default_branch" 2>/dev/null || true)"
current_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

if ! git fetch origin "$default_branch" >/dev/null 2>&1; then
  stop_session "Git fetch failed. Codex stopped before editing to avoid using an unverified baseline."
fi

remote_default_head="$(git rev-parse "refs/remotes/origin/$default_branch" 2>/dev/null || true)"
if [ -z "$remote_default_head" ]; then
  stop_session "The remote default branch could not be resolved. Codex stopped before editing."
fi

if [ "$starting_head" = "$remote_default_head" ]; then
  echo "✓ checkout already matches latest origin/$default_branch"
  exit 0
fi

if [ "$current_branch" = "$default_branch" ]; then
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    stop_session "The local default branch is stale and has uncommitted changes. Codex stopped without modifying them."
  fi

  if ! git merge-base --is-ancestor "$starting_head" "$remote_default_head"; then
    stop_session "The local default branch has diverged from origin. Codex stopped without rewriting history."
  fi

  if ! git merge --ff-only "origin/$default_branch" >/dev/null 2>&1; then
    stop_session "The local default branch could not be fast-forwarded. Codex stopped before editing."
  fi

  if [ "$(git rev-parse HEAD)" != "$remote_default_head" ]; then
    stop_session "The local default branch update could not be verified. Codex stopped before editing."
  fi

  echo "✓ '$default_branch' updated to latest origin"
  exit 0
fi

if [ -z "$current_branch" ]; then
  based_on_default=false
  if [ "$starting_head" = "$local_default_head" ] || \
    [ "$starting_head" = "$remote_default_head_before_fetch" ]; then
    based_on_default=true
  fi

  if [ "$based_on_default" = false ]; then
    echo "✓ origin/$default_branch fetched; detached feature baseline left unchanged"
    exit 0
  fi

  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    stop_session "The detached worktree is based on stale main and has uncommitted changes. Codex stopped without modifying them."
  fi

  if ! git reset --hard "origin/$default_branch" >/dev/null 2>&1; then
    stop_session "The detached worktree could not be moved to the latest default branch. Codex stopped before editing."
  fi

  if [ "$(git rev-parse HEAD)" != "$remote_default_head" ]; then
    stop_session "The detached worktree update could not be verified. Codex stopped before editing."
  fi

  echo "✓ detached worktree updated to latest origin/$default_branch"
  exit 0
fi

echo "✓ origin/$default_branch fetched; feature branch '$current_branch' left unchanged"
