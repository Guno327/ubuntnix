#!/usr/bin/env bash
# tests/unit/080-gen-numbering.sh — bin/ubx-generations `create`: generation
# numbering/allocation and manifest field validation (SPEC.md §4.2; GitHub
# issue #25, milestone M2).
#
# Covers the header comment's central numbering claim: the persistent
# `.next-index` counter, NOT max(existing dirs)+1, is what decides the next
# number — the two agree in the common case but diverge once the
# highest-numbered generation is gone while the counter survives (the
# scenario a future GC (#29) can create; see the script's own "Numbering"
# section for why max(existing)+1 would silently reuse a number there).
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

create_gen() { # extra args...
  "$gen" create --root "$root" --rootfs-image /store/rootfs --kernel /store/kernel \
    --initrd /store/initrd --root-device /dev/sda1 "$@"
}

# --- plain allocation: 1, 2, 3 in order --------------------------------
g1="$(create_gen)" || fail "first create failed"
g2="$(create_gen)" || fail "second create failed"
g3="$(create_gen)" || fail "third create failed"
[ "$g1" = 1 ] || fail "first generation should be numbered 1, got: $g1"
[ "$g2" = 2 ] || fail "second generation should be numbered 2, got: $g2"
[ "$g3" = 3 ] || fail "third generation should be numbered 3, got: $g3"

[ -f "$root/.next-index" ] || fail "no persistent .next-index counter file after create"
next="$(cat "$root/.next-index" 2>/dev/null)"
[ "$next" = 4 ] || fail ".next-index should read 4 after three creates, got: $next"

# --- the counter-vs-max(existing)+1 divergence case --------------------
# Simulate a future GC (#29) having removed the highest-numbered generation
# (3) while a lower one (1, 2) survives. max(existing)+1 would now be 3
# again (reusing a number that already existed); the persistent counter
# must still hand out 4.
rm -rf "${root:?}/3"
g4="$(create_gen)" || fail "create after simulated GC of generation 3 failed"
[ "$g4" = 4 ] || fail "numbering must not reuse a number vacated by a deleted generation: expected 4, got $g4"

# --- existing_gens ignores non-manifest / non-numeric entries ----------
mkdir -p "$root/not-a-number"
mkdir -p "$root/99"   # directory with no manifest file: not a real generation
listed="$("$gen" list --root "$root" --porcelain | cut -f1)"
case "$listed" in
  *99*) fail "list must ignore a numeric directory with no manifest file" ;;
esac
case "$listed" in
  *not-a-number*) fail "list must ignore non-numeric directory entries" ;;
esac

# --- required fields ----------------------------------------------------
out="$("$gen" create --root "$work/missing-fields" --kernel /k --initrd /i --root-device /dev/sda1 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "create without --rootfs-image should fail"
case "$out" in
  *"--rootfs-image"*) ;;
  *) fail "missing --rootfs-image error should mention the flag, got: $out" ;;
esac

# --- single-line validation: TAB in a field must be rejected ------------
out="$(create_gen --kernel-params "$(printf 'a\tb')" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "create should reject a TAB embedded in --kernel-params"
case "$out" in
  *"TAB"*) ;;
  *) fail "TAB-rejection error should mention TAB, got: $out" ;;
esac

# --- --created override (reproducible-timestamp testing hook) ----------
g5="$("$gen" create --root "$root" --rootfs-image /store/r5 --kernel /store/k5 \
  --initrd /store/i5 --root-device /dev/sda1 --created "2026-01-01T00:00:00Z")" || fail "create with --created failed"
mf="$root/$g5/manifest"
grep -q '^GEN_CREATED=2026-01-01T00:00:00Z$' "$mf" || fail "--created override was not honored in the manifest"

# --- --stdin fields, flags win over stdin -------------------------------
g6="$(printf 'GEN_TITLE=from-stdin\nGEN_KERNEL_PARAMS=stdin-params\n' | \
  "$gen" create --root "$root" --stdin --rootfs-image /store/r6 --kernel /store/k6 \
    --initrd /store/i6 --root-device /dev/sda1 --title "from-flag")" || fail "create --stdin failed"
mf="$root/$g6/manifest"
grep -q '^GEN_TITLE=from-flag$' "$mf" || fail "a flag value should win over the same field supplied on --stdin"
grep -q '^GEN_KERNEL_PARAMS=stdin-params$' "$mf" || fail "an stdin-only field should be applied when no flag set it"

exit "$fails"
