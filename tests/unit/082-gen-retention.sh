#!/usr/bin/env bash
# tests/unit/082-gen-retention.sh — bin/ubx-generations `prune-plan`:
# retention decisions (SPEC.md §4.3; GitHub issue #25, milestone M2).
#
# SPEC.md §4.3 / this project's "ubuntnix.generations.retain" rule: keep
# the newest N generations, PLUS booted and previous always, regardless of
# N (default N=5) — retain also accepts "all". These are pure planning
# decisions; nothing is deleted here (prune-plan only prints numbers).
set -u
cd "$UBX_REPO_ROOT" || exit 1

gen="$UBX_REPO_ROOT/bin/ubx-generations"
[ -x "$gen" ] || { echo "FAIL: $gen does not exist or is not executable" >&2; exit 1; }

fails=0
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317  # invoked indirectly via 'trap cleanup EXIT' below;
# a false positive in shellcheck 0.11's reachability analysis when a later
# helper function also mutates a variable read by a trailing 'exit "$var"'.
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

root="$work/gens"

create_gen() {
  "$gen" create --root "$root" --rootfs-image /store/rootfs --kernel /store/kernel \
    --initrd /store/initrd --root-device /dev/sda1
}

# six generations, 1..6
for i in 1 2 3 4 5 6; do
  got="$(create_gen)" || fail "create #$i failed"
  [ "$got" = "$i" ] || fail "expected generation $i, got $got"
done

assert_dropped() { # LABEL EXPECTED_SORTED_LINES... -- ACTUAL_ARGS...
  local label="$1"; shift
  local expected="$1"; shift
  local actual
  actual="$("$@" | sort -n | paste -sd, -)"
  [ "$actual" = "$expected" ] || fail "$label: expected dropped=[$expected], got=[$actual]"
}

# --- default-shaped: retain 5, booted = newest (6) -----------------------
# newest 5 = {2,3,4,5,6}; booted=6 (already inside); dropped = {1}.
assert_dropped "retain=5 booted=6" "1" \
  "$gen" prune-plan --root "$root" --retain 5 --booted 6

# --- booted OLDER than the retention window still gets exempted ----------
# This is the exact scenario the script's header documents as the reason
# a persistent counter (not max(existing)+1) and a by-number (not by-
# recency) exemption are both needed: a machine rolled back to an old
# generation while newer, never-booted generations exist.
# newest 2 = {5,6}; booted=1 union; previous=6 union (redundant) ->
# retained = {1,5,6}; dropped = {2,3,4}.
assert_dropped "retain=2 booted=1 previous=6" "2,3,4" \
  "$gen" prune-plan --root "$root" --retain 2 --booted 1 --previous 6

# --- retain=0 still keeps booted+previous, nothing else ------------------
assert_dropped "retain=0 booted=3 previous=4" "1,2,5,6" \
  "$gen" prune-plan --root "$root" --retain 0 --booted 3 --previous 4

# --- retain=all keeps everything, always ---------------------------------
out="$("$gen" prune-plan --root "$root" --retain all --booted 1)"
rc=$?
[ "$rc" -eq 0 ] || fail "retain=all should exit 0"
[ -z "$out" ] || fail "retain=all should drop nothing, got: $out"

# --- previous is optional (only one generation ever existed scenario) ---
assert_dropped "retain=1 booted=6, no previous" "1,2,3,4,5" \
  "$gen" prune-plan --root "$root" --retain 1 --booted 6

# --- validation: --retain is required ------------------------------------
out="$("$gen" prune-plan --root "$root" --booted 6 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "prune-plan without --retain should fail"

# --- validation: --booted is required ------------------------------------
out="$("$gen" prune-plan --root "$root" --retain 5 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "prune-plan without --booted should fail"

# --- validation: --retain must be a count or 'all' -----------------------
out="$("$gen" prune-plan --root "$root" --retain banana --booted 6 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "prune-plan with a non-numeric, non-'all' --retain should fail"

# --- validation: --booted must name a real generation --------------------
out="$("$gen" prune-plan --root "$root" --retain 5 --booted 999 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "prune-plan with a nonexistent --booted should fail"

# --- validation: --previous, when given, must name a real generation -----
out="$("$gen" prune-plan --root "$root" --retain 5 --booted 6 --previous 999 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "prune-plan with a nonexistent --previous should fail"

exit "$fails"
