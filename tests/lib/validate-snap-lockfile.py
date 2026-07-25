#!/usr/bin/env python3
"""tests/lib/validate-snap-lockfile.py — shared snaps.lock.json schema
validator (SPEC.md §4.3, §4.4; GitHub issue #60, milestone M3).

Extracted verbatim (same checks, same messages) from bin/ubx-snap-resolve's
own `emit_lockfile` so the one schema definition has one implementation,
callable from:
  - tests/unit/141-snap-resolve-emit.sh, against bin/ubx-snap-resolve's
    --emit-lockfile output (fixture-driven, no network);
  - tests/unit/145-snap-lockfile.sh, against the committed snaps.lock.json
    (no network, reads the file exactly as committed);
  - a future CI job resolving against the live Snap Store, mirroring
    tests/lib/validate-archive-lockfile.py's own role for archive.lock.json.

Schema (mirrors nix/snap.nix's own `validate`, which is the Nix-side
enforcement of the identical shape):
  {
    "version": 1,
    "snaps": [
      { "name": ..., "channel": ..., "revision": <positive int>,
        "classic": <bool>, "publisher": ..., "publisherVerified": <bool>,
        "connections": [ ... ], "config": { ... },
        "snap": { "url": ..., "sha256": <64 hex>, "size": <positive int> },
        "assert": { "url": ..., "sha256": <64 hex> } },
      ...
    ]
  }
Every entry must already satisfy SPEC.md §4.5/§5's verified-publisher
policy: `publisherVerified` may only be false if the entry's own history
recorded an opt-in at resolve time (not re-checkable from the lockfile
alone -- see bin/ubx-snap-resolve's header, "_unverifiedPublisherAllowed"
is intentionally NOT part of this persisted schema). This validator
therefore does not re-enforce the policy itself; it only enforces shape.

Usage: validate-snap-lockfile.py PATH [REPO_ROOT]
Exits 0 and prints "OK: ..." on success; exits 1 and prints "FAIL: ..." (one
line per violation) on failure.

When REPO_ROOT is given, an additional check runs: every entry's vendored
assertion file (`REPO_ROOT/snaps/assertions/<name>_<revision>.snap-
declaration` -- the exact path/naming convention nix/snap.nix's
`fetchAssert` and bin/ubx-snap-resolve's `emit_lockfile` both use, see
their own headers) must exist and its flat sha256 must equal that entry's
own `assert.sha256`. This guards the vendored-file/lockfile invariant the
snap-declaration Accept-header content-negotiation fix depends on (a
lockfile entry whose vendored file is missing or stale would make
nix/snap.nix's fetch either fail outright or silently verify the WRONG
bytes against the right hash, which can't happen if the hash matches, but
COULD happen if someone hand-edits the lockfile's assert.sha256 without
regenerating the vendored file -- this check exists to catch exactly that
drift). REPO_ROOT is omitted by callers exercising `--emit-lockfile`
fixtures that don't supply assertion bytes (bin/ubx-snap-resolve's header,
"Emission": `_assertBase64` is optional) -- there is no vendored file to
check in that case, so the check is skipped rather than failing spuriously.
"""
import hashlib
import json
import os
import re
import sys

path = sys.argv[1]
repo_root = sys.argv[2] if len(sys.argv) > 2 else None
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

snaps = data.get("snaps")
if not isinstance(snaps, list):
    fail(f"'snaps' must be a list, got {type(snaps).__name__}")
    snaps = []

if len(snaps) < 1:
    fail("'snaps' must have at least 1 entry")

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
REQUIRED_FIELDS = (
    "name", "channel", "revision", "classic", "publisher",
    "publisherVerified", "connections", "config", "snap", "assert",
)

seen_names = set()
for i, s in enumerate(snaps):
    if not isinstance(s, dict):
        fail(f"snaps[{i}] must be an object, got {type(s).__name__}")
        continue

    label = f"snaps[{i}] ({s.get('name', '<unnamed>')!r})"

    missing = [f for f in REQUIRED_FIELDS if f not in s]
    if missing:
        fail(f"{label} missing required field(s): {', '.join(missing)}")

    name = s.get("name")
    if isinstance(name, str):
        if not NAME_RE.match(name):
            fail(f"{label} 'name' is not a valid snap name: {name!r}")
        if name in seen_names:
            fail(f"duplicate snap name in snaps: {name!r}")
        seen_names.add(name)
    elif "name" in s:
        fail(f"{label} 'name' must be a string, got {type(name).__name__}")

    if "channel" in s and (not isinstance(s["channel"], str) or not s["channel"]):
        fail(f"{label} 'channel' must be a non-empty string")

    if "revision" in s:
        revision = s["revision"]
        if not isinstance(revision, int) or isinstance(revision, bool) or revision <= 0:
            fail(f"{label} 'revision' must be a positive integer, got {revision!r}")

    if "classic" in s and not isinstance(s["classic"], bool):
        fail(f"{label} 'classic' must be a boolean")

    if "publisher" in s and (not isinstance(s["publisher"], str) or not s["publisher"]):
        fail(f"{label} 'publisher' must be a non-empty string")

    if "publisherVerified" in s and not isinstance(s["publisherVerified"], bool):
        fail(f"{label} 'publisherVerified' must be a boolean")

    if "connections" in s:
        connections = s["connections"]
        if not isinstance(connections, list) or not all(isinstance(c, str) for c in connections):
            fail(f"{label} 'connections' must be a list of strings")

    if "config" in s and not isinstance(s["config"], dict):
        fail(f"{label} 'config' must be an object")

    if "snap" in s:
        snap = s["snap"]
        if not isinstance(snap, dict):
            fail(f"{label} 'snap' must be an object")
        else:
            if "sha256" not in snap or not isinstance(snap["sha256"], str) or not SHA256_RE.match(snap["sha256"]):
                fail(f"{label} 'snap.sha256' must match ^[0-9a-f]{{64}}$, got {snap.get('sha256')!r}")
            if "size" not in snap or not isinstance(snap["size"], int) or isinstance(snap["size"], bool) or snap["size"] <= 0:
                fail(f"{label} 'snap.size' must be a positive integer, got {snap.get('size')!r}")
            if "url" not in snap or not isinstance(snap["url"], str) or not snap["url"]:
                fail(f"{label} 'snap.url' must be a non-empty string")

    if "assert" in s:
        assertion = s["assert"]
        if not isinstance(assertion, dict):
            fail(f"{label} 'assert' must be an object")
        else:
            if "sha256" not in assertion or not isinstance(assertion["sha256"], str) or not SHA256_RE.match(assertion["sha256"]):
                fail(f"{label} 'assert.sha256' must match ^[0-9a-f]{{64}}$, got {assertion.get('sha256')!r}")
            if "url" not in assertion or not isinstance(assertion["url"], str) or not assertion["url"]:
                fail(f"{label} 'assert.url' must be a non-empty string")

if errors:
    print(f"FAIL: {path} failed schema validation:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)

# -- vendored-file/lockfile invariant (see this module's docstring) --------
if repo_root is not None:
    for s in snaps:
        vendored_path = os.path.join(
            repo_root, "snaps", "assertions",
            f"{s['name']}_{s['revision']}.snap-declaration",
        )
        if not os.path.isfile(vendored_path):
            fail(f"{vendored_path} does not exist (every lockfile entry needs a vendored assertion file -- see nix/snap.nix's/bin/ubx-snap-resolve's headers, 'Vendoring'/'Emission')")
            continue
        with open(vendored_path, "rb") as f:
            actual_sha256 = hashlib.sha256(f.read()).hexdigest()
        expected_sha256 = s["assert"]["sha256"]
        if actual_sha256 != expected_sha256:
            fail(
                f"{vendored_path} has sha256 {actual_sha256}, but "
                f"snaps[?] ({s['name']!r})'s assert.sha256 is "
                f"{expected_sha256!r} -- vendored file is stale or the "
                "lockfile was hand-edited; re-run bin/ubx-snap-resolve"
            )

if errors:
    print(f"FAIL: {path} failed vendored-assertion validation:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)

print(f"OK: {path} ({len(snaps)} snap(s))")
