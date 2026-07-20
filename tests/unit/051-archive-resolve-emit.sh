#!/usr/bin/env bash
# tests/unit/051-archive-resolve-emit.sh — bin/ubx-resolve's lockfile
# emission: schema conformance, stable (sort-by-name) ordering, and
# byte-stable formatting/idempotence (SPEC.md §4.4; GitHub issue #8,
# milestone M1 acceptance criterion: "re-running with unchanged inputs
# emits a byte-identical file").
#
# Exercises `bin/ubx-resolve --emit-lockfile FILE`, the pure (no network,
# no apt) half of resolution: it takes an already-resolved JSON array of
# package tuples and runs them through the exact validate/sort/format logic
# real resolution uses (see bin/ubx-resolve's header for why this is
# factored out as a separate, directly-testable step). The apt-solver half
# that PRODUCES such an array from a live snapshot is exercised end-to-end
# only in CI's "resolve" job (.github/workflows/ci.yml) — no network here
# (tests/README.md's "unit tests must not require root, network, or KVM"
# rule).
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

resolve="$UBX_REPO_ROOT/bin/ubx-resolve"
[ -x "$resolve" ] || {
  echo "FAIL: $resolve does not exist or is not executable" >&2
  exit 1
}
validator="$UBX_REPO_ROOT/tests/lib/validate-archive-lockfile.py"
[ -f "$validator" ] || {
  echo "FAIL: $validator does not exist" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A small, deliberately UNSORTED fixture of resolved package tuples (real
# sha256/size values, lifted from the committed archive.lock.json, so a
# schema/format regression here is caught the same way it would be against
# real data). One entry (zlib1g) carries an extra field that must be
# dropped on emission, not carried through verbatim.
fixture="$work/resolved.json"
cat > "$fixture" <<'EOF'
[
  {
    "name": "zlib1g", "version": "1:1.3.dfsg-3.1ubuntu2", "arch": "amd64",
    "component": "main",
    "path": "pool/main/z/zlib/zlib1g_1.3.dfsg-3.1ubuntu2_amd64.deb",
    "sha256": "0b93d16d7498f092fa3070fbbad28cdbc6b3d640f1a7681b96fc37f20d1219f1",
    "size": 62784,
    "not_part_of_the_schema": "must be dropped on emission"
  },
  {
    "name": "ed", "version": "1.20.1-1", "arch": "amd64",
    "component": "main", "path": "pool/main/e/ed/ed_1.20.1-1_amd64.deb",
    "sha256": "c26e577a24cc784d678b0b2b960db8a154fb7138fc1aa7ad1ffe504698432a43",
    "size": 56062
  },
  {
    "name": "htop", "version": "3.3.0-4build1", "arch": "amd64",
    "component": "universe",
    "path": "pool/universe/h/htop/htop_3.3.0-4build1_amd64.deb",
    "sha256": "ee0e9cffc789788164214bac9b6e285a5127c07be1815129875c6c538ba849c6",
    "size": 170528
  }
]
EOF

out1="$work/out1.json"
out2="$work/out2.json"

emit_out="$("$resolve" --emit-lockfile "$fixture" --snapshot 20260715T000000Z --series noble --out "$out1" 2>&1)"
emit_rc=$?
[ "$emit_rc" -eq 0 ] || fail "emitting from a valid fixture should exit 0 (rc=$emit_rc, output: $emit_out)"
[ -f "$out1" ] || fail "--emit-lockfile did not write $out1"

# -- schema conformance: held to the exact same shared validator
# nix/archive.nix's schema and tests/unit/040 hold the committed
# archive.lock.json to.
if [ -f "$out1" ]; then
  schema_out="$(python3 "$validator" "$out1" 2>&1)"
  schema_rc=$?
  [ "$schema_rc" -eq 0 ] || fail "emitted lockfile failed schema validation: $schema_out"
fi

# -- stable ordering: packages sorted by name regardless of fixture order --
if [ -f "$out1" ]; then
  order_check="$(python3 - "$out1" <<'PYEOF'
import json
import sys

data = json.load(open(sys.argv[1]))
names = [p["name"] for p in data["public"]["packages"]]
if names != sorted(names):
    print(f"not sorted by name: {names}")
    sys.exit(1)
if names != ["ed", "htop", "zlib1g"]:
    print(f"unexpected package set: {names}")
    sys.exit(1)
PYEOF
)"
  order_rc=$?
  [ "$order_rc" -eq 0 ] || fail "package ordering check failed: $order_check"
fi

# -- extraneous input fields must not leak into the emitted schema ---------
if [ -f "$out1" ]; then
  fields_check="$(python3 - "$out1" <<'PYEOF'
import json
import sys

data = json.load(open(sys.argv[1]))
want = {"name", "version", "arch", "component", "path", "sha256", "size"}
for pkg in data["public"]["packages"]:
    if set(pkg.keys()) != want:
        print(f"unexpected field set for {pkg.get('name')!r}: {sorted(pkg.keys())}")
        sys.exit(1)
PYEOF
)"
  fields_rc=$?
  [ "$fields_rc" -eq 0 ] || fail "emitted package fields check failed: $fields_check"
fi

# -- idempotence: re-running --emit-lockfile against the SAME fixture and
# SAME --snapshot/--series produces a byte-identical file (the issue's
# explicit acceptance criterion). This is the pure-logic half of that
# criterion; CI's "resolve" job proves the same property end-to-end
# through a real, live apt solve.
"$resolve" --emit-lockfile "$fixture" --snapshot 20260715T000000Z --series noble --out "$out2" > /dev/null
if [ -f "$out1" ] && [ -f "$out2" ]; then
  if ! diff -u "$out1" "$out2" > "$work/diff.txt"; then
    fail "two --emit-lockfile runs against unchanged inputs are not byte-identical:
$(cat "$work/diff.txt")"
  fi
fi

# Re-running against the fixture with its package ARRAY ORDER reversed
# must produce the identical output too -- sort order comes from the data
# (package name), never from input order.
reversed_fixture="$work/resolved-reversed.json"
python3 -c "
import json
data = json.load(open('$fixture'))
json.dump(list(reversed(data)), open('$reversed_fixture', 'w'))
"
out3="$work/out3.json"
"$resolve" --emit-lockfile "$reversed_fixture" --snapshot 20260715T000000Z --series noble --out "$out3" > /dev/null
if [ -f "$out1" ] && [ -f "$out3" ]; then
  diff -q "$out1" "$out3" > /dev/null 2>&1 ||
    fail "emission is not independent of input array order (reversing the fixture changed the output)"
fi

# -- rejection paths: bad resolved data must fail loudly, and must NOT
# leave a partial/corrupt file at --out.
reject() {
  local desc="$1" json="$2" want_stderr="$3"
  local f="$work/bad.json" out="$work/bad-out.json"
  rm -f "$out"
  printf '%s' "$json" > "$f"
  local err rc
  err="$("$resolve" --emit-lockfile "$f" --snapshot 20260715T000000Z --series noble --out "$out" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] || fail "$desc: expected nonzero exit, got 0"
  case "$err" in
    *"$want_stderr"*) ;;
    *) fail "$desc: expected error to mention '$want_stderr', got: $err" ;;
  esac
  [ ! -e "$out" ] || fail "$desc: --out was written despite a validation failure (no partial-write guarantee)"
}

reject "empty array" '[]' "non-empty JSON array"
reject "missing field" \
  '[{"name":"ed","version":"1.20.1-1","arch":"amd64","component":"main","path":"pool/main/e/ed/ed_1.20.1-1_amd64.deb","sha256":"c26e577a24cc784d678b0b2b960db8a154fb7138fc1aa7ad1ffe504698432a43"}]' \
  "missing required field"
reject "duplicate name" \
  '[{"name":"ed","version":"1.20.1-1","arch":"amd64","component":"main","path":"pool/main/e/ed/ed_1.20.1-1_amd64.deb","sha256":"c26e577a24cc784d678b0b2b960db8a154fb7138fc1aa7ad1ffe504698432a43","size":56062},{"name":"ed","version":"1.20.1-1","arch":"amd64","component":"main","path":"pool/main/e/ed/ed_1.20.1-1_amd64.deb","sha256":"c26e577a24cc784d678b0b2b960db8a154fb7138fc1aa7ad1ffe504698432a43","size":56062}]' \
  "duplicate package name"
reject "malformed sha256" \
  '[{"name":"ed","version":"1.20.1-1","arch":"amd64","component":"main","path":"pool/main/e/ed/ed_1.20.1-1_amd64.deb","sha256":"not-a-hash","size":56062}]' \
  "malformed sha256"
reject "non-positive size" \
  '[{"name":"ed","version":"1.20.1-1","arch":"amd64","component":"main","path":"pool/main/e/ed/ed_1.20.1-1_amd64.deb","sha256":"c26e577a24cc784d678b0b2b960db8a154fb7138fc1aa7ad1ffe504698432a43","size":0}]' \
  "invalid size"
reject "bad path (no pool/ prefix)" \
  '[{"name":"ed","version":"1.20.1-1","arch":"amd64","component":"main","path":"ed_1.20.1-1_amd64.deb","sha256":"c26e577a24cc784d678b0b2b960db8a154fb7138fc1aa7ad1ffe504698432a43","size":56062}]' \
  "invalid path"
reject "unsupported arch" \
  '[{"name":"ed","version":"1.20.1-1","arch":"arm64","component":"main","path":"pool/main/e/ed/ed_1.20.1-1_amd64.deb","sha256":"c26e577a24cc784d678b0b2b960db8a154fb7138fc1aa7ad1ffe504698432a43","size":56062}]' \
  "unsupported arch"
reject "unsupported component" \
  '[{"name":"ed","version":"1.20.1-1","arch":"amd64","component":"nonfree","path":"pool/nonfree/e/ed/ed_1.20.1-1_amd64.deb","sha256":"c26e577a24cc784d678b0b2b960db8a154fb7138fc1aa7ad1ffe504698432a43","size":56062}]' \
  "unsupported component"

# -- bad snapshot/series arguments are rejected too -------------------------
bad_snap_rc=0
bad_snap_out="$("$resolve" --emit-lockfile "$fixture" --snapshot "not-a-timestamp" --series noble --out "$work/bad-snap.json" 2>&1)" || bad_snap_rc=$?
[ "$bad_snap_rc" -ne 0 ] || fail "an obviously malformed --snapshot should be rejected"
case "$bad_snap_out" in
  *"does not match"*) ;;
  *) fail "malformed --snapshot error should mention the expected pattern, got: $bad_snap_out" ;;
esac

exit "$fails"
