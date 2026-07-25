#!/usr/bin/env bash
# tests/unit/144-snap-lockfile.sh — the committed snaps.lock.json:
# schema-valid, and every name declared in snaps.packages.json is pinned
# (SPEC.md §4.3, §4.4, §6; GitHub issue #60, milestone M3). No network
# access happens here — both files are read from disk exactly as
# committed, mirroring tests/unit/040-archive-lockfile.sh /
# tests/unit/053-archive-declaration-seed.sh's identical roles for the
# archive lockfile.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

declfile="snaps.packages.json"
lockfile="snaps.lock.json"
validator="$UBX_REPO_ROOT/tests/lib/validate-snap-lockfile.py"

for f in "$declfile" "$lockfile" "$validator"; do
  [ -f "$f" ] || {
    echo "FAIL: $f does not exist" >&2
    exit 1
  }
done

# -- schema conformance, PLUS the vendored-assertion invariant (passing
# $UBX_REPO_ROOT as validate-snap-lockfile.py's optional REPO_ROOT arg turns
# on its "every entry has a matching snaps/assertions/<name>_<revision>.
# snap-declaration file whose sha256 equals assert.sha256" check -- see
# that script's own docstring) -----------------------------------------
schema_out="$(python3 "$validator" "$lockfile" "$UBX_REPO_ROOT" 2>&1)"
schema_rc=$?
[ "$schema_rc" -eq 0 ] || fail "$lockfile failed schema/vendored-assertion validation: $schema_out"

# -- both files must be valid, parseable JSON with the expected top-level
# shape, and both must be plain JSON with no `nix` binary required to read
# them (SPEC.md §4.4's "readable with no nix binary" reasoning, shared by
# every lockfile/declaration pair in this project) ---------------------
python3 - "$declfile" "$lockfile" <<'PYEOF'
import json
import sys

decl_path, lock_path = sys.argv[1], sys.argv[2]

decl = json.load(open(decl_path, encoding="utf-8"))
lock = json.load(open(lock_path, encoding="utf-8"))

declared = set(decl["snaps"])
pinned = {s["name"] for s in lock["snaps"]}

# Declared-but-unpinned is the drift bin/ubx-snap-resolve exists to close
# (mirrors tests/unit/053's identical declared-subseteq-pinned invariant
# for the archive lockfile).
missing = sorted(declared - pinned)
if missing:
    print(
        f"FAIL: {decl_path} declares snap(s) the lockfile does not pin "
        f"(declared but never resolved -- re-run bin/ubx-snap-resolve): {missing}",
        file=sys.stderr,
    )
    sys.exit(1)

# Every pinned entry must have passed the verified-publisher policy
# (SPEC.md §4.5/§5): committed, at-rest, this file must never carry an
# entry that publisherVerified=false without that being an intentional,
# reviewable exception -- since the persisted schema deliberately does not
# carry the opt-in flag itself (see bin/ubx-snap-resolve's header,
# "_unverifiedPublisherAllowed" is not part of the persisted schema), the
# best this test can assert is that bin/ubx-snap-resolve's own emission
# already enforced it once (schema conformance above) and that the
# committed declaration for a currently-unverified pinned snap explicitly
# opts in one of the two ways -- for the small hello-world fixture this
# project ships today, publisherVerified is expected to be true outright.
unverified_pinned = [s["name"] for s in lock["snaps"] if not s["publisherVerified"]]
for name in unverified_pinned:
    entry = decl["snaps"].get(name, {})
    if not (entry.get("unverifiedPublisher") or decl.get("allowUnverifiedPublishers")):
        print(
            f"FAIL: {lock_path} pins {name!r} with an unverified publisher, but "
            f"neither {decl_path}'s per-snap unverifiedPublisher nor its "
            "allowUnverifiedPublishers currently opts in (a stale/hand-edited "
            "lockfile, or a declaration edited after the fact)",
            file=sys.stderr,
        )
        sys.exit(1)

print(
    f"OK: all {len(declared)} declared snap(s) are pinned in {lock_path} "
    f"({len(pinned)} pinned total), and every unverified-publisher entry "
    "(if any) is a declared, reviewable opt-in"
)
PYEOF
rc=$?
[ "$rc" -eq 0 ] || fail "declared/pinned cross-check failed (see stderr above)"

exit "$fails"
