#!/usr/bin/env bash
# tests/unit/083-gen-gc-plan.sh — bin/ubx-generations `gc-plan`: store-path
# reference counting against a retention selection (SPEC.md §4.3, G4;
# GitHub issue #25, milestone M2).
#
# The offline-rollback guarantee (SPEC G4) is: a store artifact is
# collected only when NO retained generation references it — including
# when a generation that itself is being dropped shares an artifact
# (e.g. an unchanged kernel) with one that's retained. This file checks
# exactly that cross-referencing, plus that empty/unset manifest fields
# never show up as phantom references.
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

# gen1 and gen2 share a kernel/initrd (as if the kernel didn't change
# between them); gen1 alone has an etc-ref; gen3 has entirely its own set.
g1="$("$gen" create --root "$root" --rootfs-image /store/r1 --kernel /store/k-shared \
  --initrd /store/i-shared --root-device /dev/sda1 --etc-ref /store/etc1)" || fail "create gen1 failed"
g2="$("$gen" create --root "$root" --rootfs-image /store/r2 --kernel /store/k-shared \
  --initrd /store/i-shared --root-device /dev/sda1)" || fail "create gen2 failed"
g3="$("$gen" create --root "$root" --rootfs-image /store/r3 --kernel /store/k3 \
  --initrd /store/i3 --root-device /dev/sda1)" || fail "create gen3 failed"

status_of() { # OUTPUT PATH
  printf '%s\n' "$1" | awk -F'\t' -v p="$2" '$2==p{print $1; found=1} END{if(!found) print "MISSING"}'
}
referrers_of() { # OUTPUT PATH
  printf '%s\n' "$1" | awk -F'\t' -v p="$2" '$2==p{print $3; found=1} END{if(!found) print "MISSING"}'
}

# --- retain only the newest (g3): g1/g2's shared kernel/initrd must COLLECT ---
out="$("$gen" gc-plan --root "$root" --retain 1 --booted "$g3")" || fail "gc-plan --retain 1 failed"

[ "$(status_of "$out" /store/k-shared)" = COLLECT ] \
  || fail "a store path referenced only by dropped generations should be COLLECT"
[ "$(referrers_of "$out" /store/k-shared)" = "$g1,$g2" ] \
  || fail "shared kernel's referrers should be '$g1,$g2', got: $(referrers_of "$out" /store/k-shared)"

[ "$(status_of "$out" /store/r3)" = KEEP ] || fail "gen3's own rootfs image should be KEEP"
[ "$(status_of "$out" /store/etc1)" = COLLECT ] || fail "gen1's etc-ref should be COLLECT once gen1 is dropped"

# an unset field (gen2/gen3 leave --etc-ref empty) must never appear as a
# referenced path at all.
case "$out" in
  *$'\t\t'*) fail "an empty manifest field leaked through as a referenced (empty) path" ;;
esac
printf '%s\n' "$out" | awk -F'\t' '$2==""{found=1} END{exit !found}' \
  && fail "gc-plan must never emit a line with an empty PATH field"

# --- KEEP even though the specific REFERRING generation is dropped -------
# Explicit --select excludes gen1 but includes gen2 (both share the
# kernel/initrd): the shared artifact must still be KEEP, and its
# referrer list must still include gen1 (accurate bookkeeping — planning
# only, nothing is deleted), not just the retained ones.
out2="$("$gen" gc-plan --root "$root" --select "$g2,$g3")" || fail "gc-plan --select failed"
[ "$(status_of "$out2" /store/k-shared)" = KEEP ] \
  || fail "a path shared with a retained (selected) generation must KEEP even when its OTHER referrer is dropped"
[ "$(referrers_of "$out2" /store/k-shared)" = "$g1,$g2" ] \
  || fail "referrer list should list every referencing generation, retained or not"
[ "$(status_of "$out2" /store/r1)" = COLLECT ] \
  || fail "gen1's own unshared rootfs image should be COLLECT when gen1 is not selected"

# --- --select and --retain are mutually exclusive -------------------------
out="$("$gen" gc-plan --root "$root" --select "$g1" --retain 1 --booted "$g1" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "gc-plan with both --select and --retain should fail"

# --- one of --select or --retain is required ------------------------------
out="$("$gen" gc-plan --root "$root" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "gc-plan with neither --select nor --retain should fail"

# --- --booted must name a real generation when using --retain -------------
out="$("$gen" gc-plan --root "$root" --retain 1 --booted 999 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "gc-plan --retain with a nonexistent --booted should fail"

exit "$fails"
