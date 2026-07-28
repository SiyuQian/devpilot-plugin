# DevPilot Plugin

DevPilot as a native [Claude Code plugin](https://docs.anthropic.com/en/docs/claude-code/plugins) — all 28 skills from the [devpilot](https://github.com/SiyuQian/devpilot) catalog, packaged so one install command gives you the whole toolkit, namespaced as `devpilot:<skill>`.

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
| `devpilot:pr-review-queue` | Work through a queue of open PRs (via the `devpilot` CLI) |
| `devpilot:batch-review-prs` | Review-inbox sweep with `gh` only — claim labels, already-reviewed-at-HEAD skip, local-checkout sync |
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
| `/batch-review-prs` | `devpilot:batch-review-prs` |

## Agents

The pr-review parallel fanout is implemented as six dedicated plugin agents (`agents/pr-review-*.md`), each with a fixed system prompt and a read-only tool whitelist: `pr-review-behavior-sweep`, `pr-review-bug-scan`, `pr-review-conventions`, `pr-review-git-history`, `pr-review-in-file-comments`, `pr-review-dependency-check`. They are dispatched by `devpilot:pr-review` and are not meant for standalone use.

## Codegraph

`devpilot:pr-review` grounds its blast-radius analysis in a real call graph rather than grep. That capability comes from the `devpilot` binary's `graph` subcommand — but the plugin does **not** require you to have installed it. All graph access goes through `scripts/codegraph.sh`, which:

- resolves a graph-capable binary from `$PATH`, `~/.local/bin`, `/usr/local/bin`, `/opt/homebrew/bin`, and `$GOPATH/bin` (feature-probing `graph preflight`, since older devpilot releases lack it);
- reports `needs_install` when there is none, so the skill can **offer** the install instead of silently degrading to grep forever;
- runs the official upstream installer on explicit consent (`install --yes`), checksum-verified, into `~/.local/bin` by default so no `sudo` prompt can hang a headless session;
- builds the graph cache when the repo has never been indexed (`ensure`);
- records a per-repo opt-out so a user who declines is never asked again.

It never prompts — a `read` would hang `claude -p`. The agent asks; the script acts. Every subcommand prints one line of JSON on stdout and progress on stderr.

```bash
scripts/codegraph.sh ensure --repo .            # safe unattended; never installs
scripts/codegraph.sh install --yes --repo .     # only after the user says yes
scripts/codegraph.sh -- preflight --base A --head B
```

## Running and testing the plugin

`.claude/skills/run-devpilot-plugin/` (the `/run-devpilot-plugin` skill) drives this repo:

```bash
bash .claude/skills/run-devpilot-plugin/driver.sh smoke        # validate + codegraph state machine
bash .claude/skills/run-devpilot-plugin/driver.sh headless missing   # real claude -p session
```

The `headless` mode is the one that matters for skill edits: it copies a skill into a scratch workspace as a project skill and executes it in a real `claude -p` session, so you can see whether a prose change actually moves model behavior. It deliberately avoids `--plugin-dir`, which is shadowed by any installed copy of this plugin. See that skill's `SKILL.md` for the trap list.

## Validation

CI runs `scripts/validate.py` on every push/PR — plugin manifest JSON, skill/agent/command frontmatter, `devpilot:<skill>` cross-references, and README skill-table drift. Run it locally with `python3 scripts/validate.py` (needs PyYAML), or via `driver.sh validate`, which provisions its own venv (a Homebrew/system python3 refuses `pip install` under PEP 668).

## Licensing

The plugin packaging is MIT. Several skills (`clean-code-principles`, `confluence-reviewer`, `content-creator`, `google-go-style`, `learn`, `news-digest`, `pm`, `pr-creator`, `prd-to-issues`, `product-research`, `trello`) derive from Apache-2.0-licensed upstream skill sources; that license is included once at the repo root as `LICENSE-APACHE-2.0.txt`.

## Relationship to the devpilot repo

The original [devpilot](https://github.com/SiyuQian/devpilot) repo remains the home of the Go CLI (`devpilot gmail/slack/trello/graph` helpers). Some skills (`trello`, `scanning-repos`) shell out to that CLI when it is installed; they degrade gracefully without it.

`devpilot:pr-review` is the exception: rather than degrade, it bootstraps. Its graph step goes through `scripts/codegraph.sh` (see [Codegraph](#codegraph) above), which installs the binary on consent so the capability becomes available instead of staying permanently off. `pr-review`'s *other* two CLI touchpoints (`pr-review preflight`, `pr-review post`) remain pure optimizations with `gh` as the contract.

Skills here were migrated from `devpilot/skills/` with the `devpilot-` name prefix dropped (the plugin namespace provides it) and cross-references rewritten to `devpilot:<skill>`.
