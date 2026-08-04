#!/usr/bin/env python3
"""devpilot-verify-planner — resolve a change set against .devpilot/verify.json.

Reads the manifest and a newline-separated list of changed paths on stdin (or
--files), and prints one JSON object describing what must run:

  {"status":"ok","gate":"block","timeout":600,
   "commands":[{"run":"go test ./internal/auth/...","why":"token rotation","from":"rules[0]"}],
   "manual":[{"steps":"...","who":"...","from":"manual[0]"}],
   "unmatched":["docs/foo.md"],"matched_rules":2}

Statuses: ok | no_manifest | bad_manifest | nothing_to_do.
Never runs anything; scripts/verify.sh executes what this returns. Stdlib only —
the manifest is JSON precisely so this needs no PyYAML on a stock Python.
"""
import argparse
import json
import pathlib
import re
import sys

MANIFEST_REL = ".devpilot/verify.json"


def glob_to_regex(pattern):
    """Translate a path glob to a regex.

    `**` matches across separators, `*` and `?` do not. A bare directory prefix
    (`internal/auth/`) matches everything beneath it, because that is what
    someone writing it means.
    """
    if pattern.endswith("/"):
        pattern += "**"
    out = ["(?s:"]
    i = 0
    while i < len(pattern):
        c = pattern[i]
        if pattern.startswith("**", i):
            out.append(".*")
            i += 2
            # `**/` should also match zero directories: a/**/b matches a/b.
            if pattern.startswith("/", i):
                out[-1] = "(?:.*/)?"
                i += 1
            continue
        if c == "*":
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        elif c == "[":
            j = pattern.find("]", i)
            if j == -1:
                out.append(re.escape(c))
            else:
                body = pattern[i + 1:j].replace("\\", "\\\\")
                if body.startswith("!"):
                    body = "^" + body[1:]
                out.append("[" + body + "]")
                i = j + 1
                continue
        else:
            out.append(re.escape(c))
        i += 1
    out.append(")\\Z")
    return re.compile("".join(out))


def matches(patterns, paths):
    """Return the subset of paths matched by any pattern."""
    regexes = [glob_to_regex(p) for p in patterns]
    return [p for p in paths if any(r.match(p) for r in regexes)]


def as_command_list(value, default_why, origin):
    """Accept either ["cmd", ...] or [{"run":"cmd","why":"..."}, ...]."""
    cmds = []
    for idx, item in enumerate(value or []):
        if isinstance(item, str):
            cmds.append({"run": item, "why": default_why, "from": origin})
        elif isinstance(item, dict) and isinstance(item.get("run"), str):
            cmds.append({
                "run": item["run"],
                "why": item.get("why") or default_why,
                "from": origin,
                **({"timeout": item["timeout"]} if isinstance(item.get("timeout"), int) else {}),
            })
        else:
            raise ValueError(f"{origin}: each entry must be a string or an object with a 'run' string")
    return cmds


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=".")
    ap.add_argument("--files", help="path to a file holding changed paths, one per line; default stdin")
    ap.add_argument("--all", action="store_true", help="ignore the change set; return every command")
    args = ap.parse_args()

    root = pathlib.Path(args.repo).resolve()
    manifest_path = root / MANIFEST_REL
    if not manifest_path.is_file():
        print(json.dumps({"status": "no_manifest", "path": MANIFEST_REL}))
        return 0

    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if not isinstance(manifest, dict):
            raise ValueError("top level must be an object")
        if manifest.get("version") != 1:
            raise ValueError(f"unsupported version {manifest.get('version')!r}; expected 1")
        gate = manifest.get("gate", "block")
        if gate not in ("block", "warn"):
            raise ValueError(f"gate must be \"block\" or \"warn\", got {gate!r}")
    except (ValueError, OSError) as e:
        print(json.dumps({"status": "bad_manifest", "path": MANIFEST_REL, "error": str(e)}))
        return 0

    if args.files:
        raw = pathlib.Path(args.files).read_text(encoding="utf-8")
    else:
        raw = "" if sys.stdin.isatty() else sys.stdin.read()
    paths = sorted({line.strip() for line in raw.splitlines() if line.strip()})

    commands, manual, matched_rules, unmatched = [], [], 0, list(paths)
    try:
        for idx, rule in enumerate(manifest.get("rules") or []):
            origin = f"rules[{idx}]"
            if not isinstance(rule, dict):
                raise ValueError(f"{origin}: must be an object")
            patterns = rule.get("match")
            if not isinstance(patterns, list) or not patterns:
                raise ValueError(f"{origin}: 'match' must be a non-empty list of globs")
            hits = paths if args.all else matches(patterns, paths)
            if not hits:
                continue
            matched_rules += 1
            unmatched = [p for p in unmatched if p not in set(hits)]
            commands.extend(as_command_list(rule.get("run"), rule.get("why", ""), origin))

        for idx, item in enumerate(manifest.get("manual") or []):
            origin = f"manual[{idx}]"
            patterns = item.get("match") if isinstance(item, dict) else None
            if not isinstance(patterns, list) or not patterns:
                raise ValueError(f"{origin}: 'match' must be a non-empty list of globs")
            if args.all or matches(patterns, paths):
                manual.append({
                    "steps": item.get("steps", ""),
                    "who": item.get("who", "the user"),
                    "from": origin,
                })

        # `always` runs only when something else did, so a docs-only edit does
        # not trigger a full build.
        if commands or args.all:
            commands = as_command_list(manifest.get("always"), "always", "always") + commands
    except ValueError as e:
        print(json.dumps({"status": "bad_manifest", "path": MANIFEST_REL, "error": str(e)}))
        return 0

    # Dedupe by command string, keeping first occurrence and its reason.
    seen, deduped = set(), []
    for c in commands:
        if c["run"] in seen:
            continue
        seen.add(c["run"])
        deduped.append(c)

    payload = {
        "status": "ok" if (deduped or manual) else "nothing_to_do",
        "gate": gate,
        "timeout": manifest.get("timeout", 600),
        "commands": deduped,
        "manual": manual,
        "matched_rules": matched_rules,
        "changed": len(paths),
        "unmatched": unmatched,
    }
    print(json.dumps(payload))
    return 0


if __name__ == "__main__":
    sys.exit(main())
