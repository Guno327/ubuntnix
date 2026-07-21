#!/usr/bin/env bash
# tests/unit/084-gen-grub-list.sh — bin/ubx-generations `emit-grub-list`:
# the TSV generation-list file bin/ubx-gen-grub-cfg (issue #10) consumes
# (SPEC.md §4.2; GitHub issue #25, milestone M2).
#
# The contract (owned by this script per its own header, "Interface with
# bin/ubx-gen-grub-cfg"): one line per selected generation, six TAB-
# separated fields in this exact order — index, title, kernelPath,
# initrdPath, rootDevice, kernelParams (last field, verbatim to end of
# line, may contain spaces/be empty). Ordering: on-disk "current" first if
# selected, then the rest descending by index.
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

g1="$("$gen" create --root "$root" --title "gen one" --rootfs-image /store/r1 \
  --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --kernel-params "quiet splash")" || fail "create gen1 failed"
g2="$("$gen" create --root "$root" --title "gen two" --rootfs-image /store/r2 \
  --kernel /store/k2 --initrd /store/i2 --root-device /dev/sda1)" || fail "create gen2 failed"
g3="$("$gen" create --root "$root" --title "gen three" --rootfs-image /store/r3 \
  --kernel /store/k3 --initrd /store/i3 --root-device /dev/sda1)" || fail "create gen3 failed"
# g3 is now "current" on disk.

# --- exact six-field TSV shape, in order -----------------------------------
out="$("$gen" emit-grub-list --root "$root" --select "$g1,$g2,$g3" --out -)" \
  || fail "emit-grub-list --select failed"

nfields="$(printf '%s\n' "$out" | head -1 | awk -F'\t' '{print NF}')"
[ "$nfields" = 6 ] || fail "each line should have exactly 6 TAB-separated fields, got $nfields"

# --- ordering: current ($g3) first, then descending ------------------------
indices="$(printf '%s\n' "$out" | cut -f1 | paste -sd, -)"
[ "$indices" = "$g3,$g2,$g1" ] \
  || fail "ordering should be current ($g3) first then descending, got: $indices"

# --- field content, including a verbatim, space-containing last field ------
g1_line="$(printf '%s\n' "$out" | awk -F'\t' -v g="$g1" '$1==g')"
IFS=$'\t' read -r idx title kernel initrd device params <<< "$g1_line"
[ "$idx" = "$g1" ] || fail "gen1's index field should be $g1, got: $idx"
[ "$title" = "gen one" ] || fail "gen1's title field should be 'gen one', got: $title"
[ "$kernel" = /store/k1 ] || fail "gen1's kernel field should be /store/k1, got: $kernel"
[ "$initrd" = /store/i1 ] || fail "gen1's initrd field should be /store/i1, got: $initrd"
[ "$device" = /dev/sda1 ] || fail "gen1's device field should be /dev/sda1, got: $device"
[ "$params" = "quiet splash" ] || fail "gen1's kernel-params field should be verbatim 'quiet splash', got: $params"

g2_line="$(printf '%s\n' "$out" | awk -F'\t' -v g="$g2" '$1==g')"
IFS=$'\t' read -r idx title kernel initrd device params <<< "$g2_line"
[ "$idx" = "$g2" ] || fail "gen2's index field should be $g2, got: $idx"
[ "$params" = "" ] || fail "gen2 has no kernel params; the field should be empty, got: $params"

# --- current omitted from the selection: no bogus leading entry -----------
out_no_current="$("$gen" emit-grub-list --root "$root" --select "$g1,$g2" --out -)" \
  || fail "emit-grub-list --select without current failed"
indices2="$(printf '%s\n' "$out_no_current" | cut -f1 | paste -sd, -)"
[ "$indices2" = "$g2,$g1" ] \
  || fail "without current in the selection, ordering should just be descending, got: $indices2"

# --- --retain-based selection matches prune-plan/gc-plan's retained set ----
out_retain="$("$gen" emit-grub-list --root "$root" --retain 2 --booted "$g3" --out -)" \
  || fail "emit-grub-list --retain failed"
indices3="$(printf '%s\n' "$out_retain" | cut -f1 | paste -sd, -)"
[ "$indices3" = "$g3,$g2" ] \
  || fail "retain=2 booted=$g3 should select {$g2,$g3} ordered $g3,$g2 -- got: $indices3"

# --- --out FILE writes atomically to a real path ---------------------------
outfile="$work/grub-list.tsv"
"$gen" emit-grub-list --root "$root" --select "$g1" --out "$outfile" \
  || fail "emit-grub-list --out FILE failed"
[ -s "$outfile" ] || fail "emit-grub-list --out FILE should produce a non-empty file"
grep -q "^$g1"$'\t' "$outfile" || fail "the written file should contain generation $g1's line"

# --- --select and --retain are mutually exclusive --------------------------
out="$("$gen" emit-grub-list --root "$root" --select "$g1" --retain 1 --booted "$g1" --out - 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "emit-grub-list with both --select and --retain should fail"

# --- --out is required ------------------------------------------------------
out="$("$gen" emit-grub-list --root "$root" --select "$g1" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "emit-grub-list without --out should fail"

# --- a nonexistent selected generation is rejected --------------------------
out="$("$gen" emit-grub-list --root "$root" --select 999 --out - 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "emit-grub-list --select with a nonexistent generation should fail"

# --- a nonexistent --booted is rejected under --retain ----------------------
out="$("$gen" emit-grub-list --root "$root" --retain 1 --booted 999 --out - 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "emit-grub-list --retain with a nonexistent --booted should fail"

exit "$fails"
