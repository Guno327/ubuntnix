#!/usr/bin/env bash
# tests/unit/135-ubx-soft-reboot-dispatch.sh — `ubx rebuild switch|test`'s
# soft-reboot activation dispatch end-to-end (SPEC.md §4.3/§12 R3; GitHub
# issue #30, milestone M2): given the delta classification
# tests/unit/134-*.sh exercises directly, this asserts bin/ubx's do_rebuild
# actually invokes (or correctly withholds) a reboot at the right times.
# Issue #55 extended this to the /run/nextroot staging step (
# UBX_NEXTROOT_STAGE_CMD) that must now run immediately before every one
# of those reboot invocations.
#
# Neither the real reboot command nor the real staging (mount) command is
# ever run here: UBX_SOFT_REBOOT_CMD and UBX_NEXTROOT_STAGE_CMD are each
# pointed at a stub script that appends its argv to its own marker file
# instead of calling systemd/mount, which is exactly the seam bin/ubx's
# header documents each env var for. Only mechanism + these unit
# assertions are in scope here — the real QEMU switch-loop exercise of an
# actual `systemctl soft-reboot` re-execing into a really-mounted
# /run/nextroot is tests/e2e/020-qemu-switch-e2e.sh (issue #32/#55).
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

# nextroot_log records "IMAGE TARGET" per staging invocation; order.log
# additionally records, in a single shared file, the RELATIVE order the
# staging stub and the reboot stub each fired in (issue #55's "staging
# must be ordered before the reboot call" requirement) — a fresh temp file
# per test iteration below, since order must be checked per-scenario.
nextroot_log="$work/nextroot.log"
nextroot_stub="$work/nextroot-stage-stub"
order_log="$work/order.log"
cat > "$nextroot_stub" <<STUB
#!/usr/bin/env bash
printf '%s\t%s\n' "\$1" "\$2" >> "$nextroot_log"
printf 'stage\n' >> "$order_log"
exit 0
STUB
chmod +x "$nextroot_stub"
# Rewrite the soft-reboot stub so it ALSO records into order.log, so a
# single scenario run can assert relative ordering between the two stubs
# without needing separate instrumentation.
cat > "$stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$stub_log"
printf 'reboot\n' >> "$order_log"
exit 0
STUB
chmod +x "$stub"

reset_stub() { : > "$stub_log"; : > "$nextroot_log"; : > "$order_log"; }
invoked() { [ -s "$stub_log" ]; }
staged() { [ -s "$nextroot_log" ]; }

# =====================================================================
# switch + image-only delta -> the stub IS invoked with 'soft-reboot'.
# =====================================================================
root1="$work/gens-image"
reset_stub
UBX_SOFT_REBOOT_CMD="$stub" UBX_NEXTROOT_STAGE_CMD="$nextroot_stub" "$ubx" rebuild switch --root "$root1" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  > /dev/null || fail "switch (gen1, image setup) failed"
reset_stub
out="$(UBX_SOFT_REBOOT_CMD="$stub" UBX_NEXTROOT_STAGE_CMD="$nextroot_stub" "$ubx" rebuild switch --root "$root1" \
  --rootfs-image /store/r2 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "switch (gen2, image delta) should exit 0, got $rc: $out"
invoked || fail "switch with an image-only delta must invoke UBX_SOFT_REBOOT_CMD, log is empty"
contains "$(cat "$stub_log")" "soft-reboot" || fail "stub should have been invoked with 'soft-reboot', got: $(cat "$stub_log")"
contains "$out" "soft-reboot" || fail "switch with an image delta should mention soft-reboot in its output, got: $out"
staged || fail "switch with an image-only delta must invoke UBX_NEXTROOT_STAGE_CMD, log is empty"
[ "$(cat "$nextroot_log")" = "$(printf '%s\t%s' /store/r2 /run/nextroot)" ] \
  || fail "staging should have been invoked with the NEW generation's image (/store/r2) and /run/nextroot, got: $(cat "$nextroot_log")"
[ "$(cat "$order_log")" = "$(printf '%s\n%s' stage reboot)" ] \
  || fail "staging must be invoked BEFORE the reboot command, order.log: $(cat "$order_log")"

# =====================================================================
# switch + kernel delta (image changes too) -> stub NOT invoked; output
# states a full reboot is required.
# =====================================================================
root2="$work/gens-kernel"
reset_stub
UBX_SOFT_REBOOT_CMD="$stub" UBX_NEXTROOT_STAGE_CMD="$nextroot_stub" "$ubx" rebuild switch --root "$root2" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  > /dev/null || fail "switch (gen1, kernel setup) failed"
reset_stub
out="$(UBX_SOFT_REBOOT_CMD="$stub" UBX_NEXTROOT_STAGE_CMD="$nextroot_stub" "$ubx" rebuild switch --root "$root2" \
  --rootfs-image /store/r2 --kernel /store/k2 --initrd /store/i1 --root-device /dev/sda1 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "switch (gen2, kernel delta) should exit 0, got $rc: $out"
invoked && fail "switch with a kernel delta must NOT invoke UBX_SOFT_REBOOT_CMD, log: $(cat "$stub_log")"
contains "$out" "full reboot" || fail "switch with a kernel delta should state a full reboot is required, got: $out"
contains "$out" "NOT" || fail "switch with a kernel delta should state ubx will NOT auto-reboot, got: $out"
staged && fail "switch with a kernel delta must NOT invoke UBX_NEXTROOT_STAGE_CMD, log: $(cat "$nextroot_log")"

# =====================================================================
# switch + live-only (identical image and kernel) -> stub NOT invoked.
# =====================================================================
root3="$work/gens-live-only"
reset_stub
UBX_SOFT_REBOOT_CMD="$stub" UBX_NEXTROOT_STAGE_CMD="$nextroot_stub" "$ubx" rebuild switch --root "$root3" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  > /dev/null || fail "switch (gen1, live-only setup) failed"
reset_stub
out="$(UBX_SOFT_REBOOT_CMD="$stub" UBX_NEXTROOT_STAGE_CMD="$nextroot_stub" "$ubx" rebuild switch --root "$root3" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "switch (gen2, live-only) should exit 0, got $rc: $out"
invoked && fail "switch with no image/kernel delta must NOT invoke UBX_SOFT_REBOOT_CMD, log: $(cat "$stub_log")"
contains "$out" "not needed" || fail "switch with no delta should state no reboot is needed, got: $out"
staged && fail "switch with no image/kernel delta must NOT invoke UBX_NEXTROOT_STAGE_CMD, log: $(cat "$nextroot_log")"

# =====================================================================
# 'rebuild test' + image delta -> stub NOT invoked, even though the
# delta class is 'image' (test never reboots, soft or full).
# =====================================================================
root4="$work/gens-test-verb"
reset_stub
UBX_SOFT_REBOOT_CMD="$stub" UBX_NEXTROOT_STAGE_CMD="$nextroot_stub" "$ubx" rebuild switch --root "$root4" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  > /dev/null || fail "switch (gen1, test-verb setup) failed"
reset_stub
out="$(UBX_SOFT_REBOOT_CMD="$stub" UBX_NEXTROOT_STAGE_CMD="$nextroot_stub" "$ubx" rebuild test --root "$root4" \
  --rootfs-image /store/r2 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild test' with an image delta should exit 0, got $rc: $out"
invoked && fail "'rebuild test' must NEVER invoke UBX_SOFT_REBOOT_CMD, log: $(cat "$stub_log")"
staged && fail "'rebuild test' must NEVER invoke UBX_NEXTROOT_STAGE_CMD, log: $(cat "$nextroot_log")"

# =====================================================================
# --dry-run switch + image delta -> stub NOT invoked; output describes
# what WOULD happen.
# =====================================================================
root5="$work/gens-dry-run"
reset_stub
UBX_SOFT_REBOOT_CMD="$stub" UBX_NEXTROOT_STAGE_CMD="$nextroot_stub" "$ubx" rebuild switch --root "$root5" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  > /dev/null || fail "switch (gen1, dry-run setup) failed"
reset_stub
out="$(UBX_SOFT_REBOOT_CMD="$stub" UBX_NEXTROOT_STAGE_CMD="$nextroot_stub" "$ubx" rebuild switch --root "$root5" --dry-run \
  --rootfs-image /store/r2 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "dry-run switch with an image delta should exit 0, got $rc: $out"
invoked && fail "dry-run switch must NEVER invoke UBX_SOFT_REBOOT_CMD, log: $(cat "$stub_log")"
contains "$out" "would" || fail "dry-run switch with an image delta should describe what WOULD happen, got: $out"
contains "$out" "soft-reboot" || fail "dry-run switch with an image delta should mention soft-reboot, got: $out"
staged && fail "dry-run switch must NEVER invoke UBX_NEXTROOT_STAGE_CMD, log: $(cat "$nextroot_log")"
[ ! -e "$root5/2" ] || fail "dry-run must not have registered generation 2 under $root5"

exit "$fails"
