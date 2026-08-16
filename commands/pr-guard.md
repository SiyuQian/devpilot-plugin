---
description: Watch a PR until it is mergeable and CI is green, resolving conflicts and fixing failing checks
---

Invoke the `devpilot:pr-guard` skill with these arguments: $ARGUMENTS

Follow that skill's instructions end-to-end. If $ARGUMENTS is empty, resolve the target PR from the current branch as the skill directs.

If the skill instructions are not visible in your context after invoking the Skill tool (for example the tool claims the skill is already loaded but no instructions appear), Read ${CLAUDE_PLUGIN_ROOT}/skills/pr-guard/SKILL.md directly and follow it end-to-end instead.
