---
name: verifying-changes
description: Use when the question is how a feature or area of this repo is verified, or when a change needs to be proven still-working before it is called done — "how is this tested", "what should I run after changing X", "set up the verify gate", "make sure the app still runs after my changes", "the verify gate failed", "add a verify rule for this feature". Owns `.devpilot/verify.json`, the per-repo map from path globs to the commands that prove those paths work, which the Stop hook (`scripts/verify.sh`) runs automatically after every change. Do NOT use to author new tests (use devpilot:e2e-tests for browser specs) or to review a PR (use devpilot:pr-review).
license: MIT
---

# Verifying changes

## Files in this skill

| File | When to load |
|---|---|
| `references/manifest.md` | Writing or editing `.devpilot/verify.json` — full schema, glob semantics, worked examples. |
| `references/bootstrap.md` | First time in a repo: how to discover the real verification commands instead of guessing them. |

## Overview

Two problems, one artifact.

1. **"How is this feature tested?"** — normally this is rediscovered every time someone touches the code, by reading CI config and guessing. Record it once: `.devpilot/verify.json` maps path globs to the commands that prove those paths still work, each with a `why` naming the behavior it covers.
2. **"Is the program still running after my change?"** — the plugin's `Stop` hook runs `scripts/verify.sh hook` after every change, resolves what changed against that manifest, runs only the matching commands, and **blocks completion** if any fail. No command to type, no workflow to enter.

There is deliberately no slash command and no entry point. The gate is either on for a repo (the manifest exists) or off (it doesn't).

**Core principle:** the manifest is a record of what is *actually* true about this repo's verification, not an aspiration. A rule whose command doesn't exist, or that passes when the feature is broken, is worse than no rule — it converts "unverified" into "verified" on the reviewer's screen.

## When NOT to use

- Writing new tests from scratch → write the test; then come back and add the rule. `devpilot:e2e-tests` for Playwright specs.
- Reviewing a diff → `devpilot:pr-review`.
- A repo with no runnable verification at all (no tests, no build, no lint) → say so plainly. Do not scaffold a manifest full of `echo ok`; a green gate that proves nothing is a lie the whole team will rely on.

## How the gate behaves

| Situation | Result |
|---|---|
| No `.devpilot/verify.json` | No-op. The hook exits 0 and prints `no_manifest`. |
| Change touches paths no rule matches | No-op, reported as `nothing_to_do`. |
| Nothing changed since the last green run | Skipped via a fingerprint of the change set (`cached_green`) — no suite re-run. |
| Matching commands all pass | Green; the fingerprint is recorded. |
| Any command fails, `gate: "block"` | Hook exits 2 → the agent is told what failed and keeps working. |
| Any command fails, `gate: "warn"` | Reported, not blocking. |
| Manifest is invalid JSON or bad schema | Treated as a failure, not a pass. |
| `DEVPILOT_VERIFY=off`, or `.devpilot/verify.off` exists | No-op. |

The change set is the union of uncommitted, staged, untracked, and already-committed-since-`origin/<default>` paths — an agent that committed mid-session is still gated on what it committed.

```bash
scripts/verify.sh plan --repo .    # what would run, and why — runs nothing
scripts/verify.sh run --repo .     # run it now, for what changed
scripts/verify.sh run --all        # every rule, ignoring the change set
scripts/verify.sh init --repo .    # placeholder manifest (never overwrites)
```

## Setting the gate up in a repo

Load `references/bootstrap.md` and follow it. The short version:

1. **Find the real commands.** Read the CI workflow, `Makefile`, `package.json` scripts, `go.mod`, `pyproject.toml`, and any `CONTRIBUTING.md` / `CLAUDE.md` verification section. CI is the highest-authority source — it is the definition of "works" that the team already enforces.
2. **Run each candidate command once, on a clean tree, before writing it into the manifest.** A command you have not seen exit 0 is a guess. Record the baseline: if the suite is already red, say which tests, and never let that excuse a new failure.
3. **Scope the rules so the common change runs in under a minute or two.** One `**` rule that runs the entire suite makes the gate so slow it gets turned off. Split by package / surface.
4. **Write the `why` for every rule** in behavior terms ("token rotation and refresh-failure fallback"), not command terms ("runs go test"). This field is the answer to "how is this feature tested" — it is the reason the file exists.
5. **Show the manifest to the user before committing it**, with the measured runtime per rule. They are agreeing to pay that cost on every change.

## Keeping it honest

This is the part that decays, so treat it as part of the change, not as cleanup:

- **A new feature lands → a rule covers it.** If a change adds a surface that no existing glob matches, add the rule in the same commit. `scripts/verify.sh plan` printing `nothing_to_do` for a real feature change is the signal.
- **A test or script gets renamed → fix the command.** A rule pointing at a command that no longer runs will surface as a gate failure. Fix the manifest and say out loud that you did — an amendment to the contract is not a silent edit.
- **A rule proves nothing → delete or replace it.** Ask periodically: if I broke this feature, would this command go red? If not, the rule is decoration.
- **Do not widen a command to make a red gate green.** Swapping `go test ./internal/auth/...` for `go build ./...` to get past a failure is falsifying the record.
- **Do not disable the gate to finish a task.** `.devpilot/verify.off` and `DEVPILOT_VERIFY=off` exist for the user, not for the agent. If the gate is wrong, fix the manifest; if the code is wrong, fix the code.

## When the gate fires

The hook hands you the failing command and the tail of its output. In order:

1. **Read the failure before touching anything.** Is it your change, or a pre-existing failure the manifest's baseline already noted?
2. **If your change broke it** — fix the code, then re-run `scripts/verify.sh run`. Not the narrower test you prefer; the command the manifest names.
3. **If the command is stale** (the test moved, the script was renamed) — fix `.devpilot/verify.json`, re-run, and tell the user which rule you amended and why.
4. **If the failure is flaky** — re-run once to confirm, and if it is genuinely nondeterministic, report it as a flake with evidence rather than looping until it passes by chance. A flaky rule that gets retried into green teaches everyone to ignore the gate.
5. **Never** conclude a task with "verification is failing but the change is fine" without stating the failing command and output in your final message. A silently skipped gate reads exactly like a passed one.

## Reporting

When the gate has run, state the result in these terms — command, result, and what it covers:

```
Verify: 3/3 green
  go build ./...                              ok    compiles
  go test ./internal/auth/...                 ok    token rotation, refresh-failure fallback
  npm run test -- src/login.test.ts           ok    login form validation
Manual (not run): <steps> — for <who>
```

Manual rules are never marked verified by you. Print their steps and name the human who owns them.
