#!/usr/bin/env bash
# tests/unit/135-ubx-soft-reboot-dispatch.sh — `ubx rebuild switch|test`'s
# soft-reboot activation dispatch end-to-end (SPEC.md §4.3/§12 R3; GitHub
# issue #30, milestone M2): given the delta classification
# tests/unit/134-*.sh exercises directly, this asserts bin/ubx's do_rebuild
# actually invokes (or correctly withholds) a reboot at the right times.
#
# The real reboot command is never run: UBX_SOFT_REBOOT_CMD is pointed at
# a stub script that appends its argv to a marker file instead of calling
# systemd, which is exactly the seam bin/ubx's header documents this env
# var for. Only mechanism + these unit assertions are in scope here — the
# real QEMU switch-loop exercise of an actual `systemctl soft-reboot` is
# issue #32, explicitly out of scope.
set -u

ubx="$UBX_REPO_ROOT/bin/ubx"
[ -x "$ubx" ] || { echo "FAIL: $ubx does not exist or is not executable" >&2; exit 1; }

fails=0
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

stub_log="$work/stub.log"
stub="$work/soft-reboot-stub"
cat > "$stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$stub_log"
exit 0
STUB
chmod +x "$stub"

reset_stub() { : > "$stub_log"; }
invoked() { [ -s "$stub_log" ]; }

# =====================================================================
# switch + image-only delta -> the stub IS invoked with 'soft-reboot'.
# =====================================================================
root1="$work/gens-image"
reset_stub
UBX_SOFT_REBOOT_CMD="$stub" "$ubx" rebuild switch --root "$root1" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  > /dev/null || fail "switch (gen1, image setup) failed"
reset_stub
out="$(UBX_SOFT_REBOOT_CMD="$stub" "$ubx" rebuild switch --root "$root1" \
  --rootfs-image /store/r2 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "switch (gen2, image delta) should exit 0, got $rc: $out"
invoked || fail "switch with an image-only delta must invoke UBX_SOFT_REBOOT_CMD, log is empty"
contains "$(cat "$stub_log")" "soft-reboot" || fail "stub should have been invoked with 'soft-reboot', got: $(cat "$stub_log")"
contains "$out" "soft-reboot" || fail "switch with an image delta should mention soft-reboot in its output, got: $out"

# =====================================================================
# switch + kernel delta (image changes too) -> stub NOT invoked; output
# states a full reboot is required.
# =====================================================================
root2="$work/gens-kernel"
reset_stub
UBX_SOFT_REBOOT_CMD="$stub" "$ubx" rebuild switch --root "$root2" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  > /dev/null || fail "switch (gen1, kernel setup) failed"
reset_stub
out="$(UBX_SOFT_REBOOT_CMD="$stub" "$ubx" rebuild switch --root "$root2" \
  --rootfs-image /store/r2 --kernel /store/k2 --initrd /store/i1 --root-device /dev/sda1 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "switch (gen2, kernel delta) should exit 0, got $rc: $out"
invoked && fail "switch with a kernel delta must NOT invoke UBX_SOFT_REBOOT_CMD, log: $(cat "$stub_log")"
contains "$out" "full reboot" || fail "switch with a kernel delta should state a full reboot is required, got: $out"
contains "$out" "NOT" || fail "switch with a kernel delta should state ubx will NOT auto-reboot, got: $out"

# =====================================================================
# switch + live-only (identical image and kernel) -> stub NOT invoked.
# =====================================================================
root3="$work/gens-live-only"
reset_stub
UBX_SOFT_REBOOT_CMD="$stub" "$ubx" rebuild switch --root "$root3" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  > /dev/null || fail "switch (gen1, live-only setup) failed"
reset_stub
out="$(UBX_SOFT_REBOOT_CMD="$stub" "$ubx" rebuild switch --root "$root3" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "switch (gen2, live-only) should exit 0, got $rc: $out"
invoked && fail "switch with no image/kernel delta must NOT invoke UBX_SOFT_REBOOT_CMD, log: $(cat "$stub_log")"
contains "$out" "not needed" || fail "switch with no delta should state no reboot is needed, got: $out"

# =====================================================================
# 'rebuild test' + image delta -> stub NOT invoked, even though the
# delta class is 'image' (test never reboots, soft or full).
# =====================================================================
root4="$work/gens-test-verb"
reset_stub
UBX_SOFT_REBOOT_CMD="$stub" "$ubx" rebuild switch --root "$root4" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  > /dev/null || fail "switch (gen1, test-verb setup) failed"
reset_stub
out="$(UBX_SOFT_REBOOT_CMD="$stub" "$ubx" rebuild test --root "$root4" \
  --rootfs-image /store/r2 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild test' with an image delta should exit 0, got $rc: $out"
invoked && fail "'rebuild test' must NEVER invoke UBX_SOFT_REBOOT_CMD, log: $(cat "$stub_log")"

# =====================================================================
# --dry-run switch + image delta -> stub NOT invoked; output describes
# what WOULD happen.
# =====================================================================
root5="$work/gens-dry-run"
reset_stub
UBX_SOFT_REBOOT_CMD="$stub" "$ubx" rebuild switch --root "$root5" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  > /dev/null || fail "switch (gen1, dry-run setup) failed"
reset_stub
out="$(UBX_SOFT_REBOOT_CMD="$stub" "$ubx" rebuild switch --root "$root5" --dry-run \
  --rootfs-image /store/r2 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "dry-run switch with an image delta should exit 0, got $rc: $out"
invoked && fail "dry-run switch must NEVER invoke UBX_SOFT_REBOOT_CMD, log: $(cat "$stub_log")"
contains "$out" "would" || fail "dry-run switch with an image delta should describe what WOULD happen, got: $out"
contains "$out" "soft-reboot" || fail "dry-run switch with an image delta should mention soft-reboot, got: $out"
[ ! -e "$root5/2" ] || fail "dry-run must not have registered generation 2 under $root5"

exit "$fails"
