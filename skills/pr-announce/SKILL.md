---
name: pr-announce
description: >
  Use when a pull request needs to be announced in the team's Slack review channel —
  after devpilot:pr-creator opens a PR, or when the user asks to ping the team for
  review. Drafts a one-line message (PR link + summary, no names, no @-mentions),
  shows it for explicit confirmation, and only then posts it to the configured
  channel. Triggers on: "announce the PR", "post it in Slack", "ping the team for
  review", "share the PR in the review channel", "/pr-announce", "发到 slack",
  "通知团队 review". Hand-off target after devpilot:pr-creator.
---

# PR Announce — post a PR to the team's Slack review channel

**Core principle:** the Slack message is *drafted for a human, sent by a human's word*.
This skill never posts without an explicit confirmation in the current turn, because a sent
Slack message cannot be deleted through the connector.

**Scope:** one message, one channel. This skill does not chase reviewers, resolve threads,
watch CI, or follow up. CI/mergeability is `devpilot:pr-guard`'s job.

## Configuration

| Setting | Default | Override |
|---|---|---|
| Channel ID | `C0B0LEKTQKV` (team PR-review channel, VetSoft workspace `idexx-vetsoft.slack.com`) | `$DEVPILOT_SLACK_PR_CHANNEL` if set, else an explicit channel ID in the invocation (`/pr-announce C012ABCDEF`) |

Resolution order: explicit argument → `DEVPILOT_SLACK_PR_CHANNEL` → the default above.
Always state which channel you resolved to when you show the draft.

## Inputs

Resolve the target PR, in this order:

1. A PR URL or number passed in the invocation.
2. The PR just created by `devpilot:pr-creator` in this session (its reported URL).
3. The PR for the current branch: `gh pr view --json number,url,title,body,headRefName`.

If none of those resolve, stop and say so — do not guess a URL. Never announce a PR whose
URL you have not seen printed by `gh` or by the creating skill.

## Step 1 — Compose the message

Exactly one line:

```
<pr-url> — <one-line summary of what the PR does>.
```

- **Link first, em dash, one sentence.** Nothing else — no bullet list, no "cc", no reviewer
  names, no `@` mentions, no `<!here>` / `<!channel>`.
- The summary comes from the PR **title and body you actually read**, not the branch name.
  Say what the change does and what it needs, in a reviewer's terms:
  *"M2M auth + X-API-KEY deprecation is green and mergeable; just needs a review approval."*
- Keep it under ~180 characters. The GitHub unfurl carries the full description — the message
  does not need to repeat it.
- Match the user's language (Chinese PR → Chinese summary), unless the channel convention is English.

**Why no names or mentions:** see [Slack connector rules](#slack-connector-rules). Reviewer
lookup in this org is actively unsafe, and the channel already routes to the right people.

## Step 2 — Show the draft and wait

Print the resolved channel ID and the exact message text, then **stop and wait for an explicit
confirmation from the user in this turn.** This is a hard gate:

- There is no bypass flag, no `--yes`, no "the user seemed to want it sent."
- Silence, a topic change, or an ambiguous reply is **not** confirmation. Do not send.
- If the user edits the wording, re-show the revised draft and wait again.
- If the user declines or ignores it, say the announcement was skipped and stop. **The PR
  itself is unaffected** — never describe a declined announcement as a failure, and never
  re-offer it unprompted.

**In autonomous mode** (invoked by a parent skill rather than a human), you cannot get that
confirmation. Do not send. Return the draft and the resolved channel ID to the parent and say
it needs human confirmation.

## Step 3 — Send

Only after confirmation:

```
mcp__claude_ai_Slack__slack_send_message
  channel_id: <resolved channel ID>
  content: "<pr-url> — <summary>."
  unfurl_app_links: true
```

`unfurl_app_links: true` is required — it is what makes GitHub expand the PR description
under the one-line message.

Then report the returned `message_link` back to the user. If the send fails, report the error
verbatim and do **not** retry with a different channel or a different tool.

If the Slack connector is not authorized in this session, say so and hand the draft back —
the user authorizes claude.ai connectors in their claude.ai connector settings. Do not attempt
an OAuth flow, and do not ask the user for tokens or callback URLs.

## Slack connector rules

These are not preferences; each one cost a real mis-send.

- **Post to the channel by explicit ID.** That is the path that works through the connector.
- **Never DM a user you found via `slack_search_users`.** In this org, user search only surfaces
  `idexx` enterprise-workspace accounts, which include dormant duplicates (blank title, default
  gravatar). The team's real accounts live in the VetSoft workspace and do not appear in search —
  so a search hit is *more* likely to be a dead account than the person you mean.
  Concretely: `U0A10QSM2KT` ("Wesley Coetzee", wesley-coetzee@idexx.com) is a dormant duplicate.
  Never DM it.
- **A sent message cannot be deleted through the connector.** This is the entire reason for the
  draft-first gate. Treat every send as permanent and public.

## Common Mistakes

| Mistake | Fix |
|---|---|
| Sending without an explicit confirmation | Never. Draft → wait → send. There is no bypass |
| Treating a declined draft as a PR-creation failure | The PR stands on its own. Report it as skipped and move on |
| Adding reviewer names or `@`-mentions | Link + one line only. The channel routes to the right people |
| Looking up a reviewer and DMing them | Search returns dormant enterprise duplicates. Channel-by-ID only |
| Pasting the whole PR description into Slack | `unfurl_app_links: true` already shows it. Keep the message one line |
| Summary written from the branch name | Read the PR title/body first, same rule as `devpilot:pr-creator` |
| Guessing the PR URL | Only announce a URL printed by `gh` or by the creating skill |
| Hardcoding the channel when an override is set | Resolve: argument → `DEVPILOT_SLACK_PR_CHANNEL` → default |
| Retrying a failed send on another channel | Report the error verbatim and stop |
