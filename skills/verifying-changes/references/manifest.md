# `.devpilot/verify.json` — schema

Lives at the root of the worked-on repo. Checked in: the whole point is that the next agent and the next human inherit the same definition of "still works". JSON rather than YAML so `scripts/verify_plan.py` reads it with the standard library on any Python 3.

```json
{
  "version": 1,
  "gate": "block",
  "timeout": 600,
  "always": [
    { "run": "go build ./...", "why": "the tree compiles" }
  ],
  "rules": [
    {
      "match": ["internal/auth/**", "cmd/api/auth_*.go"],
      "run": ["go test ./internal/auth/..."],
      "why": "token rotation, refresh-failure fallback, and the login handler contract"
    },
    {
      "match": ["web/src/**"],
      "run": [
        { "run": "npm run typecheck", "why": "props and API types line up", "timeout": 120 },
        { "run": "npm run test -- src/login.test.ts", "why": "login form validation" }
      ],
      "why": "frontend behavior"
    }
  ],
  "manual": [
    {
      "match": ["web/src/checkout/**"],
      "steps": "Load /checkout with a saved card, submit, confirm the receipt page shows the last 4 digits.",
      "who": "siyu"
    }
  ]
}
```

## Fields

| Field | Required | Meaning |
|---|---|---|
| `version` | yes | `1`. Anything else is rejected rather than guessed at. |
| `gate` | no | `"block"` (default) — a failure blocks the agent from finishing. `"warn"` — reported only. Start at `block`; `warn` is for a rule set you don't yet trust. |
| `timeout` | no | Default per-command timeout in seconds (600). Override per command. A command that hits the timeout counts as failed. |
| `always` | no | Commands that run whenever **any** rule matched. Cheap whole-tree checks belong here: build, typecheck, lint. Skipped entirely when nothing matched, so a docs-only edit doesn't trigger a build. |
| `rules` | yes | The map. Each needs `match` (non-empty glob list) and `run`. |
| `manual` | no | Things a human must check. Never run, never marked verified by the agent — printed with the named owner. |

`run` accepts either a plain string list (`["go test ./..."]`) or objects with `run` / `why` / `timeout`. Use objects when the commands inside one rule cover different behaviors and each deserves its own `why`.

Commands run through `bash -c` from the repo root. Duplicates across rules are deduplicated by command string, keeping the first `why`.

## Glob semantics

Paths are repo-root-relative, forward-slashed, exactly as `git diff --name-only` prints them.

| Pattern | Matches |
|---|---|
| `internal/auth/**` | everything under `internal/auth/`, at any depth |
| `internal/auth/` | same — a trailing slash implies `**` |
| `**/*_test.go` | any `_test.go` file at any depth |
| `cmd/api/*.go` | `.go` files directly in `cmd/api/`, **not** in subdirectories |
| `a/**/b` | `a/b`, `a/x/b`, `a/x/y/b` — `**/` matches zero or more directories |
| `**` | everything (avoid as a rule of its own; see below) |

`*` and `?` stop at `/`; `**` crosses it. Character classes (`[ch]`, `[!x]`) work.

## Writing rules that hold up

**Scope for speed.** The gate runs after every change. If the common edit triggers a five-minute suite, the gate gets disabled and the guarantee evaporates. Target: under ~90 seconds for a typical change. Split by package, surface, or service rather than writing one catch-all.

**One `**` rule is an anti-pattern** — it makes every change run everything and destroys the "which feature does this cover" information the file exists to hold. The legitimate use of `**` is a very cheap check in `always` (a build or lint), not a full suite in `rules`.

**Every rule's command must actually fail when the covered behavior breaks.** The test: mentally (or actually) break the feature and ask whether the command goes red. `go build ./...` as the only rule for an auth package passes happily while auth is completely broken.

**`why` is written in behavior terms.** "token rotation, refresh-failure fallback" tells the next reader what is protected. "runs the auth tests" tells them nothing they couldn't read from the command.

**Prefer the narrowest command that covers the rule.** `go test ./internal/auth/...` over `go test ./...`; `npm run test -- src/login.test.ts` over `npm test`. The whole-suite run belongs to CI, which has time the inner loop does not.

**Commands must be non-interactive and hermetic.** Anything that prompts will hang the hook. Anything needing credentials the environment lacks belongs in `manual` (or in CI), not in `rules` where it will fail for the wrong reason.

**Do not put `git commit`, `git push`, deploys, or anything that mutates state outside the working tree into a rule.** The gate runs unattended, repeatedly.

## Interaction with the green cache

After a green run, `scripts/verify.sh` stores a fingerprint of the change set (HEAD, tracked diff, untracked file contents, and the manifest itself) in `.git/devpilot/verify-green`. The next run with an identical fingerprint is skipped. Editing the manifest changes the fingerprint, so a rule change always re-runs. The marker lives inside `.git/`, so it never dirties `git status` and never gets committed.

## Turning it off

For the user, not for the agent: `DEVPILOT_VERIFY=off` in the environment, or an empty `.devpilot/verify.off` file in the repo. Both make every mode a no-op. An agent that hits a failing gate fixes the code or fixes the rule — it does not reach for these.
