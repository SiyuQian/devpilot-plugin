---
description: Create or update a pull request from the current branch
---

Invoke the `devpilot:pr-creator` skill with these arguments: $ARGUMENTS

Follow that skill's instructions end-to-end. If $ARGUMENTS is empty, infer the target from the current repository and branch context as the skill directs.

If the skill instructions are not visible in your context after invoking the Skill tool (for example the tool claims the skill is already loaded but no instructions appear), Read ${CLAUDE_PLUGIN_ROOT}/skills/pr-creator/SKILL.md directly and follow it end-to-end instead.
