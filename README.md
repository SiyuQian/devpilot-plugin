# DevPilot Plugin

DevPilot as a native [Claude Code plugin](https://docs.anthropic.com/en/docs/claude-code/plugins) — all 25 skills from the [devpilot](https://github.com/SiyuQian/devpilot) catalog, packaged so one install command gives you the whole toolkit, namespaced as `devpilot:<skill>`.

## Install

```bash
claude plugin marketplace add SiyuQian/devpilot-plugin
claude plugin install devpilot@devpilot-marketplace
```

Or from a local checkout:

```bash
claude plugin marketplace add ~/Works/github.com/siyuqian/devpilot-plugin
claude plugin install devpilot@devpilot-marketplace
```

## Skills

| Skill | What it does |
|---|---|
| `devpilot:pr-review` | Review a PR/diff, post inline comments |
| `devpilot:pr-creator` | Create or update pull requests |
| `devpilot:pr-review-queue` | Work through a queue of open PRs |
| `devpilot:resolving-review-threads` | Respond to inline review comments after pushing fixes |
| `devpilot:scanning-repos` | Full-repo audit (security, edge cases, coverage, doc drift) → GitHub issues |
| `devpilot:issue-triage` | Triage and classify open GitHub issues |
| `devpilot:resolve-issues` | Burn down open issues with implementer subagents |
| `devpilot:prd-to-issues` | Decompose a PRD/spec into a GitHub issue tree |
| `devpilot:auto-feature` | End-to-end feature implementation |
| `devpilot:google-go-style` | Google Go style guide enforcement |
| `devpilot:clean-code-principles` | Language-agnostic clean-code review principles |
| `devpilot:dead-code-cleanup` | Find and remove dead code (Go/TS) |
| `devpilot:e2e-tests` | End-to-end test authoring |
| `devpilot:harness-engineering` | Make a repo agent-friendly (guardrails, context files) |
| `devpilot:agent-self-evolution` | Agent self-improvement loops |
| `devpilot:prompt-review` | Review and improve prompts |
| `devpilot:content-creator` | SEO-optimized blog and content writing |
| `devpilot:cv-writer` | CV / resume writing |
| `devpilot:product-research` | Product research workflows |
| `devpilot:pm` | Product management helpers |
| `devpilot:learn` | Learning / study workflows |
| `devpilot:news-digest` | News digests |
| `devpilot:daily-toolkit` | Daily productivity toolkit |
| `devpilot:confluence-reviewer` | Review Confluence docs |
| `devpilot:trello` | Trello card workflows (uses devpilot CLI credential store) |

## Relationship to the devpilot repo

The original [devpilot](https://github.com/SiyuQian/devpilot) repo remains the home of the Go CLI (`devpilot gmail/slack/trello/graph` helpers). Some skills (`trello`, `scanning-repos`) shell out to that CLI when it is installed; they degrade gracefully without it.

Skills here were migrated from `devpilot/skills/` with the `devpilot-` name prefix dropped (the plugin namespace provides it) and cross-references rewritten to `devpilot:<skill>`.
