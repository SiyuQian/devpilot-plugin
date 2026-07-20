# Changelog

## 1.1.0 — 2026-07-21

- **agents/**: the six pr-review fanout briefs (A–F) are now plugin agent
  definitions (`devpilot:pr-review-*`) with fixed system prompts and read-only
  tool whitelists; `skills/pr-review/references/fanout.md` slimmed to dispatch
  instructions with a standalone fallback.
- **commands/**: thin slash-command entry points — `/pr-review`, `/repo-scan`,
  `/dead-code`, `/resolve-issues`, `/pr`.
- **CI**: GitHub Action (`validate.yml`) runs `scripts/validate.py` — checks
  plugin manifests, skill/agent/command frontmatter, `devpilot:<skill>`
  cross-references, residual old-style `devpilot-` prefixes, and README skill
  table drift.
- Fixed a migration artifact in `skills/harness-engineering/evals/README.md`
  (a workspace directory name mis-rewritten as a skill reference).
- Consolidated 11 identical per-skill Apache-2.0 `LICENSE.txt` copies into a
  single root `LICENSE-APACHE-2.0.txt`.
- De-duplicated plugin/marketplace descriptions.

## 1.0.0

- Initial plugin packaging: 25 skills migrated from `devpilot/skills/` with the
  `devpilot-` prefix dropped and cross-references rewritten to
  `devpilot:<skill>`.
