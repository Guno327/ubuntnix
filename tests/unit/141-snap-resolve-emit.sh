#!/usr/bin/env bash
# tests/unit/141-snap-resolve-emit.sh — bin/ubx-snap-resolve's lockfile
# emission: schema conformance, stable (sort-by-name) ordering,
# byte-stable/idempotent formatting, and the verified-publisher policy
# (SPEC.md §4.3, §4.4, §4.5, §5; GitHub issue #60, milestone M3).
#
# Exercises `bin/ubx-snap-resolve --emit-lockfile FILE`, the pure (no
# network, no snap client) half of resolution: it takes an already-resolved
# JSON array of snap tuples and runs them through the exact
# validate/policy/sort/format logic real resolution uses (see
# bin/ubx-snap-resolve's header for why this is factored out as a separate,
# directly-testable step, mirroring bin/ubx-resolve's own --emit-lockfile).
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

resolve="$UBX_REPO_ROOT/bin/ubx-snap-resolve"
[ -x "$resolve" ] || {
  echo "FAIL: $resolve does not exist or is not executable" >&2
  exit 1
}
validator="$UBX_REPO_ROOT/tests/lib/validate-snap-lockfile.py"
[ -f "$validator" ] || {
  echo "FAIL: $validator does not exist" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

sha_a="$(python3 -c "import hashlib;print(hashlib.sha256(b'a').hexdigest())")"
sha_b="$(python3 -c "import hashlib;print(hashlib.sha256(b'b').hexdigest())")"
sha_c="$(python3 -c "import hashlib;print(hashlib.sha256(b'c').hexdigest())")"
sha_d="$(python3 -c "import hashlib;print(hashlib.sha256(b'd').hexdigest())")"

# A small, deliberately UNSORTED fixture of resolved snap tuples. One entry
# carries an extra field that must be dropped on emission, not carried
# through verbatim.
fixture="$work/resolved.json"
cat > "$fixture" <<EOF
[
  {
    "name": "zzz-snap", "channel": "stable", "revision": 5, "classic": false,
    "publisher": "canonical", "publisherVerified": true,
    "snap": {"url": "https://x/zzz.snap", "sha256": "$sha_a", "size": 100},
    "assert": {"url": "https://x/zzz.assert", "sha256": "$sha_b"},
    "connections": [], "config": {},
    "not_part_of_the_schema": "must be dropped on emission"
  },
  {
    "name": "hello-world", "channel": "stable", "revision": 29, "classic": false,
    "publisher": "Canonical", "publisherVerified": true,
    "snap": {"url": "https://x/hw.snap", "sha256": "$sha_c", "size": 20480},
    "assert": {"url": "https://x/hw.assert", "sha256": "$sha_d"},
    "connections": ["network"], "config": {"foo": "bar"}
  }
]
EOF

out1="$work/out1.json"
out2="$work/out2.json"

emit_out="$("$resolve" --emit-lockfile "$fixture" --out "$out1" 2>&1)"
emit_rc=$?
[ "$emit_rc" -eq 0 ] || fail "emitting from a valid fixture should exit 0 (rc=$emit_rc, output: $emit_out)"
[ -f "$out1" ] || fail "--emit-lockfile did not write $out1"

# -- schema conformance -------------------------------------------------
if [ -f "$out1" ]; then
  schema_out="$(python3 "$validator" "$out1" 2>&1)"
  schema_rc=$?
  [ "$schema_rc" -eq 0 ] || fail "emitted lockfile failed schema validation: $schema_out"
fi

# -- stable ordering: sorted by name regardless of fixture order -----------
if [ -f "$out1" ]; then
  order_check="$(python3 - "$out1" <<'PYEOF'
import json
import sys

data = json.load(open(sys.argv[1]))
names = [s["name"] for s in data["snaps"]]
if names != sorted(names):
    print(f"not sorted by name: {names}")
    sys.exit(1)
if names != ["hello-world", "zzz-snap"]:
    print(f"unexpected snap set: {names}")
    sys.exit(1)
PYEOF
)"
  order_rc=$?
  [ "$order_rc" -eq 0 ] || fail "snap ordering check failed: $order_check"
fi

# -- extraneous input fields must not leak into the emitted schema ---------
if [ -f "$out1" ]; then
  fields_check="$(python3 - "$out1" <<'PYEOF'
import json
import sys

data = json.load(open(sys.argv[1]))
want = {"name", "channel", "revision", "classic", "publisher", "publisherVerified", "connections", "config", "snap", "assert"}
for s in data["snaps"]:
    if set(s.keys()) != want:
        print(f"unexpected field set for {s.get('name')!r}: {sorted(s.keys())}")
        sys.exit(1)
PYEOF
)"
  fields_rc=$?
  [ "$fields_rc" -eq 0 ] || fail "emitted snap fields check failed: $fields_check"
fi

# -- idempotence: re-running against the SAME fixture produces a
# byte-identical file -------------------------------------------------------
"$resolve" --emit-lockfile "$fixture" --out "$out2" > /dev/null
if [ -f "$out1" ] && [ -f "$out2" ]; then
  if ! diff -u "$out1" "$out2" > "$work/diff.txt"; then
    fail "two --emit-lockfile runs against unchanged inputs are not byte-identical:
$(cat "$work/diff.txt")"
  fi
fi

# Reversing the fixture's array order must produce the identical output too.
reversed_fixture="$work/resolved-reversed.json"
python3 -c "
import json
data = json.load(open('$fixture'))
json.dump(list(reversed(data)), open('$reversed_fixture', 'w'))
"
out3="$work/out3.json"
"$resolve" --emit-lockfile "$reversed_fixture" --out "$out3" > /dev/null
if [ -f "$out1" ] && [ -f "$out3" ]; then
  diff -q "$out1" "$out3" > /dev/null 2>&1 ||
    fail "emission is not independent of input array order (reversing the fixture changed the output)"
fi

# -- rejection paths: bad resolved data must fail loudly, and must NOT
# leave a partial/corrupt file at --out --------------------------------------
reject() {
  local desc="$1" json="$2" want_stderr="$3"
  local f="$work/bad.json" out="$work/bad-out.json"
  rm -f "$out"
  printf '%s' "$json" > "$f"
  local err rc
  err="$("$resolve" --emit-lockfile "$f" --out "$out" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] || fail "$desc: expected nonzero exit, got 0"
  case "$err" in
    *"$want_stderr"*) ;;
    *) fail "$desc: expected error to mention '$want_stderr', got: $err" ;;
  esac
  [ ! -e "$out" ] || fail "$desc: --out was written despite a validation failure (no partial-write guarantee)"
}

base='"name":"x","channel":"stable","classic":false,"publisher":"canonical","publisherVerified":true,"connections":[],"config":{}'

reject "empty array" '[]' "non-empty JSON array"
reject "missing field" \
  "[{\"name\":\"x\",\"channel\":\"stable\",\"classic\":false,\"publisher\":\"canonical\",\"publisherVerified\":true}]" \
  "missing required field"
reject "duplicate name" \
  "[{$base,\"revision\":1,\"snap\":{\"url\":\"https://x/a\",\"sha256\":\"$sha_a\",\"size\":1},\"assert\":{\"url\":\"https://x/a.a\",\"sha256\":\"$sha_b\"}},{$base,\"revision\":2,\"snap\":{\"url\":\"https://x/b\",\"sha256\":\"$sha_a\",\"size\":1},\"assert\":{\"url\":\"https://x/b.a\",\"sha256\":\"$sha_b\"}}]" \
  "duplicate snap name"
reject "malformed snap.sha256" \
  "[{$base,\"revision\":1,\"snap\":{\"url\":\"https://x/a\",\"sha256\":\"not-a-hash\",\"size\":1},\"assert\":{\"url\":\"https://x/a.a\",\"sha256\":\"$sha_b\"}}]" \
  "snap.sha256"
reject "malformed assert.sha256" \
  "[{$base,\"revision\":1,\"snap\":{\"url\":\"https://x/a\",\"sha256\":\"$sha_a\",\"size\":1},\"assert\":{\"url\":\"https://x/a.a\",\"sha256\":\"not-a-hash\"}}]" \
  "assert.sha256"
reject "non-positive revision" \
  "[{$base,\"revision\":0,\"snap\":{\"url\":\"https://x/a\",\"sha256\":\"$sha_a\",\"size\":1},\"assert\":{\"url\":\"https://x/a.a\",\"sha256\":\"$sha_b\"}}]" \
  "invalid revision"
reject "non-positive size" \
  "[{$base,\"revision\":1,\"snap\":{\"url\":\"https://x/a\",\"sha256\":\"$sha_a\",\"size\":0},\"assert\":{\"url\":\"https://x/a.a\",\"sha256\":\"$sha_b\"}}]" \
  "snap.size"

# -- the verified-publisher policy (SPEC.md §4.5/§5) -------------------------
unverified_no_optin="[{\"name\":\"randostuff\",\"channel\":\"stable\",\"revision\":1,\"classic\":false,\"publisher\":\"randodev\",\"publisherVerified\":false,\"connections\":[],\"config\":{},\"snap\":{\"url\":\"https://x/a\",\"sha256\":\"$sha_a\",\"size\":1},\"assert\":{\"url\":\"https://x/a.a\",\"sha256\":\"$sha_b\"}}]"
reject "unverified publisher, no opt-in anywhere" "$unverified_no_optin" "is not verified"

# Per-entry opt-in (_unverifiedPublisherAllowed, the internal field
# build_resolved computes from the declared unverifiedPublisher OR
# allowUnverifiedPublishers -- see this script's header) must let an
# otherwise-identical unverified entry through.
unverified_optin="$work/unverified-optin.json"
printf '%s' "[{\"name\":\"randostuff\",\"channel\":\"stable\",\"revision\":1,\"classic\":false,\"publisher\":\"randodev\",\"publisherVerified\":false,\"connections\":[],\"config\":{},\"snap\":{\"url\":\"https://x/a\",\"sha256\":\"$sha_a\",\"size\":1},\"assert\":{\"url\":\"https://x/a.a\",\"sha256\":\"$sha_b\"},\"_unverifiedPublisherAllowed\":true}]" > "$unverified_optin"
optin_out="$work/optin-out.json"
optin_emit_out="$("$resolve" --emit-lockfile "$unverified_optin" --out "$optin_out" 2>&1)"
optin_rc=$?
[ "$optin_rc" -eq 0 ] || fail "an unverified publisher WITH the opt-in flag should be accepted (rc=$optin_rc, output: $optin_emit_out)"
[ -f "$optin_out" ] || fail "opted-in unverified-publisher emission did not write $optin_out"
if [ -f "$optin_out" ]; then
  case "$(cat "$optin_out")" in
    *"_unverifiedPublisherAllowed"*) fail "the internal _unverifiedPublisherAllowed field leaked into the persisted schema" ;;
    *) ;;
  esac
fi

exit "$fails"
