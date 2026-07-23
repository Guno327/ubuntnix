#!/usr/bin/env bash
# tests/unit/132-ubx-grub-default-matrix.sh — THE GRUB-default matrix
# (SPEC.md §4.3, §4.5; GitHub issue #29, milestone M2): the single most
# important behavior this issue adds to `ubx`.
#
#   ubx rebuild switch  -> sets the GRUB default to the new generation
#   ubx rebuild boot    -> sets the GRUB default to the new generation
#   ubx rebuild test    -> NEVER touches the GRUB default, no matter what
#   ubx rollback        -> moves the GRUB default back to the target
#
# The on-disk record under test is $ROOT/grub-default (see
# bin/ubx-rebuild-lib's header, "GRUB default marker" — real bootloader
# programming is deferred to issue #30; this file, and the fact
# switch/boot/rollback write it while test never does, is real and is
# exactly the contract this test asserts). Every assertion here needs no
# root and no live systemd: registering a generation and writing a bare
# marker file are both plain filesystem operations.
set -u

ubx="$UBX_REPO_ROOT/bin/ubx"
[ -x "$ubx" ] || { echo "FAIL: $ubx does not exist or is not executable" >&2; exit 1; }

fails=0
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

grub_default_of() { # ROOT
  local f="$1/grub-default"
  if [ -f "$f" ]; then cat "$f"; else echo "<unset>"; fi
}

# =====================================================================
# switch: sets the GRUB default to the just-registered generation.
# =====================================================================
root_switch="$work/gens-switch"
[ "$(grub_default_of "$root_switch")" = "<unset>" ] || fail "precondition: grub-default should not exist yet"

"$ubx" rebuild switch --root "$root_switch" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  > /dev/null || fail "rebuild switch (gen1) failed"
[ "$(grub_default_of "$root_switch")" = 1 ] || fail "switch must set grub-default to 1, got: $(grub_default_of "$root_switch")"

"$ubx" rebuild switch --root "$root_switch" \
  --rootfs-image /store/r2 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  > /dev/null || fail "rebuild switch (gen2) failed"
[ "$(grub_default_of "$root_switch")" = 2 ] || fail "a second switch must move grub-default to 2, got: $(grub_default_of "$root_switch")"

# =====================================================================
# boot: sets the GRUB default too, but this is exercised WITHOUT ever
# calling switch/test first, and the boot verb never runs execute_domains
# (no live activation) — the marker must still land.
# =====================================================================
root_boot="$work/gens-boot"
"$ubx" rebuild boot --root "$root_boot" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  > /dev/null || fail "rebuild boot (gen1) failed"
[ "$(grub_default_of "$root_boot")" = 1 ] || fail "boot must set grub-default to 1, got: $(grub_default_of "$root_boot")"

# =====================================================================
# test: THE critical negative assertion — never touches the GRUB default,
# whether one was already set (moving from switch/boot) or never set at
# all (a bare-first-generation 'test').
# =====================================================================
root_test="$work/gens-test"
# 'test' as the very FIRST rebuild ever run against this root: no
# grub-default must be written.
"$ubx" rebuild test --root "$root_test" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  > /dev/null || fail "rebuild test (gen1, first-ever) failed"
[ "$(grub_default_of "$root_test")" = "<unset>" ] \
  || fail "'rebuild test' as the first-ever rebuild must NOT create grub-default, got: $(grub_default_of "$root_test")"

# now switch once (sets it to 1), then 'test' repeatedly: the marker must
# stay pinned at 1 no matter how many generations 'test' registers.
"$ubx" rebuild switch --root "$root_test" \
  --rootfs-image /store/r1b --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  > /dev/null || fail "rebuild switch (gen2, to seed grub-default=2) failed"
seeded="$(grub_default_of "$root_test")"
[ "$seeded" = 2 ] || fail "setup: switch should have set grub-default to 2, got: $seeded"

for i in 1 2 3; do
  "$ubx" rebuild test --root "$root_test" \
    --rootfs-image "/store/rt$i" --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
    > /dev/null || fail "rebuild test (iteration $i) failed"
  current="$(grub_default_of "$root_test")"
  [ "$current" = "$seeded" ] \
    || fail "'rebuild test' iteration $i must leave grub-default at $seeded, got: $current"
done

# --dry-run test also asserts (via stdout) that it would not touch it,
# and really doesn't.
before="$(grub_default_of "$root_test")"
out="$("$ubx" rebuild test --root "$root_test" --dry-run 2>&1)"
case "$out" in
  *"unchanged"*) ;;
  *) fail "'rebuild test --dry-run' output should say the grub default is unchanged, got: $out" ;;
esac
after="$(grub_default_of "$root_test")"
[ "$before" = "$after" ] || fail "'rebuild test --dry-run' must not change grub-default ($before -> $after)"

# =====================================================================
# rollback: moves the GRUB default back to the resolved target.
# =====================================================================
root_rb="$work/gens-rollback"
"$ubx" rebuild switch --root "$root_rb" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  > /dev/null || fail "rollback setup: switch (gen1) failed"
"$ubx" rebuild switch --root "$root_rb" \
  --rootfs-image /store/r2 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  > /dev/null || fail "rollback setup: switch (gen2) failed"
[ "$(grub_default_of "$root_rb")" = 2 ] || fail "rollback setup: grub-default should be 2 before rolling back"

"$ubx" rollback --root "$root_rb" > /dev/null || fail "rollback (to previous) failed"
[ "$(grub_default_of "$root_rb")" = 1 ] \
  || fail "rollback to 'previous' must move grub-default back to 1, got: $(grub_default_of "$root_rb")"

# rollback --dry-run must not touch it.
"$ubx" rebuild switch --root "$root_rb" \
  --rootfs-image /store/r3 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  > /dev/null || fail "rollback setup: switch (gen3) failed"
before_rb="$(grub_default_of "$root_rb")"
"$ubx" rollback --root "$root_rb" --dry-run > /dev/null || fail "rollback --dry-run failed"
after_rb="$(grub_default_of "$root_rb")"
[ "$before_rb" = "$after_rb" ] || fail "'rollback --dry-run' must not change grub-default ($before_rb -> $after_rb)"

exit "$fails"
