#!/usr/bin/env python3
"""Repo validation: plugin manifests, skill/agent/command frontmatter, cross-references, README drift.

Run from the repo root: python3 scripts/validate.py
Requires: PyYAML.
"""
import json
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
errors = []


def err(msg):
    errors.append(msg)


def frontmatter(path):
    text = path.read_text(encoding="utf-8")
    m = re.match(r"\A---\n(.*?)\n---\n", text, re.DOTALL)
    if not m:
        err(f"{path.relative_to(ROOT)}: missing YAML frontmatter block")
        return None, text
    try:
        data = yaml.safe_load(m.group(1))
    except yaml.YAMLError as e:
        err(f"{path.relative_to(ROOT)}: frontmatter is not valid YAML: {e}")
        return None, text
    if not isinstance(data, dict):
        err(f"{path.relative_to(ROOT)}: frontmatter is not a mapping")
        return None, text
    return data, text


# --- plugin manifests ---
for name in (".claude-plugin/plugin.json", ".claude-plugin/marketplace.json"):
    p = ROOT / name
    try:
        json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        err(f"{name}: {e}")

# --- skills ---
skill_dirs = sorted(d for d in (ROOT / "skills").iterdir() if d.is_dir())
skill_names = set()
for d in skill_dirs:
    sk = d / "SKILL.md"
    if not sk.is_file():
        err(f"skills/{d.name}: missing SKILL.md")
        continue
    data, _ = frontmatter(sk)
    if data is None:
        continue
    name = data.get("name")
    if name != d.name:
        err(f"skills/{d.name}/SKILL.md: frontmatter name {name!r} != directory name {d.name!r}")
    if not str(data.get("description") or "").strip():
        err(f"skills/{d.name}/SKILL.md: empty or missing description")
    skill_names.add(d.name)

# --- agents ---
agents_dir = ROOT / "agents"
if agents_dir.is_dir():
    for f in sorted(agents_dir.glob("*.md")):
        data, _ = frontmatter(f)
        if data is None:
            continue
        if data.get("name") != f.stem:
            err(f"agents/{f.name}: frontmatter name {data.get('name')!r} != file stem {f.stem!r}")
        if not str(data.get("description") or "").strip():
            err(f"agents/{f.name}: empty or missing description")

# --- commands ---
commands_dir = ROOT / "commands"
if commands_dir.is_dir():
    for f in sorted(commands_dir.glob("*.md")):
        data, text = frontmatter(f)
        if data is not None and not str(data.get("description") or "").strip():
            err(f"commands/{f.name}: empty or missing description")
        for ref in re.findall(r"devpilot:([a-z0-9-]+)", text or ""):
            if ref not in skill_names:
                err(f"commands/{f.name}: references non-existent skill devpilot:{ref}")

# --- cross-references in skills/agents ---
for f in list((ROOT / "skills").rglob("*.md")) + list(agents_dir.glob("*.md")):
    rel = f.relative_to(ROOT)
    text = f.read_text(encoding="utf-8")
    for ref in set(re.findall(r"devpilot:([a-z0-9-]+)", text)):
        if ref.startswith("pr-review-"):  # plugin agent refs, checked below
            if not (agents_dir / f"{ref}.md").is_file():
                err(f"{rel}: references non-existent agent devpilot:{ref}")
        elif ref not in skill_names:
            err(f"{rel}: references non-existent skill devpilot:{ref}")
    # residual old-style prefix (devpilot-<skill> as a skill reference).
    # Allowed: the repo/CLI names "devpilot-plugin", "devpilot-marketplace", plain "devpilot".
    for hit in re.findall(r"devpilot-[a-z0-9-]+", text):
        if hit in ("devpilot-plugin", "devpilot-marketplace"):
            continue
        suffix = hit[len("devpilot-"):]
        if suffix in skill_names:
            err(f"{rel}: residual old-style skill reference {hit!r}; use devpilot:{suffix}")

# --- README drift ---
readme = (ROOT / "README.md").read_text(encoding="utf-8")
for s in sorted(skill_names):
    if f"devpilot:{s}" not in readme:
        err(f"README.md: skill table is missing devpilot:{s}")

if errors:
    print(f"FAIL — {len(errors)} problem(s):")
    for e in errors:
        print(f"  - {e}")
    sys.exit(1)
print(f"OK — {len(skill_names)} skills, manifests, agents, commands, cross-refs, README all validated.")
