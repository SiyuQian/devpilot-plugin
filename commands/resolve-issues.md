---
description: Burn down open GitHub issues with implementer subagents
---

Invoke the `devpilot:resolve-issues` skill with these arguments: $ARGUMENTS

Follow that skill's instructions end-to-end. If $ARGUMENTS is empty, infer the target from the current repository and branch context as the skill directs.

If the skill instructions are not visible in your context after invoking the Skill tool (for example the tool claims the skill is already loaded but no instructions appear), Read ${CLAUDE_PLUGIN_ROOT}/skills/resolve-issues/SKILL.md directly and follow it end-to-end instead.
