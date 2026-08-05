---
description: Read-only diagnosis of Kafka consumer groups via a kafbat (Kafka-UI) REST API
---

Invoke the `devpilot:kafbat-consumer-groups` skill with these arguments: $ARGUMENTS

Follow that skill's instructions end-to-end, including its read-only rule — inspect and
report, never reset offsets or delete groups.

$ARGUMENTS may name a profile from `~/.config/devpilot/kafbat.json`, a search substring to
filter group ids, or a specific group id. If it is empty, resolve the default profile and
report on every consumer group whose id relates to the current repository, as the skill's
cross-check step directs.
