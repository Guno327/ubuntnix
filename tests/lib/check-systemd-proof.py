#!/usr/bin/env python3
"""Assert the shape of the CI `systemd-proof` derivation's output.

Kept as a standalone script rather than an inline `python3 -c "..."` inside
.github/workflows/ci.yml for the same reason tests/lib/check-etc-proof.py
is (see that file's own header): a multi-line Python program embedded in a
YAML block scalar is at the mercy of block-scalar indentation rules.

Usage: check-systemd-proof.py <systemd-proof output dir>

Checks (issue #27, SPEC.md §4.3/§6): the rendered systemd tree carries the
declared fully-owned unit with its declared content, the packaged-state-only
service entry appears in the manifest with no content file, and every unit
in the manifest carries the fields bin/ubx-systemd's manifest schema
requires (class, refuseRestart, hasContent, sha256, enable, mask).
"""
import json
import sys
from pathlib import Path


def fail(msg: str) -> None:
    print(f"check-systemd-proof: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: check-systemd-proof.py <systemd-proof output dir>")
    out = Path(sys.argv[1])

    unit_file = out / "tree" / "ubuntnix-example.service"
    manifest_path = out / "manifest.json"

    for p in (unit_file, manifest_path):
        if not p.is_file():
            fail(f"missing expected output file: {p}")

    if "ubuntnix example service" not in unit_file.read_text():
        fail("tree/ubuntnix-example.service does not contain the declared text")

    manifest = json.loads(manifest_path.read_text())
    if manifest.get("version") != 1:
        fail(f"unexpected manifest version: {manifest.get('version')!r}")

    units = {u["name"]: u for u in manifest.get("units", [])}
    names = sorted(units)
    if names != ["cups.service", "ubuntnix-example.service"]:
        fail(f"unexpected manifest unit names: {names}")

    example = units["ubuntnix-example.service"]
    if not example["hasContent"] or example["sha256"] is None:
        fail(f"ubuntnix-example.service should carry content + a sha256, got: {example}")
    if example["class"] != "service" or example["refuseRestart"] is not False:
        fail(f"ubuntnix-example.service: unexpected class/refuseRestart: {example}")

    cups = units["cups.service"]
    if cups["hasContent"] is not False or cups["sha256"] is not None:
        fail(f"cups.service (packaged-state-only) should have no content/sha256, got: {cups}")
    if cups["enable"] is not False:
        fail(f"cups.service should be declared enable=false, got: {cups}")

    for name, u in units.items():
        want_fields = {"name", "class", "refuseRestart", "hasContent", "sha256", "enable", "mask"}
        if set(u.keys()) != want_fields:
            fail(f"unit {name!r}: unexpected field set: {sorted(u.keys())}")

    print("check-systemd-proof: OK")


if __name__ == "__main__":
    main()
