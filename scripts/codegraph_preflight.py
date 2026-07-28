#!/usr/bin/env python3
"""codegraph_preflight.py — synthesize pr-review's graph payload from a CodeGraph index.

CodeGraph (github.com/colbymchenry/codegraph) indexes a repo into
`.codegraph/codegraph.db` and exposes per-symbol primitives (`query`, `callers`,
`callees`, `impact`, `affected`). pr-review does not want primitives: it wants
one diff-shaped risk envelope, computed once, injected into every fanout brief.
This script is that missing layer. It reads the SQLite index directly (one pass,
no per-symbol subprocess fanout) plus `git diff`, and prints the envelope
`skills/pr-review/references/graph.md` documents.

Subcommands (each prints ONE line of JSON on stdout):

    preflight --repo DIR --base SHA --head SHA
    context   --repo DIR --id 'path/to/file.go::Symbol' [--depth 1]
    impact    --repo DIR --files a.go,b.ts

Envelope: {"ok":true,"data":{...}} / {"ok":false,"error":{"code","message"}}.
Always exit 0 with a parseable envelope unless the arguments themselves are
unusable — callers branch on `ok` and `data.mode`, never on the exit code.

Two design rules worth keeping:

  1. NEVER SILENTLY ASSERT "no callers". CodeGraph resolves references
     best-effort; a Go call across packages with no go.mod, or any dynamic
     dispatch, lands in `unresolved_refs` instead of `edges`. A reviewer who
     reads `callers.count: 0` as "dead code" is then wrong because of us. So
     every symbol carries `callers.unresolved_candidates` (failed references
     whose name tail matches) and `callers.confident`, and an unresolved hit
     adds the `unresolved_callers` risk factor.
  2. FAIL LOUDLY ON SCHEMA DRIFT. CodeGraph ships fast. Column and table names
     are asserted up front; a mismatch returns mode:"fallback" with the reason,
     so the review degrades to grep instead of quoting invented facts.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys

# --- what the index must contain for the queries below to mean anything ------
MIN_SCHEMA_VERSION = 8
REQUIRED = {
    "nodes": {"id", "kind", "name", "qualified_name", "file_path", "language",
              "start_line", "end_line", "is_exported", "signature", "is_abstract"},
    "edges": {"source", "target", "kind", "line"},
    "files": {"path", "content_hash", "language"},
    "unresolved_refs": {"name_tail", "reference_kind", "status", "file_path", "line"},
}

# `contains` is structural (file→symbol, class→method) and `imports` is
# file-level; neither is a caller. Everything else — calls, references,
# implements, extends, and any kind CodeGraph adds later — counts as an inbound
# dependency. Chosen deliberately as a denylist: a new edge kind should
# over-report a caller, never invent a dead symbol.
NON_DEP_EDGE_KINDS = ("contains", "imports", "defines", "declares")

# Nodes that are not reviewable symbols.
NON_SYMBOL_KINDS = {"file", "import", "module", "package", "comment"}

# Kinds that carry behavior, and so can meaningfully be "public and untested".
# A changed module-level constant is still reported as a changed symbol, but
# demanding a test for it turns `untested_public_changes` into a file count:
# on a real repo the first version of this script scored 42 untested publics on
# a 45-symbol diff, most of them Python constants and regexes.
BEHAVIOR_KINDS = {"function", "method", "class", "struct", "interface", "trait",
                  "enum", "route", "constructor", "component", "hook"}

# Cross-language resolution is name-shaped and produces confident nonsense: on a
# mixed Go/Python repo, CodeGraph bound Python `.get(...)` call sites to a Go
# method named `get`, yielding "python/extract_pdf.py calls internal/trello".
# Only trust an edge whose endpoints share a language family. Families exist
# because some cross-language edges are real (a .tsx importing a .ts, Swift
# calling Objective-C), while go↔python edges never are.
LANG_FAMILY = {
    "typescript": "js", "tsx": "js", "javascript": "js", "jsx": "js",
    "swift": "apple", "objc": "apple", "objective-c": "apple",
    "c": "c", "cpp": "c", "c++": "c", "cuda": "c",
    "java": "jvm", "kotlin": "jvm", "scala": "jvm",
}

INTERFACE_KINDS = {"interface", "protocol", "trait"}

# CodeGraph sets `is_exported` from syntax, so it is only meaningful where the
# language marks visibility syntactically (Go's capital, `export`, `pub`, an
# access modifier). In these languages every symbol comes back is_exported=0,
# which would silently switch off the `untested_public` risk factor for whole
# ecosystems — so fall back to the leading-underscore convention there.
CONVENTION_VISIBILITY_LANGS = {"python", "ruby", "lua", "r", "perl", "elixir",
                               "shell", "bash", "julia"}

HUB_MIN_CALLERS = 8

TEST_PATH = re.compile(
    r"(_test\.(go|py|rs|dart|exs?)$"
    r"|(^|/)test_[^/]+\.(py|rs)$"
    r"|\.(test|spec)\.[cm]?[jt]sx?$"
    r"|_spec\.rb$|_test\.rb$"
    r"|Tests?\.(java|kt|cs|swift)$"
    r"|(^|/)(tests?|spec|specs|__tests__|testing)/)",
    re.IGNORECASE,
)

HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def out(payload: dict) -> None:
    print(json.dumps(payload, separators=(",", ":")))
    sys.exit(0)


def fail(code: str, message: str, mode_fallback: bool = True) -> None:
    """Emit a parseable failure. `mode:"fallback"` is what makes pr-review take
    the grep path and quote the reason, rather than trusting a partial graph."""
    payload = {"ok": False, "error": {"code": code, "message": message}}
    if mode_fallback:
        payload["data"] = {"mode": "fallback", "reason": f"{code}: {message}"}
    out(payload)


# --- git ---------------------------------------------------------------------
def git(repo: str, *args: str) -> str:
    proc = subprocess.run(
        ["git", "-C", repo, *args],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout).strip().splitlines()[0:1] or ["git failed"])
    return proc.stdout


def changed_files(repo: str, base: str, head: str) -> tuple[dict, list]:
    """{path: status} on the head side, plus the deleted paths.

    Rename-aware: a rename reports the new path, so the symbols we look up are
    the ones the index actually holds.
    """
    raw = git(repo, "diff", "--name-status", "--find-renames", "--no-color", f"{base}", f"{head}")
    status, deleted = {}, []
    for line in raw.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        code, paths = parts[0], parts[1:]
        path = paths[-1]  # new path for R/C, the only path otherwise
        if code.startswith("D"):
            deleted.append(path)
        elif code.startswith("R") or code.startswith("C"):
            status[path] = "renamed"
        elif code.startswith("A"):
            status[path] = "added"
        else:
            status[path] = "modified"
    return status, deleted


def changed_ranges(repo: str, base: str, head: str, path: str) -> list[tuple[int, int]]:
    """Head-side line ranges touched by the diff. `-U0` so context lines don't
    inflate a one-line change into a whole neighbouring function."""
    try:
        raw = git(repo, "diff", "-U0", "--no-color", base, head, "--", path)
    except RuntimeError:
        return []
    ranges = []
    for line in raw.splitlines():
        m = HUNK.match(line)
        if not m:
            continue
        start = int(m.group(1))
        count = 1 if m.group(2) is None else int(m.group(2))
        if count == 0:
            # Pure deletion: nothing exists at head. Keep a zero-width marker so
            # a symbol that lost lines still reads as modified.
            ranges.append((start, start))
        else:
            ranges.append((start, start + count - 1))
    return ranges


def blob(repo: str, rev: str, path: str) -> bytes | None:
    proc = subprocess.run(["git", "-C", repo, "show", f"{rev}:{path}"],
                          capture_output=True)
    return None if proc.returncode != 0 else proc.stdout


def blob_sha256(repo: str, rev: str, path: str) -> str | None:
    content = blob(repo, rev, path)
    return None if content is None else hashlib.sha256(content).hexdigest()


def names_at_base(repo: str, base: str, path: str) -> set | None:
    """Identifiers present in the file at `base`, for added-vs-modified.

    Line ranges cannot answer this: rewriting the one line of a one-line
    function makes its whole span "added" and the symbol reads as new. Asking
    whether the name existed at base is coarse (a moved symbol reads as
    modified) but never invents a new public API where there was one before —
    the direction of error a reviewer can live with.
    """
    content = blob(repo, base, path)
    if content is None:
        return None
    return set(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", content.decode("utf-8", "replace")))


# --- index -------------------------------------------------------------------
def open_index(repo: str, db_path: str | None) -> sqlite3.Connection:
    path = db_path or os.path.join(repo, os.environ.get("CODEGRAPH_DIR", ".codegraph"),
                                   "codegraph.db")
    if not os.path.exists(path):
        fail("index_missing", f"no CodeGraph index at {path}; run codegraph.sh ensure first")
    # Read-only, immutable=0: a watcher may be mid-write; WAL readers are fine.
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    assert_schema(conn)
    return conn


def assert_schema(conn: sqlite3.Connection) -> None:
    try:
        version = conn.execute("select max(version) from schema_versions").fetchone()[0] or 0
    except sqlite3.Error as exc:
        fail("schema_unreadable", f"cannot read schema_versions: {exc}")
    if version < MIN_SCHEMA_VERSION:
        fail("schema_too_old",
             f"index schema v{version} < required v{MIN_SCHEMA_VERSION}; "
             "re-index with a current codegraph (codegraph index --force)")
    for table, columns in REQUIRED.items():
        try:
            have = {r["name"] for r in conn.execute(f"pragma table_info({table})")}
        except sqlite3.Error as exc:
            fail("schema_drift", f"table {table} unreadable: {exc}")
        missing = columns - have
        if missing:
            fail("schema_drift",
                 f"table {table} is missing {sorted(missing)} — CodeGraph changed its "
                 "schema; update scripts/codegraph_preflight.py before trusting it")


def dep_edge_filter(alias: str = "e") -> str:
    placeholders = ",".join("?" for _ in NON_DEP_EDGE_KINDS)
    return f"{alias}.kind not in ({placeholders})"


def community_of(path: str) -> str:
    d = os.path.dirname(path)
    return d or "."


def load_indegrees(conn: sqlite3.Connection) -> tuple[dict, int]:
    """In-degree per node over same-family dependency edges, plus how many
    cross-language edges were discarded (reported in the payload so a reviewer
    can see the graph was filtered rather than wonder why a count is low)."""
    rows = conn.execute(
        f"select e.target as target, s.language as src_lang, t.language as tgt_lang,"
        f"       count(*) as n"
        f"  from edges e"
        f"  join nodes s on s.id = e.source"
        f"  join nodes t on t.id = e.target"
        f" where {dep_edge_filter()}"
        f" group by e.target, s.language, t.language",
        NON_DEP_EDGE_KINDS,
    )
    degrees: dict = {}
    dropped = 0
    for r in rows:
        if same_family(r["src_lang"], r["tgt_lang"]):
            degrees[r["target"]] = degrees.get(r["target"], 0) + r["n"]
        else:
            dropped += r["n"]
    return degrees, dropped


def caller_caveats(node, callers: list, name_counts: dict, unresolved: list) -> list:
    """Why this symbol's caller set may not be the truth.

    CodeGraph binds references by name when it cannot bind them structurally,
    and it does not type-check receivers. Two failure modes, both observed on a
    real Go repo:

      * `internal/graph/store/store.go::Close` (a method, one definition in the
        tree) collected 93 callers — every `.Close()` on any type anywhere.
      * a method `Error` defined in a _test.go collected 103 — every
        `t.Error(...)` and `err.Error()`.

    Neither is detectable from the count alone, so grade instead of dropping:
    dropping would manufacture the false "dead code" this whole payload exists
    to prevent. An empty caveat list means the count is a fact; a non-empty one
    means it is an upper bound and the reviewer must read the code.
    """
    caveats = []
    # A duplicated name can only steal callers from somewhere else in the tree.
    # When every caller sits in the definition's own file the binding is local
    # and safe — flagging it would mark most private helpers unreliable and train
    # the reviewer to ignore the flag.
    if name_counts.get(node["name"], 0) > 1 and \
            any(c["file_path"] != node["file_path"] for c in callers):
        caveats.append("ambiguous_name")
    if node["kind"] == "method":
        home = community_of(node["file_path"])
        if any(community_of(c["file_path"]) != home for c in callers):
            # Bare-method-name binding across a package boundary is the
            # receiver-typing gap. Same-package callers stay trustworthy.
            caveats.append("cross_community_method_binding")
    if unresolved:
        caveats.append("unresolved_call_sites")
    return caveats


def load_name_counts(conn: sqlite3.Connection) -> dict:
    """How many definitions share each bare symbol name."""
    rows = conn.execute(
        "select name, count(*) as n from nodes"
        f" where kind not in ({','.join('?' for _ in NON_SYMBOL_KINDS)})"
        " group by name", tuple(NON_SYMBOL_KINDS))
    return {r["name"]: r["n"] for r in rows}


def hub_threshold(indegrees: dict) -> int:
    """A hub is judged relative to this repo, not an absolute number: a 400-file
    service and a 40-file library have different "everyone calls this" shapes.
    p95 of the nonzero in-degrees, floored at HUB_MIN_CALLERS."""
    values = sorted(v for v in indegrees.values() if v > 0)
    if not values:
        return HUB_MIN_CALLERS
    p95 = values[min(len(values) - 1, int(len(values) * 0.95))]
    return max(HUB_MIN_CALLERS, p95)


def symbols_in_file(conn: sqlite3.Connection, path: str) -> list:
    return list(conn.execute(
        "select id, kind, name, qualified_name, file_path, language, start_line, end_line,"
        "       is_exported, signature, is_abstract"
        "  from nodes where file_path = ? order by start_line",
        (path,),
    ))


def family(language: str) -> str:
    return LANG_FAMILY.get(language, language)


def same_family(a: str, b: str) -> bool:
    return family(a) == family(b)


def inbound(conn: sqlite3.Connection, node_id: str, language: str,
            limit: int = 25) -> list:
    rows = conn.execute(
        f"select n.name, n.kind, n.file_path, n.start_line, n.language,"
        f"       e.kind as edge_kind"
        f"  from edges e join nodes n on n.id = e.source"
        f" where e.target = ? and {dep_edge_filter()}"
        f" order by n.file_path, n.start_line",
        (node_id, *NON_DEP_EDGE_KINDS),
    )
    kept = [r for r in rows if same_family(r["language"], language)]
    return kept[:limit]


def outbound(conn: sqlite3.Connection, node_id: str, language: str,
             limit: int = 25) -> list:
    rows = conn.execute(
        f"select n.name, n.kind, n.file_path, n.start_line, n.language,"
        f"       e.kind as edge_kind"
        f"  from edges e join nodes n on n.id = e.target"
        f" where e.source = ? and {dep_edge_filter()}"
        f" order by n.file_path, n.start_line",
        (node_id, *NON_DEP_EDGE_KINDS),
    )
    kept = [r for r in rows if same_family(r["language"], language)]
    return kept[:limit]


def unresolved_for(conn: sqlite3.Connection, name: str, limit: int = 5) -> list:
    """Failed references whose last name segment matches this symbol. These are
    the call sites CodeGraph saw but could not bind — the antidote to a false
    "zero callers"."""
    return list(conn.execute(
        "select file_path, line, reference_name from unresolved_refs"
        " where name_tail = ? and status != 'resolved' limit ?",
        (name, limit + 1),
    ))


def ref(row) -> str:
    return f"{row['file_path']}::{row['name']}"


def is_public(node) -> bool:
    if node["is_exported"]:
        return True
    if node["language"] in CONVENTION_VISIBILITY_LANGS:
        return not node["name"].startswith("_")
    return False


def overlaps(ranges: list, start: int, end: int) -> bool:
    return any(not (r_end < start or r_start > end) for r_start, r_end in ranges)


# --- preflight ---------------------------------------------------------------
def cmd_preflight(args) -> None:
    repo = os.path.abspath(args.repo)
    try:
        base = git(repo, "rev-parse", args.base).strip()
        head = git(repo, "rev-parse", args.head).strip()
    except RuntimeError as exc:
        fail("bad_revision", f"cannot resolve --base/--head in {repo}: {exc}")

    try:
        status, deleted = changed_files(repo, base, head)
    except RuntimeError as exc:
        fail("diff_failed", f"git diff {base}..{head} failed: {exc}")

    if not status and not deleted:
        out({"ok": True, "data": {"mode": "built", "reason": "empty diff",
                                  "changed_symbols": [], "cross_community_edges": [],
                                  "risk_summary": empty_summary()}})

    conn = open_index(repo, args.db)
    indexed = {r["path"]: r["language"] for r in conn.execute("select path, language from files")}
    known = [p for p in status if p in indexed]
    unindexed = sorted(p for p in status if p not in indexed)

    if not known:
        fail("no_indexed_changed_files",
             "none of the changed files are in the CodeGraph index "
             f"({len(unindexed)} unindexed: {', '.join(unindexed[:5])}"
             f"{'…' if len(unindexed) > 5 else ''})")

    indegrees, cross_lang_dropped = load_indegrees(conn)
    threshold = hub_threshold(indegrees)
    name_counts = load_name_counts(conn)

    # Freshness, per file and exactly: the index stores sha256 of file bytes, so
    # compare it against the blob at `head`. A mismatch means the index does not
    # describe the revision under review, and every line number below is suspect.
    stale = []
    for path in known:
        want = blob_sha256(repo, head, path)
        row = conn.execute("select content_hash from files where path = ?", (path,)).fetchone()
        if want is None or row is None or row["content_hash"] != want:
            stale.append(path)

    if stale:
        # Fail closed. Every line number, caller edge, and risk factor below is
        # derived from the indexed copy of these files; if that copy is not the
        # revision under review, the payload is confidently wrong — worse than
        # absent. `mode != "built"` is pr-review's documented signal to take the
        # grep path, and re-running `codegraph.sh ensure` fixes it.
        fail("index_stale",
             f"{len(stale)} changed file(s) differ between the index and {head[:12]}: "
             f"{', '.join(stale[:5])}{'…' if len(stale) > 5 else ''} — "
             "run codegraph.sh ensure, or check out the head commit before reviewing")

    changed_symbols = []
    edge_rows = []
    for path in known:
        ranges = changed_ranges(repo, base, head, path)
        file_added = status[path] == "added"
        if not ranges and not file_added:
            continue
        base_names = None if file_added else names_at_base(repo, base, path)
        for node in symbols_in_file(conn, path):
            kind = node["kind"]
            if kind in NON_SYMBOL_KINDS:
                continue
            start, end = node["start_line"], node["end_line"]
            if not file_added and not overlaps(ranges, start, end):
                continue
            is_new = file_added or (base_names is not None and node["name"] not in base_names)
            changed_symbols.append(
                describe(conn, node, indegrees, threshold,
                         "added" if is_new else "modified", name_counts)
            )
        # Whole-file entry for a newly added file, matching the payload contract:
        # reviewers are told these carry no callers BY CONSTRUCTION.
        if file_added:
            changed_symbols.append({
                "id": path, "kind": "file", "is_exported": False, "change_type": "added",
                "language": indexed[path], "community": community_of(path),
                "callers": {"count": 0, "same_community": 0, "in_hub": False,
                            "sample": None, "unresolved_candidates": 0,
                            "caveats": None, "name_definitions": 1,
                            "confident": True},
                "tests": {"has_tests": False, "test_symbols": None},
                "risk_factors": None,
            })
        edge_rows.extend(new_cross_edges(conn, path, ranges or [(1, 10**9)]))

    summary = summarize(changed_symbols, edge_rows)
    data = {
        "mode": "built",
        "backend": "codegraph",
        "graph": {
            "freshness": {
                "covers_head_sha": not stale,
                "head_sha": head,
                "base_sha": base,
                "stale_files": len(stale),
                "stale_file_samples": stale[:5] or None,
            },
            "indexed_files": len(indexed),
            "hub_threshold": threshold,
            "unindexed_changed_files": unindexed or None,
            "deleted_files": deleted or None,
            "cross_language_edges_ignored": cross_lang_dropped,
        },
        "changed_symbols": changed_symbols,
        "cross_community_edges": aggregate_edges(edge_rows),
        "risk_summary": summary,
    }
    out({"ok": True, "data": data})


def describe(conn, node, indegrees, threshold, change_type, name_counts) -> dict:
    callers = inbound(conn, node["id"], node["language"])
    count = indegrees.get(node["id"], 0)
    tests = [ref(c) for c in callers if TEST_PATH.search(c["file_path"])]
    unresolved = unresolved_for(conn, node["name"])
    caveats = caller_caveats(node, callers, name_counts, unresolved)
    home = community_of(node["file_path"])
    same_community = sum(1 for c in callers if community_of(c["file_path"]) == home)
    is_exported = is_public(node)
    is_iface = node["kind"] in INTERFACE_KINDS or bool(node["is_abstract"])

    factors = []
    if is_exported and not tests and node["kind"] in BEHAVIOR_KINDS:
        factors.append("untested_public")
    # A hub claim built on a caveated caller set is usually the binding artifact,
    # not real fan-in.
    if count >= threshold and not caveats:
        factors.append("hub")
    if is_iface:
        factors.append("interface_change")
    if unresolved and count == 0:
        # The dangerous case: no resolved caller, but call sites exist that
        # CodeGraph could not bind. Never let this read as dead code.
        factors.append("unresolved_callers")

    return {
        "id": f"{node['file_path']}::{node['name']}",
        "node_id": node["id"],
        "kind": node["kind"],
        "language": node["language"],
        "signature": node["signature"],
        "is_exported": is_exported,
        "change_type": change_type,
        "lines": [node["start_line"], node["end_line"]],
        "callers": {
            "count": count,
            "same_community": same_community,
            "in_hub": count >= threshold and not caveats,
            "sample": [ref(c) for c in callers[:5]] or None,
            "unresolved_candidates": len(unresolved),
            "unresolved_sample": [f"{u['file_path']}:{u['line']} {u['reference_name']}"
                                  for u in unresolved[:3]] or None,
            # `confident` is the only field a reviewer needs to read before
            # quoting a count: false means "upper bound — go read the code".
            "caveats": caveats or None,
            "name_definitions": name_counts.get(node["name"], 1),
            "confident": not caveats,
        },
        "tests": {"has_tests": bool(tests), "test_symbols": tests or None},
        "community": community_of(node["file_path"]),
        "risk_factors": factors or None,
    }


def new_cross_edges(conn, path: str, ranges: list) -> list:
    """Dependency edges whose CALL SITE is inside this diff and which cross a
    community boundary. Call-site lines make "added" checkable without indexing
    the base revision — the edge is new to the reviewer either way."""
    rows = conn.execute(
        f"select src.file_path as src_file, src.name as src_name,"
        f"       src.language as src_lang, tgt.language as tgt_lang,"
        f"       tgt.file_path as tgt_file, tgt.name as tgt_name, e.line, e.kind"
        f"  from edges e"
        f"  join nodes src on src.id = e.source"
        f"  join nodes tgt on tgt.id = e.target"
        f" where src.file_path = ? and {dep_edge_filter()} and e.line is not null",
        (path, *NON_DEP_EDGE_KINDS),
    )
    found = []
    for r in rows:
        if not overlaps(ranges, r["line"], r["line"]):
            continue
        if not same_family(r["src_lang"], r["tgt_lang"]):
            continue
        a, b = community_of(r["src_file"]), community_of(r["tgt_file"])
        if a == b:
            continue
        found.append({"from": a, "to": b,
                      "sample": f"{r['src_file']}::{r['src_name']} → "
                                f"{r['tgt_file']}::{r['tgt_name']}"})
    return found


def aggregate_edges(rows: list) -> list:
    buckets: dict = {}
    for r in rows:
        key = (r["from"], r["to"])
        b = buckets.setdefault(key, {"from": r["from"], "to": r["to"],
                                     "count_added": 0, "samples": []})
        b["count_added"] += 1
        if len(b["samples"]) < 3:
            b["samples"].append(r["sample"])
    return sorted(buckets.values(), key=lambda b: -b["count_added"])


def empty_summary() -> dict:
    return {"hub_nodes_modified": 0, "untested_public_changes": 0,
            "interface_changes": 0, "new_cross_community_edges": 0,
            "symbols_with_unresolved_callers": 0}


def summarize(symbols: list, edges: list) -> dict:
    real = [s for s in symbols if s["kind"] != "file"]

    def has(sym, factor):
        return factor in (sym["risk_factors"] or [])

    return {
        "hub_nodes_modified": sum(1 for s in real if has(s, "hub")),
        "untested_public_changes": sum(1 for s in real if has(s, "untested_public")),
        "interface_changes": sum(1 for s in real if has(s, "interface_change")),
        "new_cross_community_edges": sum(e["count_added"] for e in aggregate_edges(edges)),
        "symbols_with_unresolved_callers": sum(1 for s in real if has(s, "unresolved_callers")),
    }


# --- context -----------------------------------------------------------------
def resolve_id(conn, symbol_id: str):
    """Accept `path::Name`, a bare name, or CodeGraph's own node id."""
    if "::" in symbol_id:
        path, name = symbol_id.rsplit("::", 1)
        row = conn.execute(
            "select * from nodes where file_path = ? and name = ? order by start_line limit 1",
            (path, name)).fetchone()
        if row:
            return row
        symbol_id = name
    row = conn.execute("select * from nodes where id = ?", (symbol_id,)).fetchone()
    if row:
        return row
    return conn.execute(
        "select * from nodes where name = ? and kind not in ('file','import')"
        " order by length(qualified_name) limit 1", (symbol_id,)).fetchone()


def cmd_context(args) -> None:
    repo = os.path.abspath(args.repo)
    conn = open_index(repo, args.db)
    node = resolve_id(conn, args.id)
    if node is None:
        fail("symbol_not_found", f"no symbol matching '{args.id}' in the index")

    source = None
    abs_path = os.path.join(repo, node["file_path"])
    if os.path.exists(abs_path):
        with open(abs_path, "r", errors="replace") as fh:
            lines = fh.readlines()
        source = "".join(lines[node["start_line"] - 1: node["end_line"]])

    out({"ok": True, "data": {
        "mode": "built",
        "id": f"{node['file_path']}::{node['name']}",
        "kind": node["kind"],
        "signature": node["signature"],
        "docstring": node["docstring"],
        "lines": [node["start_line"], node["end_line"]],
        "source": source,
        "callers": [ref(r) for r in inbound(conn, node["id"], node["language"])],
        "callees": [ref(r) for r in outbound(conn, node["id"], node["language"])],
        "unresolved_callers": [f"{u['file_path']}:{u['line']} {u['reference_name']}"
                              for u in unresolved_for(conn, node["name"], 10)] or None,
    }})


# --- impact ------------------------------------------------------------------
def cmd_impact(args) -> None:
    repo = os.path.abspath(args.repo)
    conn = open_index(repo, args.db)
    paths = [p.strip() for p in args.files.split(",") if p.strip()]
    if not paths:
        fail("bad_args", "--files needs at least one comma-separated path")

    callers, symbols, unresolved = {}, [], 0
    for path in paths:
        for node in symbols_in_file(conn, path):
            if node["kind"] in NON_SYMBOL_KINDS:
                continue
            symbols.append(f"{path}::{node['name']}")
            for r in inbound(conn, node["id"], node["language"], limit=200):
                if r["file_path"] in paths:
                    continue  # same-file callers are not blast radius
                callers.setdefault(ref(r), r["file_path"])
            unresolved += len(unresolved_for(conn, node["name"]))

    out({"ok": True, "data": {
        "mode": "built",
        "files": paths,
        "symbols": symbols,
        "caller_union": sorted(callers),
        "caller_files": sorted(set(callers.values())),
        "unresolved_candidates": unresolved,
        "confident": unresolved == 0,
    }})


# --- hubs / callers_of / tests_for -------------------------------------------
# The three oracles repo-scan's scanners use. Kept here rather than shelling out
# to `codegraph callers` per symbol: a scanner asks these hundreds of times, and
# a process launch per question costs more than the whole index.
def cmd_hubs(args) -> None:
    repo = os.path.abspath(args.repo)
    conn = open_index(repo, args.db)
    indegrees, dropped = load_indegrees(conn)
    threshold = args.threshold if args.threshold is not None else hub_threshold(indegrees)
    name_counts = load_name_counts(conn)

    hot = sorted(((n, c) for n, c in indegrees.items() if c >= threshold),
                 key=lambda kv: -kv[1])
    hubs, ambiguous, in_tests = [], 0, 0
    for node_id, count in hot:
        if len(hubs) >= args.limit:
            break
        row = conn.execute(
            "select name, kind, file_path, start_line, is_exported, language"
            "  from nodes where id = ?", (node_id,)).fetchone()
        if row is None or row["kind"] in NON_SYMBOL_KINDS:
            continue
        # Both exclusions exist because an unfiltered hub list is actively
        # misleading: the top entries on a real repo were `Error` (defined in a
        # _test.go) and `Close`, i.e. name collisions, not fan-in. A scanner that
        # upgrades severity on "this is a hub" must not be fed those.
        if name_counts.get(row["name"], 0) > 1:
            ambiguous += 1
            continue
        if TEST_PATH.search(row["file_path"]):
            in_tests += 1
            continue
        callers = inbound(conn, node_id, row["language"], limit=200)
        home = community_of(row["file_path"])
        hubs.append({"id": f"{row['file_path']}::{row['name']}", "node_id": node_id,
                     "kind": row["kind"], "callers": count,
                     "same_community_callers": sum(
                         1 for c in callers if community_of(c["file_path"]) == home),
                     "caveats": caller_caveats(
                         row, callers, name_counts,
                         unresolved_for(conn, row["name"], 1)) or None,
                     "is_exported": is_public(row),
                     "community": home})
    out({"ok": True, "data": {"mode": "built", "threshold": threshold,
                              "cross_language_edges_ignored": dropped,
                              "excluded_ambiguous_names": ambiguous,
                              "excluded_test_definitions": in_tests,
                              "hubs": hubs}})


def cmd_callers_of(args) -> None:
    repo = os.path.abspath(args.repo)
    conn = open_index(repo, args.db)
    node = resolve_id(conn, args.id)
    if node is None:
        fail("symbol_not_found", f"no symbol matching '{args.id}' in the index")

    # Breadth-first to --depth, so "who can reach this" is answerable without the
    # caller running this command once per level.
    seen = {node["id"]}
    frontier = [node]
    levels = []
    for _ in range(max(1, args.depth)):
        nxt, level = [], []
        for current in frontier:
            for r in inbound(conn, current["id"], current["language"], limit=200):
                key = f"{r['file_path']}::{r['name']}"
                row = conn.execute(
                    "select * from nodes where file_path = ? and name = ? limit 1",
                    (r["file_path"], r["name"])).fetchone()
                if row is None or row["id"] in seen:
                    continue
                seen.add(row["id"])
                level.append({"id": key, "kind": r["kind"],
                              "is_test": bool(TEST_PATH.search(r["file_path"]))})
                nxt.append(row)
        if not level:
            break
        levels.append(level)
        frontier = nxt

    unresolved = unresolved_for(conn, node["name"], 10)
    direct = inbound(conn, node["id"], node["language"], limit=200)
    caveats = caller_caveats(node, direct, load_name_counts(conn), unresolved)
    out({"ok": True, "data": {
        "mode": "built",
        "id": f"{node['file_path']}::{node['name']}",
        "depth": args.depth,
        "levels": levels,
        "total": sum(len(level) for level in levels),
        "unresolved_candidates": len(unresolved),
        "caveats": caveats or None,
        "confident": not caveats,
    }})


def cmd_tests_for(args) -> None:
    repo = os.path.abspath(args.repo)
    conn = open_index(repo, args.db)
    node = resolve_id(conn, args.id)
    if node is None:
        fail("symbol_not_found", f"no symbol matching '{args.id}' in the index")
    callers = inbound(conn, node["id"], node["language"], limit=200)
    tests = [ref(r) for r in callers if TEST_PATH.search(r["file_path"])]
    unresolved = unresolved_for(conn, node["name"], 10)
    caveats = caller_caveats(node, callers, load_name_counts(conn), unresolved)
    out({"ok": True, "data": {
        "mode": "built",
        "id": f"{node['file_path']}::{node['name']}",
        "has_tests": bool(tests),
        "test_symbols": tests,
        # A symbol whose callers could not all be resolved may well be tested
        # through a path CodeGraph cannot see. `has_tests: false` here is
        # "no test found", never "no test exists".
        "unresolved_candidates": len(unresolved),
        "caveats": caveats or None,
        "confident": not caveats,
    }})


# --- cli ---------------------------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser(add_help=True)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("preflight")
    p.add_argument("--repo", default=".")
    p.add_argument("--base", required=True)
    p.add_argument("--head", required=True)
    p.add_argument("--db")
    p.set_defaults(func=cmd_preflight)

    c = sub.add_parser("context")
    c.add_argument("--repo", default=".")
    c.add_argument("--id", required=True)
    c.add_argument("--depth", type=int, default=1)
    c.add_argument("--db")
    c.set_defaults(func=cmd_context)

    i = sub.add_parser("impact")
    i.add_argument("--repo", default=".")
    i.add_argument("--files", required=True)
    i.add_argument("--db")
    i.set_defaults(func=cmd_impact)

    h = sub.add_parser("hubs")
    h.add_argument("--repo", default=".")
    h.add_argument("--threshold", type=int, default=None,
                   help="minimum caller count; default is this repo's p95")
    h.add_argument("--limit", type=int, default=100)
    h.add_argument("--db")
    h.set_defaults(func=cmd_hubs)

    # Underscored aliases match the query names the repo-scan prose has always
    # used (`graph query callers_of …`), so the skills read the same after the
    # backend swap.
    for name in ("callers_of", "callers-of"):
        co = sub.add_parser(name)
        co.add_argument("--repo", default=".")
        co.add_argument("--id", required=True)
        co.add_argument("--depth", type=int, default=2)
        co.add_argument("--db")
        co.set_defaults(func=cmd_callers_of)

    for name in ("tests_for", "tests-for"):
        tf = sub.add_parser(name)
        tf.add_argument("--repo", default=".")
        tf.add_argument("--id", required=True)
        tf.add_argument("--db")
        tf.set_defaults(func=cmd_tests_for)

    args = parser.parse_args()
    try:
        args.func(args)
    except BrokenPipeError:
        pass
    except Exception as exc:  # never hand the caller an unparseable crash
        fail(type(exc).__name__, str(exc)[:400])


if __name__ == "__main__":
    main()
