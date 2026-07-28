---
name: run-devpilot-plugin
description: >-
  Use to run, test, verify, or smoke-test the devpilot Claude Code plugin — this
  repo's skills, commands, agents, and the scripts/ shell tooling. Covers
  validating the plugin manifests and frontmatter, exercising
  scripts/codegraph.sh across every install state, and executing a skill for
  real in a headless `claude -p` session against a generated fixture repo so you
  can see whether a prose edit actually changes model behavior. Triggers on
  "run the plugin", "test this skill", "does pr-review still work", "smoke test",
  "verify my skill edit".
---

# Run the devpilot plugin

All paths are relative to the repo root (`<unit>/` = this repository).

This plugin has no application window. It is markdown skills plus two shell
scripts, executed by Claude Code — so "running it" means two different things,
and the driver covers both:

| Layer | What it proves | Cost |
|---|---|---|
| **Direct invocation** — `scripts/codegraph.sh` driven through every machine state | The shell tooling behaves; `action` values are right | Free, ~15 s |
| **Headless skill execution** — a real `claude -p` session performing a skill from *this working tree* | The prose actually steers the model | API tokens, ~1–2 min per probe |

The second layer is the one that matters for this repo. A skill edit that reads
perfectly and steers the model wrong is the characteristic bug here, and only a
real session catches it.

Everything runs through one driver:

```
.claude/skills/run-devpilot-plugin/driver.sh
```

## Prerequisites

- **`python3`** — present. Do **not** try to `pip install pyyaml`; on this
  machine's Homebrew python it fails with PEP 668
  `externally-managed-environment`. The driver provisions its own venv at
  `/tmp/devpilot-plugin-driver/venv` on first `validate` run (needs network
  once). Nothing to install by hand.
- **`git`** — used to build the fixture repo.
- **`claude`** CLI — only for `headless` / `smoke-full`.
- **`devpilot`** binary — *optional*. Without it the codegraph checks that need
  a binary skip loudly, and `driver.sh install-live` will fetch one into the
  sandbox. Never required.

No `apt-get` / `brew install` step exists for this repo.

## Run (agent path)

```bash
bash .claude/skills/run-devpilot-plugin/driver.sh smoke
```

That is validate + the full `codegraph.sh` state machine, no API cost. Verified
output:

```
== scripts/validate.py ==
  PASS validate.py: OK — 28 skills, manifests, agents, commands, cross-refs, README all validated.

== scripts/codegraph.sh state machine (sandboxed) ==
  PASS no binary → needs_install
  PASS install without --yes refused (exit 2)
  PASS cold cache → needs_build
  PASS ensure builds cold cache → ready
  PASS ensure idempotent → ready
  PASS preflight payload: mode=built, Hello has 1 caller + untested_public
  PASS after opt-out, status → declined
  PASS after opt-out, ensure does not build → declined
  PASS reset-consent clears the marker

ALL PASS — 10 checks
```

Subcommands:

| Command | What it does |
|---|---|
| `smoke` | `validate` + `codegraph`. The default. No API cost. |
| `validate` | `scripts/validate.py` through the sandbox venv. |
| `codegraph` | 9 assertions on `scripts/codegraph.sh` in a sandbox. |
| `fixture` | Build the Go fixture repo, print its path + base/head SHAs. |
| `headless present\|missing\|declined ["extra prompt"]` | Real `claude -p` session executing pr-review step 1.5 with codegraph in that state. |
| `install-live` | Really downloads devpilot (~28 MB) **into the sandbox**. |
| `smoke-full` | `smoke` + all three headless probes. Costs tokens. |
| `clean` | `rm -rf /tmp/devpilot-plugin-driver`. |

### Verifying a skill edit for real

```bash
bash .claude/skills/run-devpilot-plugin/driver.sh headless missing
```

This copies `skills/pr-review/` into a scratch workspace, launches `claude -p`
there, and makes it execute step 1.5 against the fixture with no devpilot binary
resolvable. Verified result — the session reports:

```json
{"action":"needs_install","reason":"no graph-capable devpilot binary found", ...}
```

and then states the prescribed next action (ask for consent once; install only
on an explicit yes). The driver asserts three things, none of them by matching
the model's prose:

- the session reported `"action":"needs_install"`,
- no opt-out marker was written without user consent,
- nothing was installed unprompted.

`headless present` (binary available → `ready` → preflight runs) and
`headless declined` (opt-out recorded → `declined`, grep fallback, no re-ask)
are the other two states. All three pass as of this writing.

### Sandboxing guarantees

`DEVPILOT_HOME` is forced to `/tmp/devpilot-plugin-driver/devpilot-home`, so no
run touches the user's real graph cache at `~/.devpilot`. `install-live` installs
only into `/tmp/devpilot-plugin-driver/bin`, never `~/.local/bin` or
`/usr/local/bin`, so it cannot disturb an existing devpilot. Override the whole
sandbox location with `DRIVER_SANDBOX=<dir>`.

## Run (human path)

Install this checkout as a real plugin and use it interactively:

```bash
claude plugin marketplace add .
claude plugin install devpilot@devpilot-marketplace
```

Then `/pr-review`, `/batch-review-prs`, etc. Useful for judging feel; useless for
regression-checking an edit, because of the shadowing trap below.

## Gotchas

- **`--plugin-dir <this-repo>` does NOT test this repo.** If the user already has
  `devpilot@devpilot-marketplace` installed, it registers the same
  `devpilot:pr-review` name and **wins**. A probe run this way read
  `~/.claude/plugins/cache/devpilot-marketplace/devpilot/1.0.0/…/graph.md` — the
  stale installed copy — and reported success while testing code that was never
  edited. This is why `headless` copies the skill into a scratch workspace as an
  unnamespaced *project* skill (`pr-review`, not `devpilot:pr-review`) instead.
- **`--bare` and a temp `CLAUDE_CONFIG_DIR` both break auth** →
  `Not logged in · Please run /login`. Credentials live in the macOS Keychain but
  are still not picked up under either. You cannot sandbox a headless probe by
  isolating the config dir; sandbox the *workspace* instead.
- **Invoking the `Skill` tool in a one-turn probe shows you nothing.** It returns
  `Launching skill: <name>`; the instructions load on the *next* turn. Give the
  session work that forces more turns, or you'll conclude the skill is empty.
- **In project-skill mode the plugin agents don't exist.** `devpilot:pr-review-*`
  are registered only when this repo is loaded as a plugin, so step 2's fanout
  cannot run under `headless`. Probes are deliberately scoped to step 1.5.
- **`claude` is a shell alias, not a binary on PATH.** Scripts must resolve
  `$HOME/.local/bin/claude` themselves; the driver's `find_claude` does.
- **`timeout(1)` does not exist on macOS.** A first attempt at bounding a probe
  died with `(eval):1: command not found: timeout`. Don't reach for it.
- **`devpilot graph build` exits 0 while reporting `ok:false`.** Never judge it by
  exit code — `codegraph.sh` reads `graph status`'s `ok` field instead.
- **This repo cannot build its own codegraph, by design.** `driver.sh codegraph`
  runs against a *generated* Go fixture for exactly this reason: pointing
  `codegraph.sh ensure` at this repo returns
  `build_failed: go_no_module: repo contains .go files but no go.mod/go.work`,
  because `skills/harness-engineering/evals/fixtures/` holds Go *fixtures* with
  no module manifest. Expected, not a regression.
- **Opt-out markers are per-worktree.** The marker goes in the git dir, which for
  a worktree is `…/.git/worktrees/<name>/devpilot-codegraph-optout` — declining
  in a worktree does not carry to the main checkout.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ModuleNotFoundError: No module named 'yaml'` | Run `driver.sh validate`, which builds the venv. Do not `pip install --user pyyaml` — PEP 668 blocks it. |
| `Not logged in · Please run /login` from a probe | You added `--bare` or overrode `CLAUDE_CONFIG_DIR`. Remove both. |
| Headless probe passes but your edit clearly isn't loaded | You used `--plugin-dir`. Use `driver.sh headless`, which shadows via a project skill. |
| `command not found: claude` inside a script | Resolve the binary path; `claude` is an alias. |
| `build_failed: go_no_module` | Expected when pointed at this repo. Use the fixture (`driver.sh fixture`). |
| Codegraph checks say `(no devpilot installed …)` | `driver.sh install-live` fetches one into the sandbox. |
| A probe leaves the fixture opted out | `bash scripts/codegraph.sh reset-consent --repo /tmp/devpilot-plugin-driver/fixture` (the driver already does this on exit). |
