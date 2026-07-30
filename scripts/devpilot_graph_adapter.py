#!/usr/bin/env python3
"""Normalise a `devpilot graph` payload into the wrapper's canonical schema.

Why this file exists
--------------------
`devpilot graph preflight` predates the CodeGraph backend and emits a payload
that is *close* to the one `codegraph_preflight.py` synthesizes, but not field
compatible. Reading a devpilot payload with the CodeGraph field list produces
silently wrong answers, so nothing may consume it raw. Verified differences
against devpilot v0.18.3:

  missing entirely   `changed_symbols[].lines`
                     `changed_symbols[].callers.same_community`
                     `changed_symbols[].callers.unresolved_candidates`
                     `changed_symbols[].callers.caveats`
                     `changed_symbols[].callers.confident`   <- the important one
                     `graph.indexed_files`, `graph.hub_threshold`,
                     `graph.unindexed_changed_files`,
                     `graph.cross_language_edges_ignored`
                     `risk_summary.symbols_with_unresolved_callers`
  renamed / reskewed `graph.freshness.covers_base_sha` (devpilot) vs
                     `graph.freshness.covers_head_sha` (CodeGraph) — these are
                     different questions, so the value is recomputed here from
                     git rather than copied across.
  empty-value skew   devpilot returns `[]` where CodeGraph returns `null`
  devpilot-only      `is_new`, `callees_changed`, `implementors_of`,
                     `implements`, `truncated_symbols`, `graph.languages`
                     (kept — additive fields cost the reader nothing)

The one judgement call, stated plainly
--------------------------------------
`callers.confident` gates two opposite behaviours in the review: a confident
count may *corroborate* a finding (floor 85) and may *contradict* one (cap 50,
which drops it). devpilot binds callers through a resolved module graph — that
is why it refuses repos without a build manifest — so its counts are
structurally resolved, not name-matched, and `confident: true` is the honest
mapping. But devpilot exposes no per-symbol resolution diagnostics, so
`confident: true` here means "this backend resolves structurally", not "the
synthesizer checked this symbol". Corroborating on that is fine; killing a real
finding on it is not. So the payload also carries
`data.contradiction_allowed: false`, and graph.md forbids the contradiction
direction on this backend.
"""

import argparse
import json
import subprocess
import sys


def none_if_empty(value):
    """CodeGraph reports absent collections as null; devpilot uses []."""
    if value in ([], {}, ""):
        return None
    return value


def git_head(repo):
    try:
        out = subprocess.run(
            ["git", "-C", repo, "rev-parse", "HEAD"],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout.strip() or None if out.returncode == 0 else None


def fallback(reason):
    return {"ok": False, "data": {"mode": "fallback", "backend": "devpilot",
                                  "reason": reason}}


def adapt_callers(callers):
    callers = callers or {}
    return {
        "count": callers.get("count", 0),
        # devpilot does not split callers by package, and does not report the
        # call sites it failed to bind — it fails the whole build instead.
        "same_community": None,
        "in_hub": bool(callers.get("in_hub")),
        "sample": none_if_empty(callers.get("sample")),
        "unresolved_candidates": None,
        "caveats": None,
        "confident": True,  # structural binding; see the module docstring
    }


def adapt_symbol(sym):
    out = dict(sym)
    out["callers"] = adapt_callers(sym.get("callers"))
    # devpilot's preflight carries no line span. Absent, not zero: a consumer
    # that anchors on `lines` must fall back to the diff hunk.
    out["lines"] = None
    tests = sym.get("tests") or {}
    out["tests"] = {
        "has_tests": bool(tests.get("has_tests")),
        "test_symbols": none_if_empty(tests.get("test_symbols")),
    }
    out["risk_factors"] = none_if_empty(sym.get("risk_factors"))
    return out


def adapt_preflight(data, repo, head_sha):
    graph = data.get("graph") or {}
    freshness = graph.get("freshness") or {}

    # covers_head_sha is *not* devpilot's covers_base_sha. Recompute the real
    # question — "does the indexed tree hold the revision under review?" — from
    # git, so `index_stale` still gets caught on this backend.
    worktree_head = git_head(repo)
    if head_sha and worktree_head:
        covers_head = worktree_head.startswith(head_sha) or head_sha.startswith(worktree_head)
    else:
        covers_head = None

    # Fail the payload closed, exactly as codegraph_preflight.py does. `mode`
    # stays "built" in devpilot's own envelope even when the index describes a
    # different revision, and the skill's fallback trigger only looks at `mode`
    # — so a stale index would otherwise be read as ground truth.
    if covers_head is False:
        return fallback(
            "index_stale: the indexed tree is at %s but the revision under "
            "review is %s — re-run `ensure --repo <repo> --at %s`"
            % (worktree_head[:12], head_sha[:12], head_sha[:12])
        )

    symbols = [adapt_symbol(s) for s in (data.get("changed_symbols") or [])]
    risk = dict(data.get("risk_summary") or {})
    # devpilot never reports unresolved callers: a repo it cannot resolve fails
    # to build at all, so the count is zero by construction, not by measurement.
    risk.setdefault("symbols_with_unresolved_callers", 0)

    return {
        "ok": True,
        "data": {
            "mode": data.get("mode", "built"),
            "backend": "devpilot",
            # See the docstring: corroborate yes, contradict no.
            "contradiction_allowed": False,
            "backend_caveats": [
                "no per-symbol resolution diagnostics: callers.confident "
                "reflects the backend's structural binding, not a per-symbol check",
                "changed_symbols[].lines is unavailable; anchor on the diff hunk",
            ],
            "graph": {
                "freshness": {
                    "covers_head_sha": covers_head,
                    "covers_base_sha": freshness.get("covers_base_sha"),
                    "stale_files": freshness.get("stale_files", 0),
                    "head_sha": worktree_head,
                },
                "languages": none_if_empty(graph.get("languages")),
                "indexed_files": None,
                "hub_threshold": None,
                "unindexed_changed_files": none_if_empty(graph.get("skipped_files")),
                "cross_language_edges_ignored": None,
            },
            "changed_symbols": symbols,
            "cross_community_edges": data.get("cross_community_edges") or [],
            "risk_summary": risk,
            "truncated_symbols": none_if_empty(data.get("truncated_symbols")),
        },
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--command", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--head-sha", default="")
    args = ap.parse_args()

    raw = sys.stdin.read()
    start = raw.find("{")
    if start < 0:
        print(json.dumps(fallback(
            "devpilot_no_output: `devpilot graph` produced no JSON envelope")))
        return
    try:
        envelope = json.loads(raw[start:])
    except ValueError as exc:
        print(json.dumps(fallback(f"devpilot_unparseable: {exc}")))
        return

    if not envelope.get("ok"):
        err = envelope.get("error") or {}
        print(json.dumps(fallback(
            f"{err.get('code') or 'unknown'}: {err.get('message') or ''}".strip())))
        return

    data = envelope.get("data") or {}
    if args.command == "preflight":
        print(json.dumps(adapt_preflight(data, args.repo, args.head_sha)))
        return

    # context / impact / hubs are read as evidence text rather than as a
    # field-addressed payload, so tag the backend and pass the body through.
    data.setdefault("mode", "built")
    data["backend"] = "devpilot"
    print(json.dumps({"ok": True, "data": data}))


if __name__ == "__main__":
    main()
