---
description: Stress-test a plan, decision, or idea by grilling you one question at a time
---

Invoke the `devpilot:grilling` skill with these arguments: $ARGUMENTS

Follow that skill's instructions end-to-end. If $ARGUMENTS is empty, infer the topic to grill from the current conversation and repository context as the skill directs.

If the skill instructions are not visible in your context after invoking the Skill tool (for example the tool claims the skill is already loaded but no instructions appear), Read ${CLAUDE_PLUGIN_ROOT}/skills/grilling/SKILL.md directly and follow it end-to-end instead.
