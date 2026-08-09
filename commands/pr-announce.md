---
description: Announce a pull request in the team's Slack review channel (draft first, send only on confirmation)
---

Invoke the `devpilot:pr-announce` skill with these arguments: $ARGUMENTS

Follow that skill's instructions end-to-end. $ARGUMENTS may contain a PR URL/number, a Slack
channel ID, or both — if empty, resolve the PR from the current branch as the skill directs.

Never send the Slack message without explicit confirmation from the user in this turn.
