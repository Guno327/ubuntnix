#!/usr/bin/env python3
"""tests/lib/validate-etc-exceptions.py — shared etc.exceptions.json schema
validator (SPEC.md §4.2, §4.3; GitHub issue #26, milestone M2).

Extracted as a standalone, directly-testable implementation of the exact
same shape nix/etc.nix's own `validateExceptions` enforces at eval time
(see that file's header, "Machine-local mutable exceptions") — this
harness has no `nix` binary (tests/unit/021-flake-purity.sh's header
explains why), so nix's own enforcement can't be exercised here; CI's
"flake" job (`nix flake check`, which forces every eval-boundary
`validate`/`validateExceptions` call in the tree) is what proves the two
never drift apart. Used by:
  - tests/unit/110-etc-exceptions.sh, against the committed
    etc.exceptions.json (no network, reads the file exactly as committed);
  - the same test's fixture-driven rejection cases (malformed mode, a
    `sensitive` entry with a world-readable mode, missing fields).

Schema:
  {
    "version": 1,
    "exceptions": [
      { "path": ..., "owner": ..., "group": ..., "mode": "0600",
        "sensitive": <bool>, "reason": ... },
      ...
    ]
  }

Additional rule (SPEC.md §4.2, "never world-readable when sensitive"): a
`sensitive: true` entry's `mode` must not have the world ("other") read
bit set — i.e. its last octal digit must not be 4/5/6/7.

Usage: validate-etc-exceptions.py PATH
Exits 0 and prints "OK: ..." on success; exits 1 and prints "FAIL: ..."
(one line per violation) on failure.
"""
import json
import re
import sys

path = sys.argv[1]
errors = []


def fail(msg):
    errors.append(msg)


try:
    with open(path, encoding="utf-8") as f:
        raw = f.read()
except OSError as e:
    print(f"FAIL: could not read {path}: {e}", file=sys.stderr)
    sys.exit(1)

try:
    data = json.loads(raw)
except json.JSONDecodeError as e:
    print(f"FAIL: {path} is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)

if not isinstance(data, dict):
    print(f"FAIL: {path} top level is not a JSON object", file=sys.stderr)
    sys.exit(1)

if data.get("version") != 1:
    fail(f"'version' must be the integer 1, got {data.get('version')!r}")

exceptions = data.get("exceptions")
if not isinstance(exceptions, list):
    fail(f"'exceptions' must be a list, got {type(exceptions).__name__}")
    exceptions = []

REQUIRED_FIELDS = ("path", "owner", "group", "mode", "sensitive", "reason")
MODE_RE = re.compile(r"^0[0-7]{3}$")

seen_paths = set()
for i, e in enumerate(exceptions):
    if not isinstance(e, dict):
        fail(f"exceptions[{i}] must be an object, got {type(e).__name__}")
        continue

    label = f"exceptions[{i}] ({e.get('path', '<no path>')!r})"

    missing = [f for f in REQUIRED_FIELDS if f not in e]
    if missing:
        fail(f"{label} missing required field(s): {', '.join(missing)}")
        continue

    p = e["path"]
    if not isinstance(p, str) or not p:
        fail(f"{label} 'path' must be a non-empty string, got {p!r}")
    elif p in seen_paths:
        fail(f"duplicate exception path: {p!r}")
    else:
        seen_paths.add(p)
    if isinstance(p, str) and p.startswith("/"):
        fail(f"{label} 'path' must be relative (no leading '/'), got {p!r}")

    mode = e["mode"]
    mode_ok = isinstance(mode, str) and bool(MODE_RE.match(mode))
    if not mode_ok:
        fail(f"{label} 'mode' must be 4 octal digits as a string (e.g. \"0600\"), got {mode!r}")

    sensitive = e["sensitive"]
    if not isinstance(sensitive, bool):
        fail(f"{label} 'sensitive' must be a boolean, got {sensitive!r}")
    elif mode_ok and sensitive and mode[-1] in "4567":
        fail(
            f"{label} is marked sensitive but its mode {mode!r} is "
            "world-readable (SPEC.md §4.2's 'never world-readable when "
            "sensitive' requirement)"
        )

    if not isinstance(e["owner"], str) or not e["owner"]:
        fail(f"{label} 'owner' must be a non-empty string, got {e['owner']!r}")
    if not isinstance(e["group"], str) or not e["group"]:
        fail(f"{label} 'group' must be a non-empty string, got {e['group']!r}")
    if not isinstance(e["reason"], str) or not e["reason"]:
        fail(f"{label} 'reason' must be a non-empty string, got {e['reason']!r}")

if errors:
    print(f"FAIL: {path} failed schema validation:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)

print(f"OK: {path} ({len(exceptions)} exception(s), schema valid)")
sys.exit(0)
