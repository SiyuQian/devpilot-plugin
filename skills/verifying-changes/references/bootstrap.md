# Bootstrapping the manifest in a repo

The goal of this pass is to write down what is **already true** about how this repo is verified. You are documenting, not inventing. Anything you cannot observe, you ask about.

## 1. Read the authoritative sources, in this order

| Source | Why it ranks here |
|---|---|
| CI config (`.github/workflows/*.yml`, `.gitlab-ci.yml`, `Jenkinsfile`) | This is the team's enforced definition of "works". Whatever gates merge is the ground truth. |
| `Makefile` / `Taskfile` / `justfile` targets | The commands humans actually type; usually what CI calls. |
| `package.json` `scripts`, `go.mod`, `pyproject.toml`, `Cargo.toml` | The runner and its invocation. |
| `CLAUDE.md` / `AGENTS.md` / `CONTRIBUTING.md` | Often has a "how to test" section already — reuse its commands verbatim rather than competing with it. |
| Test file layout | Tells you how to scope rules (per-package Go tests, colocated `*.test.ts`, a `tests/` tree). |

If CI runs `make check` and `make check` runs four things, prefer the four things — the gate needs per-area scoping that a single aggregate target can't give.

## 2. Map the repo's surfaces

List the top-level areas a change can touch, and for each: what proves it works, and how long that takes. Something like:

```
internal/auth/     → go test ./internal/auth/...        (4s)
internal/billing/  → go test ./internal/billing/...     (11s)
cmd/api/           → go build ./... && go test ./cmd/... (9s)
web/src/           → npm run typecheck; npm run test     (38s)
migrations/        → make migrate-test                   (22s)  ← needs a DB
docs/, *.md        → (nothing runnable)                  ← leave unmatched, on purpose
```

Paths with nothing runnable should match **no rule**. `nothing_to_do` on a docs edit is the correct outcome, not a gap to paper over.

## 3. Run every candidate command once, before it goes in the file

Non-negotiable. For each:

- Clean tree (`git status --porcelain` empty).
- Run it. Record exit status and wall time.
- **Exit 0** → it goes in, with its measured time.
- **Non-zero** → find out why before writing it in. Missing local dependency (a DB, credentials) means it belongs in `manual` or CI, not `rules`. Genuinely failing tests mean you have found the repo's baseline — record it and tell the user; a pre-existing red suite must never be the excuse that lets a new failure through.
- **Prompts for input or hangs** → cannot be a rule. The hook runs unattended.

A command you have not personally watched exit 0 is a guess, and a guessed rule fails on the next unrelated change, which is how gates lose their credibility.

## 4. Check each rule actually detects breakage

For at least the two or three most important rules, confirm the command is sensitive to the behavior it claims to cover. Cheapest version: find the test function names the command runs (`go test -run` list, the spec file's `describe` blocks) and confirm they assert the behavior in the `why`. If a rule's command is only a build or a lint, its `why` must say so — "compiles", not "auth works".

## 5. Write the manifest and show it to the user

Use the schema in `manifest.md`. Then show a table before committing:

```
| Rule | Paths | Command | Measured | Covers |
|---|---|---|---|---|
| 1 | internal/auth/** | go test ./internal/auth/... | 4s | token rotation, refresh fallback |
| 2 | web/src/** | npm run typecheck; npm run test | 38s | types + login validation |
| always | — | go build ./... | 6s | compiles |

Typical change cost: 10s (Go) / 44s (frontend).
Not covered on purpose: docs/**, *.md — nothing runnable.
Baseline: green, except TestLegacyImport (pre-existing failure, unrelated).
Manual: checkout flow — owner: <who>.
```

The user is agreeing to pay that cost on every single change, so the measured times are the important column. If a surface is too slow to gate, say so and propose either a narrower command or moving it to `manual`/CI — don't quietly include a two-minute rule.

## 6. Wire it into the repo's own context files

Add a short pointer in `CLAUDE.md` / `AGENTS.md`: the manifest is where verification lives, and changes must add a rule for new surfaces. Without that line, the next agent reading only `CLAUDE.md` will keep inventing test commands.

## Repos where this shouldn't be set up

Say so instead of scaffolding:

- **No tests, no build, no lint.** There is nothing to gate on. Offer to add a first real check instead; a manifest of `echo ok` is a false guarantee, and false guarantees are worse than none.
- **Verification requires infrastructure the dev machine doesn't have** (a cluster, a staging DB, paid API keys). Those go in `manual` with an owner, and the honest answer is that this repo's gate is thin.
- **The suite is already deeply red.** Fix or quarantine first, or the gate blocks on failures nobody caused. `gate: "warn"` is a reasonable interim, stated as interim.
