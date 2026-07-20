#!/usr/bin/env python3
"""tests/lib/check-resolved-closure.py — CI sanity check for a real,
network-driven bin/ubx-resolve run (GitHub issue #8, milestone M1; see the
"resolve" job in .github/workflows/ci.yml).

Deliberately kept as a standalone script (rather than embedded inline in
ci.yml, e.g. a multi-line `python3 -c "..."`) so its lines can be indented
however Python wants without fighting YAML block-scalar indentation rules.

Checks, given a declaration file and the lockfile bin/ubx-resolve produced
from it:
  1. the resolved package count is STRICTLY GREATER than the declared
     count — a real apt solve against an empty dpkg status pulls in each
     declared package's actual runtime dependencies (libc6 and friends),
     so a resolved count at or below the declared count would mean the
     solver never really ran (e.g. a regression silently echoing the
     declared list back out instead of solving it);
  2. every declared package name is actually present by name in the
     resolved closure (the solver can't "resolve away" a package it was
     explicitly asked to install).

Usage: check-resolved-closure.py DECLARATION_FILE LOCKFILE
Exits 0 on success; prints a message to stderr and exits 1 on failure.
"""
import json
import sys

if len(sys.argv) != 3:
    print("usage: check-resolved-closure.py DECLARATION_FILE LOCKFILE", file=sys.stderr)
    sys.exit(2)

decl_path, lock_path = sys.argv[1], sys.argv[2]

declared = json.load(open(decl_path, encoding="utf-8"))["packages"]
resolved = json.load(open(lock_path, encoding="utf-8"))["public"]["packages"]
resolved_names = {p["name"] for p in resolved}

print(f"declared package count: {len(declared)}; resolved package count: {len(resolved)}")

errors = []
if len(resolved) <= len(declared):
    errors.append(
        f"resolved package count ({len(resolved)}) is not greater than the "
        f"declared count ({len(declared)}) — expected the real apt solver "
        "to pull in dependencies"
    )

missing = [name for name in declared if name not in resolved_names]
if missing:
    errors.append(f"declared package(s) missing from the resolved closure: {missing}")

if errors:
    for e in errors:
        print(f"FAIL: {e}", file=sys.stderr)
    sys.exit(1)

print("OK: resolved closure is a proper superset of the declared package set")
