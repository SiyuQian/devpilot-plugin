---
description: Scan the whole repository for security, edge-case, testing, and doc-drift issues and file them as GitHub issues
---

Invoke the `devpilot:scanning-repos` skill with these arguments: $ARGUMENTS

Follow that skill's instructions end-to-end. If $ARGUMENTS is empty, infer the target from the current repository and branch context as the skill directs.

If the skill instructions are not visible in your context after invoking the Skill tool (for example the tool claims the skill is already loaded but no instructions appear), Read ${CLAUDE_PLUGIN_ROOT}/skills/scanning-repos/SKILL.md directly and follow it end-to-end instead.
