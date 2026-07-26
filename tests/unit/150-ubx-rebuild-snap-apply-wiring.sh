#!/usr/bin/env bash
# tests/unit/150-ubx-rebuild-snap-apply-wiring.sh — `ubx rebuild
# switch|boot|test` wiring bin/ubx-snap's plan and bin/ubx-snap-apply's
# executor into its convergence sequence (SPEC.md §4.3, §7; GitHub issue
# #72, milestone M3).
#
# Mirrors tests/unit/149-ubx-rebuild-snap-purge-wiring.sh's own
# "end-to-end through a real `ubx rebuild ...` invocation, stub instead of
# the real underlying binary" style, adapted to bin/ubx-snap-apply's own
# UBX_SNAP_CMD seam (tests/unit/148-snap-apply-executor.sh) rather than
# bin/ubx-snap-purge's UBX_SNAP_BIN seam.
#
# What this test asserts (none of it needs root, network, or a real
# snapd):
#   1. `rebuild switch` (no --apply): the plan is computed and reported
#      ("snap: N action(s) touched"), but bin/ubx-snap-apply is never
#      invoked (the UBX_SNAP_CMD stub records zero calls) -- dry-run must
#      not mutate.
#   2. `rebuild switch --apply`: bin/ubx-snap-apply IS invoked for real,
#      issuing the exact ordered `ack`/`install` calls bin/ubx-snap's plan
#      computed for a freshly-declared snap.
#   3. `rebuild test --apply` NEVER really invokes bin/ubx-snap-apply,
#      even though --apply was given -- the same safety carve-out
#      tests/unit/149 already established for the snap-purge sweep,
#      extended here to the plan+apply convergence path (see bin/ubx's
#      execute_domains header).
#   4. `rebuild boot --apply` never invokes it either (boot never calls
#      execute_domains at all).
#   5. --snap-observed overrides the "assume converged" synthesis: an
#      observed manifest that already matches the declared one produces an
#      empty plan and zero real snap-cmd calls, even under --apply.
#   6. Omitting --snap-manifest entirely skips the domain (no invocation),
#      matching every other domain's "nothing declared" convention.
#   7. Ordering: when both a plan+apply action and a snap-purge removal
#      are pending, the plan+apply call(s) are issued BEFORE the purge
#      sweep's own removal (converge what's declared before sweeping what
#      isn't) -- both funnel their real mutations through independent
#      seams (UBX_SNAP_CMD vs UBX_SNAP_BIN) recording to one shared,
#      ordered log.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

ubx="$UBX_REPO_ROOT/bin/ubx"
snap_apply="$UBX_REPO_ROOT/bin/ubx-snap-apply"
[ -x "$ubx" ] || { echo "FAIL: $ubx does not exist or is not executable" >&2; exit 1; }
[ -x "$snap_apply" ] || { echo "FAIL: $snap_apply does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# -- recording stub standing in for the real `snap` client (UBX_SNAP_CMD) --
# mirrors tests/unit/148's own recording stub exactly.
snap_cmd_stub="$work/stub-snap-cmd"
cat > "$snap_cmd_stub" <<EOF
#!/bin/sh
echo "\$*" >> "\$STUB_SNAP_CMD_LOG"
exit 0
EOF
chmod +x "$snap_cmd_stub"

# -- old manifest: nothing declared yet (first-ever generation) -- so the
# new manifest's 'firefox' is planned as a fresh install (ack + install).
old_manifest="$work/old-snap-manifest.json"
echo '{"version": 1, "snaps": []}' > "$old_manifest"

# -- new manifest: declares exactly one snap, 'firefox' at revision 4090 --
new_manifest="$work/new-snap-manifest.json"
cat > "$new_manifest" <<'EOF'
{"version": 1, "snaps": [
  {"name": "firefox", "channel": "stable", "revision": 4090, "classic": false, "connections": [], "config": {}}
]}
EOF

export UBX_SOFT_REBOOT_CMD=true
export UBX_NEXTROOT_STAGE_CMD=true

# This test's focus is bin/ubx-snap's plan+apply convergence path, NOT the
# separate snap-purge sweep (tests/unit/149 owns that one) -- but every
# `--apply` scenario below still walks through execute_domains' snap block
# in full, which always ALSO invokes bin/ubx-snap-purge (see bin/ubx's own
# header/execute_domains). Stub its own UBX_SNAP_BIN seam with a 'list'
# reporting exactly the declared 'firefox' snap (nothing undeclared), so
# the purge sweep finds nothing to remove and never shells out to a real
# 'snap' client -- this harness has no real snapd, and even a real 'snap'
# binary on the host must never be touched by a unit test
# (tests/README.md's "no root, no network, no KVM" rule).
default_snap_bin_stub="$work/stub-default-snap-bin"
cat > "$default_snap_bin_stub" <<'STUBEOF'
#!/usr/bin/env bash
set -u
if [ "$1" = "list" ]; then
  printf 'Name      Version   Rev   Tracking       Publisher     Notes\n'
  printf 'firefox   118.0     4090  latest/stable  mozilla**     -\n'
  exit 0
fi
echo "stub-default-snap-bin: unexpected invocation: $*" >&2
exit 99
STUBEOF
chmod +x "$default_snap_bin_stub"
export UBX_SNAP_BIN="$default_snap_bin_stub"

common_flags=(--rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --snap-manifest "$new_manifest")

run_rebuild() {
  # run_rebuild ROOT VERB [extra args...] -- fresh --root per call so
  # generation numbering never collides across the scenarios below.
  local root="$1" verb="$2"
  shift 2
  "$ubx" rebuild "$verb" --root "$root" "${common_flags[@]}" "$@"
}

# =====================================================================
# 1) `rebuild switch` (no --apply): plan computed/reported, but
#    bin/ubx-snap-apply is never invoked for real.
# =====================================================================
root1="$work/gens1"
log1="$work/log1.txt"
: > "$log1"
export STUB_SNAP_CMD_LOG="$log1"
out="$(UBX_SNAP_CMD="$snap_cmd_stub" run_rebuild "$root1" switch 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild switch' (no --apply) should exit 0, got $rc: $out"
contains "$out" "snap: 2 action(s) touched" || fail "'rebuild switch' should report the computed snap plan's action count (2: ack+install), got: $out"
[ ! -s "$log1" ] || fail "'rebuild switch' without --apply must NOT invoke ubx-snap-apply for real, recorded: $(cat "$log1")"

# =====================================================================
# 2) `rebuild switch --apply`: bin/ubx-snap-apply IS invoked for real, in
#    the exact ordered sequence bin/ubx-snap's plan computed.
# =====================================================================
root2="$work/gens2"
log2="$work/log2.txt"
: > "$log2"
export STUB_SNAP_CMD_LOG="$log2"
out="$(UBX_SNAP_CMD="$snap_cmd_stub" run_rebuild "$root2" switch --apply 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild switch --apply' should exit 0, got $rc: $out"
mapfile -t calls2 < "$log2"
if [ "${#calls2[@]}" -ne 2 ]; then
  fail "'rebuild switch --apply' should issue exactly 2 real snap-cmd calls (ack, install), got ${#calls2[@]}: $(printf '%s\n' "${calls2[@]}")"
else
  case "${calls2[0]}" in
    "ack "*"firefox_4090.snap-declaration") ;;
    *) fail "expected call[0] to ack firefox's assertion, got: ${calls2[0]}" ;;
  esac
  case "${calls2[1]}" in
    "install --dangerous "*"firefox_4090.snap") ;;
    *) fail "expected call[1] to install firefox's payload, got: ${calls2[1]}" ;;
  esac
fi

# =====================================================================
# 3) `rebuild test --apply`: NEVER really invokes ubx-snap-apply, even
#    though --apply was given -- extends tests/unit/149's snap-purge
#    safety carve-out to the plan+apply convergence path too.
# =====================================================================
root3="$work/gens3"
log3="$work/log3.txt"
: > "$log3"
export STUB_SNAP_CMD_LOG="$log3"
out="$(UBX_SNAP_CMD="$snap_cmd_stub" run_rebuild "$root3" test --apply 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild test --apply' should exit 0, got $rc: $out"
contains "$out" "snap: 2 action(s) touched" || fail "'rebuild test --apply' should still report the computed snap plan, got: $out"
[ ! -s "$log3" ] || fail "'rebuild test --apply' must NEVER really invoke ubx-snap-apply, recorded: $(cat "$log3")"

# =====================================================================
# 4) `rebuild boot --apply`: never invokes ubx-snap-apply at all (boot
#    never calls execute_domains).
# =====================================================================
root4="$work/gens4"
log4="$work/log4.txt"
: > "$log4"
export STUB_SNAP_CMD_LOG="$log4"
out="$(UBX_SNAP_CMD="$snap_cmd_stub" run_rebuild "$root4" boot --apply 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild boot --apply' should exit 0, got $rc: $out"
[ ! -s "$log4" ] || fail "'rebuild boot' must not invoke ubx-snap-apply at all, recorded: $(cat "$log4")"

# =====================================================================
# 5) --snap-observed overrides the "assume converged" synthesis: an
#    observed manifest already matching the declaration produces an empty
#    plan and zero real snap-cmd calls, even under --apply.
# =====================================================================
root5="$work/gens5"
log5="$work/log5.txt"
: > "$log5"
export STUB_SNAP_CMD_LOG="$log5"
observed="$work/observed-converged.json"
cat > "$observed" <<'EOF'
{"version": 1, "refreshHold": true, "snaps": [
  {"name": "firefox", "channel": "stable", "revision": 4090, "classic": false, "connections": [], "config": {}}
]}
EOF
out="$(UBX_SNAP_CMD="$snap_cmd_stub" run_rebuild "$root5" switch --apply --snap-observed "$observed" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild switch --apply --snap-observed' (already converged) should exit 0, got $rc: $out"
contains "$out" "snap: 0 action(s) touched" || fail "an already-converged --snap-observed manifest should plan zero actions, got: $out"
[ ! -s "$log5" ] || fail "an already-converged --snap-observed manifest must issue zero real snap-cmd calls, recorded: $(cat "$log5")"

# =====================================================================
# 6) Omitting --snap-manifest entirely: the domain is skipped, exactly
#    like an omitted --etc-ref/--systemd-ref/--users-manifest.
# =====================================================================
root6="$work/gens6"
log6="$work/log6.txt"
: > "$log6"
export STUB_SNAP_CMD_LOG="$log6"
out="$(UBX_SNAP_CMD="$snap_cmd_stub" "$ubx" rebuild switch --root "$root6" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --apply 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild switch --apply' with no --snap-manifest should exit 0, got $rc: $out"
contains "$out" "snap: nothing declared" || fail "'rebuild switch' with no --snap-manifest should report the domain as skipped, got: $out"
[ ! -s "$log6" ] || fail "'rebuild switch' with no --snap-manifest declared must not invoke ubx-snap-apply, recorded: $(cat "$log6")"

# =====================================================================
# 7) Ordering: plan+apply's own calls precede the snap-purge sweep's
#    removal, on a SHARED, ordered log (two independent seams,
#    UBX_SNAP_CMD and UBX_SNAP_BIN, both appending to one file).
# =====================================================================
root7="$work/gens7"
shared_log="$work/shared-order.txt"
: > "$shared_log"

order_snap_cmd_stub="$work/stub-order-snap-cmd"
cat > "$order_snap_cmd_stub" <<EOF
#!/bin/sh
echo "APPLY: \$*" >> "$shared_log"
exit 0
EOF
chmod +x "$order_snap_cmd_stub"

# The purge sweep's own UBX_SNAP_BIN seam (tests/unit/149's own stub
# shape): 'list' reports both the declared 'firefox' and an undeclared
# 'htop-snap', so the purge sweep has something real to remove.
order_snap_bin_stub="$work/stub-order-snap-bin"
cat > "$order_snap_bin_stub" <<EOF
#!/usr/bin/env bash
set -u
if [ "\$1" = "list" ]; then
  cat "\$STUB_ORDER_LIST_OUTPUT"
  exit 0
fi
if [ "\$1" = "remove" ] && [ "\$2" = "--purge" ]; then
  echo "PURGE: \$3" >> "$shared_log"
  exit 0
fi
echo "stub-order-snap-bin: unexpected invocation: \$*" >&2
exit 99
EOF
chmod +x "$order_snap_bin_stub"

order_list_output="$work/order-list-output.txt"
cat > "$order_list_output" <<'EOF'
Name      Version   Rev   Tracking       Publisher     Notes
firefox   118.0     4090  latest/stable  mozilla**     -
htop-snap 3.0       12    latest/stable  someuser      -
EOF

out="$(UBX_SNAP_CMD="$order_snap_cmd_stub" UBX_SNAP_BIN="$order_snap_bin_stub" \
  STUB_ORDER_LIST_OUTPUT="$order_list_output" \
  run_rebuild "$root7" switch --apply 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "ordering scenario 'rebuild switch --apply' should exit 0, got $rc: $out"

mapfile -t order_calls < "$shared_log"
[ "${#order_calls[@]}" -ge 3 ] || fail "expected at least 3 recorded calls (ack, install, purge), got ${#order_calls[@]}: $(printf '%s\n' "${order_calls[@]}")"
purge_idx=-1
last_apply_idx=-1
for i in "${!order_calls[@]}"; do
  case "${order_calls[$i]}" in
    APPLY:*) last_apply_idx="$i" ;;
    PURGE:*) [ "$purge_idx" -ge 0 ] || purge_idx="$i" ;;
  esac
done
if [ "$purge_idx" -lt 0 ] || [ "$last_apply_idx" -lt 0 ]; then
  fail "expected both an APPLY and a PURGE call recorded, got: $(printf '%s\n' "${order_calls[@]}")"
elif [ "$last_apply_idx" -ge "$purge_idx" ]; then
  fail "expected the plan+apply convergence calls to precede the snap-purge sweep's removal, got order: $(printf '%s\n' "${order_calls[@]}")"
fi

exit "$fails"
