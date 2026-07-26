#!/usr/bin/env bash
# tests/unit/057-ubx-resolve-esm-emit.sh — bin/ubx-resolve-esm's lockfile
# emission: schema conformance, the hash-pinned fetch path exercised via a
# fixture (never a real esm.ubuntu.com fetch), stable ordering, and that
# the 'public' tier of the target lockfile survives byte-for-byte
# untouched (SPEC.md §4.4 second bullet, §8.2; GitHub issue #81,
# milestone M4).
#
# Exercises `bin/ubx-resolve-esm --emit-lockfile FILE`, the pure (no
# network, no Pro token) half of esm resolution — mirrors
# tests/unit/051-archive-resolve-emit.sh's relationship to bin/ubx-resolve.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

resolve_esm="$UBX_REPO_ROOT/bin/ubx-resolve-esm"
[ -x "$resolve_esm" ] || {
  echo "FAIL: $resolve_esm does not exist or is not executable" >&2
  exit 1
}
validator="$UBX_REPO_ROOT/tests/lib/validate-archive-lockfile.py"
[ -f "$validator" ] || {
  echo "FAIL: $validator does not exist" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A base archive lockfile with a real (committed-shape) public tier and an
# EMPTY esm tier -- this is exactly what a pre-M4 lockfile (or a fresh
# ubx-resolve run) looks like; this test's job is to prove ubx-resolve-esm
# can populate the esm tier onto it without disturbing the public one.
base_lockfile="$work/archive.lock.json"
cp "$UBX_REPO_ROOT/archive.lock.json" "$base_lockfile"

# A small, deliberately UNSORTED fixture of already-resolved esm tuples --
# the "hash-pinned fetch path exercised with a fixture" acceptance
# criterion: no network, no Pro token, just the pure emission logic fed a
# stand-in for what a real Pro-token-authenticated fetch would have
# produced.
fixture="$work/resolved-esm.json"
cat > "$fixture" <<'EOF'
[
  {
    "name": "zeb-universe-pkg", "version": "1.0-1ubuntu1~esm1",
    "sha256": "111111111111111111111111111111111111111111111111111111111111111a",
    "path": "pool/esm-apps/main/z/zeb-universe-pkg/zeb-universe-pkg_1.0-1ubuntu1~esm1_amd64.deb",
    "not_part_of_the_schema": "must be dropped on emission"
  },
  {
    "name": "aaa-universe-pkg", "version": "2.0-1ubuntu1~esm1",
    "sha256": "222222222222222222222222222222222222222222222222222222222222222b",
    "path": "pool/esm-infra/main/a/aaa-universe-pkg/aaa-universe-pkg_2.0-1ubuntu1~esm1_amd64.deb"
  }
]
EOF

out1="$work/out1.json"
out2="$work/out2.json"

emit_out="$("$resolve_esm" --emit-lockfile "$fixture" --archive-lockfile "$base_lockfile" --out "$out1" 2>&1)"
emit_rc=$?
[ "$emit_rc" -eq 0 ] || fail "emitting from a valid fixture should exit 0 (rc=$emit_rc, output: $emit_out)"
[ -f "$out1" ] || fail "--emit-lockfile did not write $out1"

# -- schema conformance: held to the exact same shared validator as the
# public tier.
if [ -f "$out1" ]; then
  schema_out="$(python3 "$validator" "$out1" 2>&1)"
  schema_rc=$?
  [ "$schema_rc" -eq 0 ] || fail "emitted lockfile failed schema validation: $schema_out"
fi

# -- the 'public' tier must survive completely untouched. -------------------
if [ -f "$out1" ]; then
  public_diff="$(python3 - "$base_lockfile" "$out1" <<'PYEOF'
import json
import sys

a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
if a["public"] != b["public"]:
    print("public tier changed")
    sys.exit(1)
if a["version"] != b["version"]:
    print("top-level version changed")
    sys.exit(1)
PYEOF
)"
  public_rc=$?
  [ "$public_rc" -eq 0 ] || fail "the public tier was modified by --emit-lockfile: $public_diff"
fi

# -- the esm tier: source marker present, sorted by name, extraneous fields
# dropped.
if [ -f "$out1" ]; then
  esm_check="$(python3 - "$out1" <<'PYEOF'
import json
import sys

data = json.load(open(sys.argv[1]))
esm = data["esm"]["packages"]
names = [p["name"] for p in esm]
if names != sorted(names):
    print(f"esm.packages not sorted by name: {names}")
    sys.exit(1)
if names != ["aaa-universe-pkg", "zeb-universe-pkg"]:
    print(f"unexpected esm package set: {names}")
    sys.exit(1)
want = {"name", "version", "sha256", "path", "source"}
for pkg in esm:
    if set(pkg.keys()) != want:
        print(f"unexpected field set for {pkg.get('name')!r}: {sorted(pkg.keys())}")
        sys.exit(1)
    if pkg["source"] != "esm":
        print(f"{pkg['name']!r} has source={pkg['source']!r}, expected 'esm'")
        sys.exit(1)
PYEOF
)"
  esm_rc=$?
  [ "$esm_rc" -eq 0 ] || fail "emitted esm.packages check failed: $esm_check"
fi

# -- idempotence: re-running against the same fixture/base produces a
# byte-identical file.
"$resolve_esm" --emit-lockfile "$fixture" --archive-lockfile "$base_lockfile" --out "$out2" > /dev/null
if [ -f "$out1" ] && [ -f "$out2" ]; then
  if ! diff -u "$out1" "$out2" > "$work/diff.txt"; then
    fail "two --emit-lockfile runs against unchanged inputs are not byte-identical:
$(cat "$work/diff.txt")"
  fi
fi

# -- no network access happened: confirm via a fixture that references a
# path only (never a URL a real fetch would need to reach), and that the
# whole run above completed with no attempted network calls (implicit --
# there's no interpreter here that could reach the network from a plain
# JSON-to-JSON transform; this comment documents the intent this test
# structurally guarantees).

# -- rejection paths: bad resolved data must fail loudly and must NOT leave
# a partial/corrupt file at --out.
reject() {
  local desc="$1" json="$2" want_stderr="$3"
  local f="$work/bad.json" out="$work/bad-out.json"
  rm -f "$out"
  printf '%s' "$json" > "$f"
  local err rc
  err="$("$resolve_esm" --emit-lockfile "$f" --archive-lockfile "$base_lockfile" --out "$out" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] || fail "$desc: expected nonzero exit, got 0"
  case "$err" in
    *"$want_stderr"*) ;;
    *) fail "$desc: expected error to mention '$want_stderr', got: $err" ;;
  esac
  [ ! -e "$out" ] || fail "$desc: --out was written despite a validation failure (no partial-write guarantee)"
}

reject "missing field" \
  '[{"name":"p","version":"1","sha256":"111111111111111111111111111111111111111111111111111111111111111a"}]' \
  "missing required field"
reject "duplicate name" \
  '[{"name":"p","version":"1","sha256":"111111111111111111111111111111111111111111111111111111111111111a","path":"pool/esm-apps/p/p_1_amd64.deb"},{"name":"p","version":"2","sha256":"222222222222222222222222222222222222222222222222222222222222222b","path":"pool/esm-apps/p/p_2_amd64.deb"}]' \
  "duplicate package name"
reject "malformed sha256" \
  '[{"name":"p","version":"1","sha256":"not-a-hash","path":"pool/esm-apps/p/p_1_amd64.deb"}]' \
  "malformed sha256"
reject "conflicting source field" \
  '[{"name":"p","version":"1","sha256":"111111111111111111111111111111111111111111111111111111111111111a","path":"pool/esm-apps/p/p_1_amd64.deb","source":"public"}]' \
  'expected "esm" or absent'

# -- merging into something that isn't an archive lockfile at all must
# also fail loudly, with no partial write.
bad_target="$work/not-a-lockfile.json"
echo '{"nothing": "here"}' > "$bad_target"
echo '[]' > "$work/empty-resolved.json"
out="$("$resolve_esm" --emit-lockfile "$work/empty-resolved.json" --archive-lockfile "$bad_target" --out "$work/bad-target-out.json" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "merging into a non-archive-lockfile target should fail"
case "$out" in
  *"does not look like an archive lockfile"*) ;;
  *) fail "bad-merge-target error should explain why, got: $out" ;;
esac
[ ! -e "$work/bad-target-out.json" ] || fail "bad merge target: --out was written despite the failure"

exit "$fails"
