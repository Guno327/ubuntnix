#!/usr/bin/env python3
"""Assert the shape of the CI `home-proof` derivation's output.

Kept as a standalone script rather than an inline `python3 -c "..."` inside
.github/workflows/ci.yml for the same reason tests/lib/check-etc-proof.py
and tests/lib/check-systemd-proof.py are (see their headers): a multi-line
Python program embedded in a YAML block scalar is at the mercy of
block-scalar indentation rules and silently breaks the whole workflow file.

Usage: check-home-proof.py <home-proof output dir>

Checks (issue #98, SPEC.md §9, §4.3 row "Home files, user services"): the
rendered per-user home tree carries the declared $HOME file with its
declared content and the declared user service, and the JSON manifest lists
the declaring user with exactly the declared file paths and service names.
"""
import json
import sys
from pathlib import Path


def fail(msg: str) -> None:
    print(f"check-home-proof: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: check-home-proof.py <home-proof output dir>")
    out = Path(sys.argv[1])

    bashrc = out / "tree" / "gunnar" / "files" / ".bashrc"
    service = out / "tree" / "gunnar" / "services" / "ubuntnix-home-example.service"
    manifest_path = out / "manifest.json"

    for p in (bashrc, service, manifest_path):
        if not p.is_file():
            fail(f"missing expected output file: {p}")

    if "EDITOR=vim" not in bashrc.read_text():
        fail("tree/gunnar/files/.bashrc does not contain the declared text")

    manifest = json.loads(manifest_path.read_text())
    if manifest.get("version") != 1:
        fail(f"unexpected manifest version: {manifest.get('version')!r}")

    users = {u["name"]: u for u in manifest.get("users", [])}
    if "gunnar" not in users:
        fail(f"manifest missing user 'gunnar', got users: {sorted(users)}")

    gunnar = users["gunnar"]
    file_paths = {f["path"] for f in gunnar.get("files", [])}
    want_files = {".bashrc", ".config/foo/config.toml"}
    if file_paths != want_files:
        fail(f"gunnar file paths {sorted(file_paths)} != expected {sorted(want_files)}")

    svc_names = {s["name"] for s in gunnar.get("services", [])}
    want_svcs = {"ubuntnix-home-example.service"}
    if svc_names != want_svcs:
        fail(f"gunnar service names {sorted(svc_names)} != expected {sorted(want_svcs)}")

    print("check-home-proof: OK")


if __name__ == "__main__":
    main()
