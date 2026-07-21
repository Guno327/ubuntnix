#!/usr/bin/env bash
# tests/unit/081-gen-links.sh — bin/ubx-generations current/previous
# pointer maintenance and rollback-target resolution (SPEC.md §4.2, §4.3;
# GitHub issue #25, milestone M2).
#
# `current`/`previous` are this tooling's own bookkeeping pointers (see the
# script's header, "current vs. booted"): current := the generation the
# most recent `create` produced, previous := whatever current pointed at
# right before that. This file checks that bookkeeping only — it never
# claims these are "the booted generation".
set -u
cd "$UBX_REPO_ROOT" || exit 1

gen="$UBX_REPO_ROOT/bin/ubx-generations"
[ -x "$gen" ] || { echo "FAIL: $gen does not exist or is not executable" >&2; exit 1; }

fails=0
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

work="$(mktemp -d)"
# shellcheck disable=SC2329  # invoked indirectly via 'trap cleanup EXIT' below;
# a false positive in shellcheck 0.11's reachability analysis when a later
# helper function also mutates a variable read by a trailing 'exit "$var"'.
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

root="$work/gens"

create_gen() {
  "$gen" create --root "$root" --rootfs-image /store/rootfs --kernel /store/kernel \
    --initrd /store/initrd --root-device /dev/sda1
}

# --- no previous yet after the very first generation --------------------
g1="$(create_gen)" || fail "first create failed"
[ -L "$root/current" ] || fail "no 'current' symlink after the first create"
[ -e "$root/previous" ] && fail "'previous' should not exist yet after only one create"

cur="$(basename "$(readlink "$root/current")")"
[ "$cur" = "$g1" ] || fail "current should point at $g1, points at: $cur"

# --- relative symlinks (must resolve inside \$root without \$root baked in) ---
raw_target="$(readlink "$root/current")"
case "$raw_target" in
  /*) fail "current symlink should be relative, got absolute target: $raw_target" ;;
esac

# --- second and third create: current/previous both advance -------------
g2="$(create_gen)" || fail "second create failed"
cur="$(basename "$(readlink "$root/current")")"
prev="$(basename "$(readlink "$root/previous")")"
[ "$cur" = "$g2" ] || fail "after 2nd create, current should be $g2, got $cur"
[ "$prev" = "$g1" ] || fail "after 2nd create, previous should be $g1, got $prev"

g3="$(create_gen)" || fail "third create failed"
cur="$(basename "$(readlink "$root/current")")"
prev="$(basename "$(readlink "$root/previous")")"
[ "$cur" = "$g3" ] || fail "after 3rd create, current should be $g3, got $cur"
[ "$prev" = "$g2" ] || fail "after 3rd create, previous should be $g2, got $prev"

# --- list --porcelain reflects current/previous flags correctly ---------
listing="$("$gen" list --root "$root" --porcelain)"
echo "$listing" | awk -F'\t' -v g="$g3" '$1==g && $5=="yes"{f=1} END{exit !f}' \
  || fail "list --porcelain should mark $g3 current=yes"
echo "$listing" | awk -F'\t' -v g="$g2" '$1==g && $6=="yes"{f=1} END{exit !f}' \
  || fail "list --porcelain should mark $g2 previous=yes"
echo "$listing" | awk -F'\t' -v g="$g1" '$1==g && $5=="no" && $6=="no"{f=1} END{exit !f}' \
  || fail "list --porcelain should mark $g1 as neither current nor previous"

# --- rollback-target previous, using on-disk pointers as convenience default ---
target="$("$gen" rollback-target previous --root "$root")" || fail "rollback-target previous failed"
[ "$target" = "$g2" ] || fail "rollback-target previous should resolve to $g2, got $target"

# --- rollback-target rejects a generation that exists but isn't retained ---
# retain=1 with an explicit booted=$g3: only {g3} (newest 1) union {g3}
# (booted) is retained — no --previous override, so it also defaults from
# the on-disk pointer ($g2), retaining {g2,g3}. $g1 is neither, so asking
# to roll back to it must fail even though it still exists on disk.
out="$("$gen" rollback-target "$g1" --root "$root" --retain 1 --booted "$g3" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "rollback-target to a non-retained generation should fail"
case "$out" in
  *"not retained"*) ;;
  *) fail "non-retained rollback-target error should say so, got: $out" ;;
esac

# --- rollback-target to an explicit, retained generation succeeds -------
target="$("$gen" rollback-target "$g2" --root "$root" --retain 1 --booted "$g3")" \
  || fail "rollback-target to a retained generation should succeed"
[ "$target" = "$g2" ] || fail "rollback-target should echo back $g2, got $target"

# --- rollback-target rejects a nonexistent target ------------------------
out="$("$gen" rollback-target 999 --root "$root" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "rollback-target to a nonexistent generation should fail"

# --- rollback-target rejects a nonexistent --booted/--previous -----------
out="$("$gen" rollback-target "$g2" --root "$root" --booted 999 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "rollback-target with a nonexistent --booted should fail"

exit "$fails"
