#!/usr/bin/env bash
# tests/unit/053-archive-declaration-seed.sh — every name declared in the
# committed archive.packages.json must be pinned in archive.lock.json
# (SPEC.md §4.4, §6; GitHub issues #8/#20, milestone M1).
#
# DIRECTION NOTE: this invariant INVERTED when issue #20 landed. During
# the hand-built-lockfile era (#7), the declaration was seeded FROM the
# lockfile and this test asserted pinned ⊆ declared. Now the lockfile is
# generator-emitted (bin/ubx-resolve, CI regen-lockfile job): it pins the
# declared set's full real dependency closure, which is necessarily a
# strict superset of the declaration (122 pinned vs ~18 declared at the
# first regeneration). The committable invariant is declared ⊆ pinned:
# a declared name missing from the lockfile means someone declared a
# package and forgot to re-run the resolver.
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

missing = sorted(declared - pinned)
if missing:
    print(
        f"FAIL: {decl_path} declares package(s) the lockfile does not pin "
        f"(declared but never resolved -- re-run the resolver, see the CI "
        f"regen-lockfile job): {missing}",
        file=sys.stderr,
    )
    sys.exit(1)

print(
    f"OK: all {len(declared)} declared package name(s) are pinned in "
    f"{lock_path} (closure: {len(pinned)} packages)"
)
PYEOF
