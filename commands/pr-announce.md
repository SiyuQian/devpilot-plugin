---
description: Announce a pull request in the team's Slack review channel (draft first, send only on confirmation)
---

Invoke the `devpilot:pr-announce` skill with these arguments: $ARGUMENTS

Follow that skill's instructions end-to-end. $ARGUMENTS may contain a PR URL/number, a Slack
channel ID, or both — if empty, resolve the PR from the current branch as the skill directs.

Never send the Slack message without explicit confirmation from the user in this turn.

If the skill instructions are not visible in your context after invoking the Skill tool (for example the tool claims the skill is already loaded but no instructions appear), Read ${CLAUDE_PLUGIN_ROOT}/skills/pr-announce/SKILL.md directly and follow it end-to-end instead.
