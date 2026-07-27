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
| `devpilot:pr-guard` | Watch a PR until it's mergeable and CI is green (resolves conflicts, fixes failing checks) |
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
| `devpilot:grilling` | Stress-test a plan or decision by interviewing you one question at a time |

## Commands

Thin slash-command entry points for the high-traffic skills (each just invokes the corresponding skill):

| Command | Skill |
|---|---|
| `/pr-review` | `devpilot:pr-review` |
| `/pr` | `devpilot:pr-creator` |
| `/pr-guard` | `devpilot:pr-guard` |
| `/repo-scan` | `devpilot:scanning-repos` |
| `/resolve-issues` | `devpilot:resolve-issues` |
| `/dead-code` | `devpilot:dead-code-cleanup` |
| `/grill` | `devpilot:grilling` |

## Agents

The pr-review parallel fanout is implemented as six dedicated plugin agents (`agents/pr-review-*.md`), each with a fixed system prompt and a read-only tool whitelist: `pr-review-behavior-sweep`, `pr-review-bug-scan`, `pr-review-conventions`, `pr-review-git-history`, `pr-review-in-file-comments`, `pr-review-dependency-check`. They are dispatched by `devpilot:pr-review` and are not meant for standalone use.

## Validation

CI runs `scripts/validate.py` on every push/PR — plugin manifest JSON, skill/agent/command frontmatter, `devpilot:<skill>` cross-references, and README skill-table drift. Run it locally with `python3 scripts/validate.py` (needs PyYAML).

## Licensing

The plugin packaging is MIT. Several skills (`clean-code-principles`, `confluence-reviewer`, `content-creator`, `google-go-style`, `learn`, `news-digest`, `pm`, `pr-creator`, `prd-to-issues`, `product-research`, `trello`) derive from Apache-2.0-licensed upstream skill sources; that license is included once at the repo root as `LICENSE-APACHE-2.0.txt`.

## Relationship to the devpilot repo

The original [devpilot](https://github.com/SiyuQian/devpilot) repo remains the home of the Go CLI (`devpilot gmail/slack/trello/graph` helpers). Some skills (`trello`, `scanning-repos`) shell out to that CLI when it is installed; they degrade gracefully without it.

Skills here were migrated from `devpilot/skills/` with the `devpilot-` name prefix dropped (the plugin namespace provides it) and cross-references rewritten to `devpilot:<skill>`.
