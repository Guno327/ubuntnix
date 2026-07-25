#!/usr/bin/env bash
# tests/unit/134-ubx-rebuild-classify-delta.sh — bin/ubx-rebuild-lib's
# ubx_rebuild_classify_delta: the delta->activation-path matrix underlying
# the soft-reboot activation path (SPEC.md §4.3/§12 R3; GitHub issue #30,
# milestone M2).
#
#   kernel     GEN_KERNEL_PATH differs between old and new generation --
#              OVERRIDES an image change too (a kernel delta always wins:
#              there is no live kernel soft-reboot).
#   image      kernel unchanged, GEN_ROOTFS_IMAGE differs -- the
#              soft-reboot candidate.
#   live-only  neither changed.
#
# Exercised directly against the classifier (no `ubx` invocation, no
# reboot dispatch at all -- see tests/unit/135-*.sh for the end-to-end
# dispatch-through-`ubx-rebuild` matrix) by hand-writing generation
# manifest fixtures in bin/ubx-generations' own flat KEY=value format
# (see that script's header, "Manifest format").
set -u

lib="$UBX_REPO_ROOT/bin/ubx-rebuild-lib"
[ -f "$lib" ] || { echo "FAIL: $lib does not exist" >&2; exit 1; }
UBX_REBUILD_LIB_PROG="test"
# shellcheck source=bin/ubx-rebuild-lib
. "$lib"

fails=0
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

root="$work/gens"
mkdir -p "$root"

write_gen() { # GEN ROOTFS_IMAGE KERNEL_PATH
  mkdir -p "$root/$1"
  {
    printf 'GEN_ROOTFS_IMAGE=%s\n' "$2"
    printf 'GEN_KERNEL_PATH=%s\n' "$3"
  } > "$root/$1/manifest"
}

assert_class() { # LABEL OLD_GEN NEW_GEN EXPECTED
  local label="$1" old="$2" new="$3" expected="$4" got
  got="$(ubx_rebuild_classify_delta "$root" "$old" "$new")"
  [ "$got" = "$expected" ] || fail "$label: expected '$expected', got '$got'"
}

# =====================================================================
# image-only change: kernel identical, rootfs image differs -> image.
# =====================================================================
write_gen 1 /store/r1 /store/k1
write_gen 2 /store/r2 /store/k1
assert_class "image-only delta" 1 2 image

# =====================================================================
# kernel change, image UNCHANGED -> kernel.
# =====================================================================
write_gen 3 /store/r1 /store/k1
write_gen 4 /store/r1 /store/k2
assert_class "kernel-only delta" 3 4 kernel

# =====================================================================
# kernel change AND image change -> kernel still wins (overrides image).
# =====================================================================
write_gen 5 /store/r1 /store/k1
write_gen 6 /store/r2 /store/k2
assert_class "kernel+image delta (kernel overrides)" 5 6 kernel

# =====================================================================
# no change at all -> live-only.
# =====================================================================
write_gen 7 /store/r1 /store/k1
write_gen 8 /store/r1 /store/k1
assert_class "no delta" 7 8 live-only

# =====================================================================
# empty OLD_GEN (the very first rebuild ever): a new image present ->
# image; nothing present -> live-only.
# =====================================================================
write_gen 9 /store/r1 /store/k1
assert_class "empty old gen, new image present" "" 9 image

mkdir -p "$root/10"
: > "$root/10/manifest"
assert_class "empty old gen, no new image/kernel declared" "" 10 live-only

exit "$fails"
