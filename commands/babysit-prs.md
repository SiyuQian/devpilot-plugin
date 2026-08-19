---
description: Sweep all my open PRs and make them merge-ready — fix new review comments, merge conflicts, and failing CI (loop-friendly)
---

Invoke the `devpilot:babysit-prs` skill with these arguments: $ARGUMENTS

Follow that skill's instructions end-to-end. If $ARGUMENTS contains `auto` or this run was triggered by /loop or a schedule, use auto/loop mode (skip the Step 2 confirmation).

If the skill instructions are not visible in your context after invoking the Skill tool (for example the tool claims the skill is already loaded but no instructions appear), Read ${CLAUDE_PLUGIN_ROOT}/skills/babysit-prs/SKILL.md directly and follow it end-to-end instead.
