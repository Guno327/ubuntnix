#!/usr/bin/env bash
# tests/unit/040-archive-lockfile.sh — archive.lock.json schema validation
# (SPEC.md §4.4; GitHub issue #7, milestone M1).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so nix/archive.nix's own
# `builtins.fromJSON` parse can't be exercised here — that's CI-only (the
# "flake" job in .github/workflows/ci.yml, which builds
# `.#archive-fetch-proof` / `.#archive-hash-mismatch-proof`). This test
# instead validates the lockfile's SHAPE directly with python3's `json`
# module, against the schema documented in nix/archive.nix's header
# comment — exactly as any other non-Nix tool (a future `ubx update`, docs
# tooling, CI) would read it. No network access happens here: the file is
# read from disk exactly as committed.
set -u

cd "$UBX_REPO_ROOT" || exit 1

lockfile="archive.lock.json"

[ -f "$lockfile" ] || {
  echo "FAIL: $lockfile does not exist" >&2
  exit 1
}

python3 - "$lockfile" <<'PYEOF'
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

# -- lockfile format version ----------------------------------------------
if data.get("version") != 1:
    fail(f"'version' must be the integer 1, got {data.get('version')!r}")

# -- public tier ------------------------------------------------------------
public = data.get("public")
if not isinstance(public, dict):
    fail(f"'public' must be an object, got {type(public).__name__}")
    public = {}

snapshot = public.get("snapshot")
SNAPSHOT_RE = re.compile(r"^[0-9]{8}T[0-9]{6}Z$")
if not isinstance(snapshot, str) or not SNAPSHOT_RE.match(snapshot):
    fail(
        "'public.snapshot' must match ^[0-9]{8}T[0-9]{6}Z$ "
        f"(e.g. 20260715T000000Z), got {snapshot!r}"
    )

series = public.get("series")
if series != "noble":
    fail(f"'public.series' must be 'noble', got {series!r}")

packages = public.get("packages")
if not isinstance(packages, list):
    fail(f"'public.packages' must be a list, got {type(packages).__name__}")
    packages = []

if len(packages) < 3:
    fail(f"'public.packages' must have at least 3 entries, got {len(packages)}")

REQUIRED_FIELDS = ("name", "version", "arch", "component", "path", "sha256", "size")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

seen_names = set()
for i, pkg in enumerate(packages):
    if not isinstance(pkg, dict):
        fail(f"public.packages[{i}] must be an object, got {type(pkg).__name__}")
        continue

    label = f"public.packages[{i}] ({pkg.get('name', '<unnamed>')!r})"

    missing = [f for f in REQUIRED_FIELDS if f not in pkg]
    if missing:
        fail(f"{label} missing required field(s): {', '.join(missing)}")

    name = pkg.get("name")
    if isinstance(name, str):
        if name in seen_names:
            fail(f"duplicate package name in public.packages: {name!r}")
        seen_names.add(name)
    elif "name" in pkg:
        fail(f"{label} 'name' must be a string, got {type(name).__name__}")

    if "sha256" in pkg:
        sha256 = pkg["sha256"]
        if not isinstance(sha256, str) or not SHA256_RE.match(sha256):
            fail(f"{label} 'sha256' must match ^[0-9a-f]{{64}}$, got {sha256!r}")

    if "size" in pkg:
        size = pkg["size"]
        if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
            fail(f"{label} 'size' must be a positive integer, got {size!r}")

    if "path" in pkg:
        pkg_path = pkg["path"]
        if not isinstance(pkg_path, str) or not pkg_path.startswith("pool/"):
            fail(f"{label} 'path' must start with 'pool/', got {pkg_path!r}")

    if "arch" in pkg:
        arch = pkg["arch"]
        # "all" is a legitimate Debian archive architecture (arch-independent
        # packages, e.g. tzdata -- added for issue #9's compose work) in
        # addition to this project's native "amd64" target; anything else
        # would be a real schema violation.
        if arch not in ("amd64", "all"):
            fail(f"{label} 'arch' must be 'amd64' or 'all', got {arch!r}")

    for str_field in ("version", "component"):
        if str_field in pkg and (
            not isinstance(pkg[str_field], str) or not pkg[str_field]
        ):
            fail(f"{label} field '{str_field}' must be a non-empty string, got {pkg[str_field]!r}")

# -- esm tier -----------------------------------------------------------
esm = data.get("esm")
if not isinstance(esm, dict):
    fail(f"'esm' must be an object, got {type(esm).__name__}")
    esm = {}

esm_packages = esm.get("packages")
if not isinstance(esm_packages, list):
    fail(f"'esm.packages' must be a list, got {type(esm_packages).__name__}")
elif esm_packages != []:
    fail(
        "'esm.packages' must be an empty list in M1 (esm fetching lands in "
        f"M4 -- SPEC.md §4.4, R4); got {len(esm_packages)} entries"
    )

if errors:
    print(f"FAIL: {path} failed schema validation:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)

print(f"OK: {path} ({len(packages)} public package(s), schema valid)")
sys.exit(0)
PYEOF
