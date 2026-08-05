---
name: kafbat-consumer-groups
description: >
  MANUAL INVOCATION ONLY — do NOT auto-trigger from conversation context. Only run this
  skill when the user explicitly types `/kafbat`, names the skill outright, or asks in so
  many words for a kafbat / Kafka-UI consumer-group inspection. Merely mentioning Kafka,
  a consumer, a topic, offsets, lag, or a broken consumer is NOT a trigger. What it does:
  read-only diagnosis of Kafka consumer groups through a kafbat (Kafka-UI) instance's REST
  API — lists groups, per-partition offsets and lag, distinguishes real backlog from
  phantom lag left by stale committed offsets, spots orphan EMPTY groups, and cross-checks
  live group state against the repo's own consumer config.
---

# kafbat consumer groups

Read the same data the kafbat UI shows — consumer groups, members, per-partition offsets
and lag — straight from its REST API, then reason over it instead of squinting at a table.

## Invocation

This skill is manual-only. If you arrived here without the user explicitly asking for a
kafbat inspection, stop and do not proceed. There is no ambient trigger.

## Read-only

**This skill never mutates Kafka state.** No offset resets, no group deletion, no topic
or config writes — not even when the diagnosis obviously calls for one.

When a fix requires a write, print the exact `curl` (or the exact kafbat UI click-path)
the user would run, explain the blast radius, and stop. The user runs it themselves. Do
not offer to run it for them.

## Configuration

Resolve the endpoint and credential in this order. Never ask the user to paste a cookie
into the transcript if a configured source already has one.

1. Environment: `KAFBAT_URL` and `KAFBAT_SESSION`.
2. `~/.config/devpilot/kafbat.json` — a local, untracked file:

   ```json
   {
     "profiles": {
       "nonprod": { "url": "https://kafbat.example.internal", "session": "<SESSION cookie>" },
       "prod":    { "url": "https://kafbat-prod.example.internal", "session": "<SESSION cookie>" }
     },
     "default": "nonprod"
   }
   ```

   `chmod 600` it. Pick the profile the user names, else `default`.
3. Ask the user for the base URL and the `SESSION` cookie value.

If nothing resolves, tell the user what to set and stop — do not guess a hostname.

### Credential hygiene

- Load the cookie into a shell variable and reference it as `-b "SESSION=$KAFBAT_SESSION"`.
  Never inline the literal value in a command, never put it in a URL query string, and
  never `echo` it back.
- Never write the cookie, the base URL, or a cluster name into any file inside the
  repository you are working in — including notes, reports, and commit messages. These
  are internal infrastructure identifiers.
- A `SESSION` cookie is a live authenticated session. Treat it like a password: it is
  valid for this task only, and it belongs in the config file above, nowhere else.

### Session expiry

An expired session does not always 401. If a response body is HTML (a login page) or a
redirect rather than JSON, the session is dead — say so and ask for a fresh cookie. Do
not retry in a loop.

## API

Verified against kafbat-ui on Kafka 3.9.0 (KRaft). Set `BASE` and `C` first:

```bash
BASE="$KAFBAT_URL"; AUTH=(-s -m 30 -b "SESSION=$KAFBAT_SESSION" -H 'Accept: application/json')

# 1. Discover clusters — always do this first; the cluster name is part of every path.
curl "${AUTH[@]}" "$BASE/api/clusters"

# 2. List groups (paged, searchable).
curl "${AUTH[@]}" "$BASE/api/clusters/$C/consumer-groups/paged?search=<substr>&perPage=200"

# 3. One group in full — includes the per-partition array.
curl "${AUTH[@]}" "$BASE/api/clusters/$C/consumer-groups/<groupId>"
```

Path gotcha: it is `consumer-groups` (plural, hyphenated). `consumergroups` and
`consumer-group` both 404 with a Spring `No static resource ...` error body. If any path
returns that message the path is wrong, not the data — probe a variant rather than
concluding the group does not exist.

Useful fields:

- group summary: `groupId`, `state`, `members`, `topics`, `consumerLag`, `partitionAssignor`,
  `coordinator.host`
- `partitions[]`: `topic`, `partition`, `currentOffset`, `endOffset`, `consumerLag`,
  `consumerId`

Tabulate with `jq -r '... | @tsv' | column -t -s$'\t'` — a raw JSON dump of 200 groups is
unreadable and burns context.

## Diagnosis

Work through these in order. Report only what the data supports.

### 1. Summary table

`groupId | state | members | topics | lag`, sorted with nonzero lag first. States worth
calling out: `EMPTY` (no members), `PREPARING_REBALANCE` / `COMPLETING_REBALANCE` (mid
rebalance — a lag reading taken here is a snapshot, say so), `DEAD`.

### 2. Phantom lag vs real backlog

**A nonzero group `consumerLag` is not automatically a backlog.** kafbat sums lag across
every `(topic, partition)` the group still holds a committed offset for — including topics
the consumer no longer subscribes to. Those offsets stay in `__consumer_offsets` after a
config change until they expire.

Tell them apart in `partitions[]`:

- lag on a partition with an **empty/absent `consumerId`** and on a topic that is **not in
  the current subscription** → phantom. Stale committed offset from an earlier config.
  The consumer is not behind; the panel is counting history.
- lag on a partition **assigned to a live `consumerId`** on a currently-subscribed topic
  → real backlog. Compare `endOffset - currentOffset` per partition, and check whether it
  is concentrated on one partition (hot key / stuck record) or spread evenly (throughput).

A `STABLE` group with 3 members and a four-figure `consumerLag` entirely on unsubscribed
topics is healthy. Say that plainly instead of raising an incident.

### 3. Orphan groups

`state: EMPTY`, zero members, and no code that references the group id → a group left
behind by a removed consumer. Its lag is meaningless. Confirm the absence in code (step 4)
before calling it an orphan; a scaled-to-zero deployment looks identical from Kafka's side.

### 4. Cross-check against the repo

This is the step that makes the skill better than reading the UI. In the current repo,
find the consumer configuration — group ids and their topic lists — and reconcile:

- Search config (`config*/`, `*.yaml`, helm `values.yaml`) and wiring code for `group_id`
  / `groupID` / `ConsumerGroup` and the topic lists next to them.
- **Group in Kafka but not in code** → orphan, or renamed group (look for a near-miss id;
  a rename silently starts from the configured offset reset policy).
- **Group in code but not in Kafka** → never started, or a feed that is intentionally not
  enabled. Check for a comment or a flag saying so before flagging it as broken. An absent
  group is also how a *misspelled topic name* presents.
- **Group's Kafka topic set wider than its configured topic list** → the extra topics are
  the stale-offset source from step 2.
- Note the offset-reset policy in code (`earliest` vs `latest`), because it decides what a
  reset or a rename would actually replay.

Read the config; do not infer it from the group name.

### 5. Report

Short prose, not a JSON dump:

1. one-line verdict — healthy, or the specific problem;
2. the summary table;
3. per finding: what the data shows, the code/config line that confirms or contradicts it
   (`path:line`), and what it means;
4. suggested writes, if any, as commands for the user to run — never executed here.

Distinguish what you verified from what you inferred. If a group's meaning depends on repo
context you could not find, say the cross-check was inconclusive rather than guessing.
