#!/usr/bin/env bash
# tests/unit/140-snap-declaration.sh — declared snap set
# (snaps.packages.json), parsing/validation (SPEC.md §4.3, §4.5, §6;
# GitHub issue #60, milestone M3: "declared snaps -> snap lockfile").
#
# Exercises `bin/ubx-snap-resolve --check-declaration`, which runs no
# network and no snap client (pure parse + schema validation of the
# committed declaration file), against both the real committed
# snaps.packages.json and a set of fixture files covering every rejection
# path. No network access happens here (tests/README.md's "unit tests must
# not require root, network, or KVM" rule).
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

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# -- the real, committed declaration file must itself validate -------------
declfile="snaps.packages.json"
[ -f "$declfile" ] || fail "$declfile does not exist"
if [ -f "$declfile" ]; then
  out="$("$resolve" --check-declaration --declaration "$declfile" 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] || fail "--check-declaration rejected the committed $declfile (rc=$rc): $out"
fi

check() {
  local desc="$1" decl="$2" want_rc="$3" want_stderr="${4:-}"
  local f="$work/decl.json"
  printf '%s' "$decl" > "$f"
  local out rc
  out="$("$resolve" --check-declaration --declaration "$f" 2>&1)"
  rc=$?
  [ "$rc" -eq "$want_rc" ] || {
    fail "$desc: expected exit $want_rc, got $rc (output: $out)"
    return
  }
  if [ -n "$want_stderr" ]; then
    case "$out" in
      *"$want_stderr"*) ;;
      *) fail "$desc: expected output to mention '$want_stderr', got: $out" ;;
    esac
  fi
}

check "valid, minimal" \
  '{"snaps":{"hello-world":{"channel":"stable"}}}' \
  0

check "valid, all fields set" \
  '{"allowUnverifiedPublishers":true,"snaps":{"hello-world":{"channel":"latest/edge","revision":27,"classic":true,"connections":["network","home"],"config":{"foo":"bar","nested.key":1},"unverifiedPublisher":true}}}' \
  0

check "not valid JSON" \
  '{not json' \
  1 "not valid JSON"

check "top level not an object" \
  '["hello-world"]' \
  1 "not a JSON object"

check "missing snaps" \
  '{}' \
  1 "'snaps' must be a non-empty object"

check "empty snaps" \
  '{"snaps":{}}' \
  1 "'snaps' must be a non-empty object"

check "snaps not an object" \
  '{"snaps":["hello-world"]}' \
  1 "'snaps' must be a non-empty object"

check "invalid snap name (uppercase)" \
  '{"snaps":{"Hello-World":{"channel":"stable"}}}' \
  1 "not a valid snap name"

check "invalid snap name (leading hyphen)" \
  '{"snaps":{"-hello":{"channel":"stable"}}}' \
  1 "not a valid snap name"

check "invalid snap name (doubled hyphen)" \
  '{"snaps":{"hello--world":{"channel":"stable"}}}' \
  1 "not a valid snap name"

check "invalid snap name (all digits)" \
  '{"snaps":{"12345":{"channel":"stable"}}}' \
  1 "not a valid snap name"

check "missing channel" \
  '{"snaps":{"hello-world":{}}}' \
  1 "channel must match"

check "invalid channel" \
  '{"snaps":{"hello-world":{"channel":"not-a-real-risk"}}}' \
  1 "channel must match"

check "invalid channel (bad risk with track)" \
  '{"snaps":{"hello-world":{"channel":"latest/wobbly"}}}' \
  1 "channel must match"

check "classic not a boolean" \
  '{"snaps":{"hello-world":{"channel":"stable","classic":"yes"}}}' \
  1 "classic must be a boolean"

check "connections not a list" \
  '{"snaps":{"hello-world":{"channel":"stable","connections":"network"}}}' \
  1 "connections must be a list"

check "connections has an invalid interface name" \
  '{"snaps":{"hello-world":{"channel":"stable","connections":["Not_Valid"]}}}' \
  1 "not a valid interface name"

check "config not an object" \
  '{"snaps":{"hello-world":{"channel":"stable","config":"nope"}}}' \
  1 "config must be an object"

check "config has an invalid key" \
  '{"snaps":{"hello-world":{"channel":"stable","config":{"Bad Key":"x"}}}}' \
  1 "invalid key"

check "unverifiedPublisher not a boolean" \
  '{"snaps":{"hello-world":{"channel":"stable","unverifiedPublisher":"nope"}}}' \
  1 "unverifiedPublisher must be a boolean"

check "allowUnverifiedPublishers not a boolean" \
  '{"allowUnverifiedPublishers":"nope","snaps":{"hello-world":{"channel":"stable"}}}' \
  1 "allowUnverifiedPublishers"

check "revision not an integer" \
  '{"snaps":{"hello-world":{"channel":"stable","revision":"27"}}}' \
  1 "revision must be null or a positive integer"

check "revision non-positive" \
  '{"snaps":{"hello-world":{"channel":"stable","revision":0}}}' \
  1 "revision must be null or a positive integer"

# All violations in one run must be reported together (mirrors
# bin/ubx-resolve's own validate_declaration / nix's `validate` functions:
# one report enumerating every problem, not just the first).
multi_decl="$work/multi.json"
printf '%s' '{"allowUnverifiedPublishers":"nope","snaps":{"Bad-Name":{"channel":"nonsense"}}}' > "$multi_decl"
multi_out="$("$resolve" --check-declaration --declaration "$multi_decl" 2>&1)"
for want in "allowUnverifiedPublishers" "not a valid snap name" "channel must match"; do
  case "$multi_out" in
    *"$want"*) ;;
    *) fail "multi-violation report missing '$want' (got: $multi_out)" ;;
  esac
done

# -- nonexistent declaration file --------------------------------------------
out="$("$resolve" --check-declaration --declaration "$work/does-not-exist.json" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "--check-declaration on a nonexistent file should fail"
case "$out" in
  *"does not exist"*) ;;
  *) fail "nonexistent-file error should mention 'does not exist', got: $out" ;;
esac

exit "$fails"
