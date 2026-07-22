#!/usr/bin/env python3
"""Assert the shape of the CI `etc-proof` derivation's output.

Kept as a standalone script rather than an inline `python3 -c "..."` inside
.github/workflows/ci.yml for the same reason tests/lib/check-resolved-
closure.py is (see that file and the "Archive resolution" job's own
comment): a multi-line Python program embedded in a YAML block scalar is at
the mercy of block-scalar indentation rules, and getting it wrong breaks
the whole workflow FILE, not just the step -- GitHub then rejects every job
in it with a 0-second "invalid workflow" failure and no log, which is
exactly what happened on the first push of this branch.

Usage: check-etc-proof.py <etc-proof output dir>

Checks (issue #26, SPEC §4.2): the rendered per-generation /etc tree
carries the declared entries with their declared content, and manifest.json
describes exactly those entries with their declared owner/group/mode.
"""
import json
import sys
from pathlib import Path


def fail(msg: str) -> None:
    print(f"check-etc-proof: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: check-etc-proof.py <etc-proof output dir>")
    out = Path(sys.argv[1])

    motd = out / "tree" / "motd"
    cfg_path = out / "tree" / "app" / "config.json"
    manifest_path = out / "manifest.json"

    for p in (motd, cfg_path, manifest_path):
        if not p.is_file():
            fail(f"missing expected output file: {p}")

    if "Welcome to ubuntnix." not in motd.read_text():
        fail("tree/motd does not contain the declared text")

    manifest = json.loads(manifest_path.read_text())
    if manifest.get("version") != 1:
        fail(f"unexpected manifest version: {manifest.get('version')!r}")

    paths = sorted(e["path"] for e in manifest["entries"])
    if paths != ["app/config.json", "motd"]:
        fail(f"unexpected manifest entry paths: {paths}")

    cfg = next(e for e in manifest["entries"] if e["path"] == "app/config.json")
    got = (cfg["owner"], cfg["group"], cfg["mode"])
    if got != ("root", "root", "0640"):
        fail(f"unexpected owner/group/mode for app/config.json: {got}")

    print("check-etc-proof: OK")


if __name__ == "__main__":
    main()
