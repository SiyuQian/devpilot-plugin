#!/usr/bin/env bash
# SessionStart hook: keep the local default branch up to date with the remote
# without touching the current branch or working tree.
#
# Shipped with the devpilot plugin; registered via hooks/hooks.json.
#
# - Not in a git repo            -> silently exit
# - On a feature branch          -> fast-forward local default ref via refspec
#                                   (git fetch origin main:main), no checkout
# - On the default branch:
#     - clean tree               -> git merge --ff-only origin/<default>
#     - dirty tree               -> skip, print a hint (never touch the tree)

set -euo pipefail

# Bail quietly if not inside a git work tree.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Resolve the remote's default branch (origin/HEAD -> e.g. "main").
default_branch="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/origin/##')"
if [ -z "$default_branch" ]; then
  # origin/HEAD not set locally; ask the remote once.
  default_branch="$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p')"
fi
[ -z "$default_branch" ] && exit 0

current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"

if [ "$current_branch" != "$default_branch" ]; then
  # Not on the default branch: fast-forward its local ref without a checkout.
  if git fetch origin "$default_branch:$default_branch" >/dev/null 2>&1; then
    echo "✓ local '$default_branch' fast-forwarded to origin (you are on '$current_branch')"
  else
    # Local default has diverged (e.g. local commits); just update the remote ref.
    git fetch origin >/dev/null 2>&1 || true
    echo "⚠ could not fast-forward local '$default_branch' (diverged); fetched origin/$default_branch only"
  fi
  exit 0
fi

# On the default branch.
git fetch origin >/dev/null 2>&1 || true
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  echo "⚠ on '$default_branch' with uncommitted changes — skipping auto-update; run 'git pull --ff-only' when ready"
  exit 0
fi

if git merge --ff-only "origin/$default_branch" >/dev/null 2>&1; then
  echo "✓ '$default_branch' updated to latest origin"
else
  echo "⚠ '$default_branch' could not fast-forward (local commits or divergence) — resolve manually"
fi
