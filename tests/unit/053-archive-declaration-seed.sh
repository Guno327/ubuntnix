#!/usr/bin/env bash
# tests/unit/053-archive-declaration-seed.sh — the committed
# archive.packages.json must declare (at least) every package name already
# pinned in archive.lock.json (SPEC.md §4.4, §6; GitHub issue #8, milestone
# M1 seeding instruction: "Seed it with the packages currently in
# archive.lock.json ... so re-resolving reproduces the current lockfile's
# package closure").
#
# This is distinct from tests/unit/050-archive-declared.sh (which checks
# archive.packages.json's own schema in isolation): this test cross-checks
# it against archive.lock.json. No network access happens here — both
# files are read from disk exactly as committed.
set -u

cd "$UBX_REPO_ROOT" || exit 1

declfile="archive.packages.json"
lockfile="archive.lock.json"

for f in "$declfile" "$lockfile"; do
  [ -f "$f" ] || {
    echo "FAIL: $f does not exist" >&2
    exit 1
  }
done

python3 - "$declfile" "$lockfile" <<'PYEOF'
import json
import sys

decl_path, lock_path = sys.argv[1], sys.argv[2]

declared = set(json.load(open(decl_path, encoding="utf-8"))["packages"])
pinned = {p["name"] for p in json.load(open(lock_path, encoding="utf-8"))["public"]["packages"]}

missing = sorted(pinned - declared)
if missing:
    print(
        f"FAIL: {decl_path}'s declared packages do not cover every name "
        f"pinned in {lock_path}; missing: {missing}",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"OK: {decl_path} declares all {len(pinned)} package name(s) pinned in {lock_path}")
PYEOF
