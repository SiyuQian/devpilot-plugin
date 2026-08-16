#!/usr/bin/env bash
# SessionStart hook: verify that work based on the default branch starts from
# its latest remote commit.
#
# Shipped with the devpilot plugin; registered via hooks/hooks.json.
#
# Only a checkout that is *based on the default branch* is worth stopping the
# session over; anything else degrades to a warning so the agent still starts.
#
# - Not in a git repo, no origin
#   remote, or no commits yet     -> silently exit
# - Checkout already at
#   origin/<default>              -> report and exit
# - On the default branch         -> fast-forward a clean checkout
# - In a detached worktree created
#   from the default branch       -> reset a clean checkout to origin/<default>
# - On a feature branch, or on a
#   detached feature baseline     -> fetch only, and fast-forward the local
#                                    <default> ref without a checkout
# - Fetch failure or unresolvable
#   origin/<default>              -> stop only when the checkout is based on
#                                    the default branch; otherwise warn
# - Divergence, a dirty stale
#   checkout, or an unverified
#   update                        -> stop before the agent edits old code

set -euo pipefail

# Minimal JSON string escaping — enough for the reason strings this script
# produces (backslash, double quote, tab). Mirrors jstr() in scripts/codegraph.sh.
jstr() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g'
}

stop_session() {
  local escaped
  escaped="$(jstr "$1")"

  printf '{"continue":false,"stopReason":"%s","systemMessage":"%s"}\n' \
    "$escaped" "$escaped"
  exit 0
}

# Bail quietly if there is nothing to verify: not a work tree, no remote to
# compare against, or no commit yet. Every lookup below is guarded because a
# failing command substitution aborts the script under `set -e`, which would
# skip the stop_session paths this hook exists to reach.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
git remote get-url origin >/dev/null 2>&1 || exit 0

starting_head="$(git rev-parse --verify --quiet HEAD 2>/dev/null || true)"
[ -n "$starting_head" ] || exit 0

# Resolve the remote's default branch (origin/HEAD -> e.g. "main").
default_branch="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null \
  | sed 's#^refs/remotes/origin/##' || true)"
if [ -z "$default_branch" ]; then
  # origin/HEAD not set locally; ask the remote once.
  default_branch="$(git remote show origin 2>/dev/null \
    | sed -n 's/.*HEAD branch: //p' || true)"
fi
if [ -z "$default_branch" ]; then
  stop_session "The remote default branch could not be identified. Stopped before editing."
fi

local_default_head="$(git rev-parse "refs/heads/$default_branch" 2>/dev/null || true)"
remote_default_head_before_fetch="$(git rev-parse "refs/remotes/origin/$default_branch" 2>/dev/null || true)"
current_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

# Is the checkout the agent is about to edit derived from the default branch?
based_on_default=false
if [ "$current_branch" = "$default_branch" ]; then
  based_on_default=true
elif [ -z "$current_branch" ] && \
  { [ "$starting_head" = "$local_default_head" ] || \
    [ "$starting_head" = "$remote_default_head_before_fetch" ]; }; then
  based_on_default=true
fi

describe_checkout() {
  if [ -n "$current_branch" ]; then
    printf "branch '%s'" "$current_branch"
  else
    printf 'detached HEAD'
  fi
}

# Fetch. When the default branch is not the one checked out here, use a refspec
# so the local <default> ref fast-forwards too — worktrees and branches created
# from it later then start current. git refuses that refspec for a branch that
# is checked out (in this or another worktree), so fall back to a plain fetch.
fetch_ok=true
if [ "$current_branch" = "$default_branch" ]; then
  git fetch origin "$default_branch" >/dev/null 2>&1 || fetch_ok=false
elif ! git fetch origin "$default_branch:$default_branch" >/dev/null 2>&1; then
  git fetch origin "$default_branch" >/dev/null 2>&1 || fetch_ok=false
fi

if [ "$fetch_ok" = false ]; then
  if [ "$based_on_default" = true ]; then
    stop_session "Git fetch failed and this checkout is based on $default_branch. Stopped before editing to avoid an unverified baseline."
  fi
  echo "⚠ could not fetch origin/$default_branch; $(describe_checkout) left unchanged"
  exit 0
fi

remote_default_head="$(git rev-parse "refs/remotes/origin/$default_branch" 2>/dev/null || true)"
if [ -z "$remote_default_head" ]; then
  if [ "$based_on_default" = true ]; then
    stop_session "origin/$default_branch could not be resolved. Stopped before editing."
  fi
  echo "⚠ origin/$default_branch could not be resolved; $(describe_checkout) left unchanged"
  exit 0
fi

if [ "$starting_head" = "$remote_default_head" ]; then
  echo "✓ checkout already matches latest origin/$default_branch"
  exit 0
fi

if [ "$based_on_default" = false ]; then
  echo "✓ origin/$default_branch fetched; $(describe_checkout) left unchanged"
  exit 0
fi

# Past this point the checkout is based on the default branch and is stale.
# Both updates below rewrite tracked content only, so untracked files must not
# block the session — reset --hard and merge --ff-only never touch them.
if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
  stop_session "This checkout is based on a stale $default_branch and has uncommitted changes. Stopped without modifying them."
fi

if ! git merge-base --is-ancestor "$starting_head" "$remote_default_head"; then
  stop_session "This checkout is based on a $default_branch that has diverged from origin. Stopped without discarding those commits."
fi

if [ "$current_branch" = "$default_branch" ]; then
  if ! git merge --ff-only "origin/$default_branch" >/dev/null 2>&1; then
    stop_session "The local $default_branch could not be fast-forwarded. Stopped before editing."
  fi
elif ! git reset --hard "origin/$default_branch" >/dev/null 2>&1; then
  stop_session "The detached worktree could not be moved to the latest $default_branch. Stopped before editing."
fi

if [ "$(git rev-parse --verify --quiet HEAD 2>/dev/null || true)" != "$remote_default_head" ]; then
  stop_session "The update to origin/$default_branch could not be verified. Stopped before editing."
fi

if [ "$current_branch" = "$default_branch" ]; then
  echo "✓ '$default_branch' updated to latest origin"
else
  echo "✓ detached worktree updated to latest origin/$default_branch"
fi
