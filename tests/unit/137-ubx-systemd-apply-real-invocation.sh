#!/usr/bin/env bash
# tests/unit/137-ubx-systemd-apply-real-invocation.sh — a REAL `--apply`
# invocation of `bin/ubx-systemd-apply` (and, end to end, `ubx rebuild
# switch --apply`) against a STUBBED `systemctl` that always succeeds
# (SPEC.md §11 M2 exit criterion; GitHub issue #32).
#
# -- Why this test exists --------------------------------------------------
#
# tests/unit/124-systemd-observe-report-apply.sh already covers
# ubx-systemd-apply's dry-run output and its "refuse --apply with no
# systemctl on PATH" gate, but NEVER exercises the actual --apply code path
# to completion (every real command it would run -- install/daemon-reload/
# stop/disable/mask/enable/start/restart -- succeeding). That gap hid a
# real bug purely in bin/ubx-systemd-apply's own shell, with no systemd/
# QEMU involved at all: `main()`'s `--apply` branch declared `local script`
# and set `trap 'rm -f "$script"' EXIT` (single-quoted, so `$script` is
# resolved lazily, when the EXIT trap actually FIRES). Since `main()` is
# the last thing this script's top level calls, that trap fires only after
# `main` has already RETURNED -- at which point `local script` has gone out
# of scope and is unset again. Under this script's own `set -euo
# pipefail`, referencing that now-unbound `$script` inside the trap is
# itself a fatal error, which clobbers the process's real exit status to 1
# even though every actual command (install/daemon-reload/restart) had
# already succeeded. This is exactly what surfaced end-to-end as
# tests/e2e/020-qemu-switch-e2e.sh's scenario 1 (S1) failing with
# "ubx rebuild switch exited 1" with NO other explanation -- the guest's
# canary-b unit really did get rewritten and restarted; only the trap's own
# unbound-variable death made the whole command look like it failed. Fixed
# by expanding `$script` into the trap string immediately (double-quoted),
# exactly the same "expand now, not at trap-fire time" fix bin/ubx's own
# do_rebuild already uses for its workdir cleanup trap (see that function's
# own SC2064 comment) -- this test pins that fix so a regression here is
# caught at the shell level, with no systemd or QEMU required.
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

apply="$UBX_REPO_ROOT/bin/ubx-systemd-apply"
sysd="$UBX_REPO_ROOT/bin/ubx-systemd"
ubx="$UBX_REPO_ROOT/bin/ubx"
[ -x "$apply" ] || { echo "FAIL: $apply does not exist or is not executable" >&2; exit 1; }
[ -x "$sysd" ] || { echo "FAIL: $sysd does not exist or is not executable" >&2; exit 1; }
[ -x "$ubx" ] || { echo "FAIL: $ubx does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# -- a stub `systemctl` that always succeeds and logs its own argv --------
fakebin="$work/fakebin"
mkdir -p "$fakebin"
cat > "$fakebin/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$STUB_SYSTEMCTL_LOG"
exit 0
EOF
chmod +x "$fakebin/systemctl"
export STUB_SYSTEMCTL_LOG="$work/systemctl.log"
: > "$STUB_SYSTEMCTL_LOG"

# =====================================================================
# 1) ubx-systemd-apply --apply, directly: a real, non-trivial plan
#    (write-unit-file + daemon-reload + restart) run to completion
#    against the stub must exit 0 -- this is the exact call shape
#    (write/reload/restart, real systemctl on PATH) that S1's `ubx
#    rebuild switch --apply` hit inside the switch-loop-proof guest.
# =====================================================================
old="$work/old.json"
new="$work/new.json"
cat > "$old" <<'EOF'
{"version": 1, "units": [
  {"name": "canary.service", "class": "service", "refuseRestart": false, "hasContent": true, "sha256": "old-sha", "enable": true, "mask": false}
]}
EOF
cat > "$new" <<'EOF'
{"version": 1, "units": [
  {"name": "canary.service", "class": "service", "refuseRestart": false, "hasContent": true, "sha256": "new-sha", "enable": true, "mask": false}
]}
EOF
observed="$work/observed.json"
cat > "$observed" <<'EOF'
{"version": 1, "units": [
  {"name": "canary.service", "sha256": "old-sha", "enabled": true, "masked": false, "active": true}
]}
EOF
plan="$work/plan.json"
"$sysd" plan --old-manifest "$old" --new-manifest "$new" --observed-manifest "$observed" --out "$plan" \
  || fail "ubx-systemd plan failed unexpectedly"

content_dir="$work/content"
mkdir -p "$content_dir"
echo "[Service]" > "$content_dir/canary.service"

unit_dir="$work/units"
mkdir -p "$unit_dir"

apply_out="$(PATH="$fakebin:$PATH" "$apply" --plan "$plan" --unit-dir "$unit_dir" --content-dir "$content_dir" --apply 2>&1)"
apply_rc=$?
[ "$apply_rc" -eq 0 ] || fail "ubx-systemd-apply --apply (write+reload+restart, all real commands succeeding) should exit 0, got $apply_rc: $apply_out"
[ -f "$unit_dir/canary.service" ] || fail "--apply should have installed canary.service into --unit-dir"
contains "$(cat "$STUB_SYSTEMCTL_LOG" 2> /dev/null)" "daemon-reload" || fail "stub systemctl should have seen a daemon-reload call"
contains "$(cat "$STUB_SYSTEMCTL_LOG" 2> /dev/null)" "restart canary.service" || fail "stub systemctl should have seen a restart of canary.service"

# =====================================================================
# 2) end to end: `ubx rebuild switch --apply` against a fixture systemd
#    delta, real stub systemctl on PATH -- the exact shape of
#    tests/e2e/020-qemu-switch-e2e.sh's scenario 1 (S1) invocation.
#    Must exit 0.
# =====================================================================
export UBX_SOFT_REBOOT_CMD=true # not exercised here (no image delta); guard anyway
export UBX_NEXTROOT_STAGE_CMD=true # ditto, since issue #55 (nextroot staging)

root="$work/gens"
etc_ref="$work/etc.json"
echo '{"version": 1, "entries": []}' > "$etc_ref"
users_ref="$work/users.json"
echo '{"version": 1, "users": [], "groups": []}' > "$users_ref"

passwd="$work/passwd"
group="$work/group"
shadow="$work/shadow"
: > "$passwd"
: > "$group"
: > "$shadow"

# gen1: register the baseline declaring canary.service (old content).
PATH="$fakebin:$PATH" "$ubx" rebuild switch --root "$root" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --etc-ref "$etc_ref" --systemd-ref "$old" --users-manifest "$users_ref" \
  --apply --systemd-unit-dir "$unit_dir" --systemd-content-dir "$content_dir" \
  --users-out "$work/gen1-users.sh" --passwd "$passwd" --group "$group" --shadow "$shadow" \
  > "$work/gen1.log" 2>&1
gen1_rc=$?
[ "$gen1_rc" -eq 0 ] || fail "'ubx rebuild switch --apply' (gen1) should exit 0, got $gen1_rc: $(cat "$work/gen1.log")"

# gen2: switch to the changed content -- the real write/reload/restart
# chain runs again, against a real (stub) systemctl on PATH.
: > "$STUB_SYSTEMCTL_LOG"
out="$(PATH="$fakebin:$PATH" "$ubx" rebuild switch --root "$root" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --etc-ref "$etc_ref" --systemd-ref "$new" --users-manifest "$users_ref" \
  --apply --systemd-unit-dir "$unit_dir" --systemd-content-dir "$content_dir" \
  --users-out "$work/gen2-users.sh" --passwd "$passwd" --group "$group" --shadow "$shadow" 2>&1)"
gen2_rc=$?
[ "$gen2_rc" -eq 0 ] || fail "'ubx rebuild switch --apply' (gen2, real content change + real systemctl restart) should exit 0, got $gen2_rc: $out"
contains "$(cat "$STUB_SYSTEMCTL_LOG" 2> /dev/null)" "restart canary.service" || fail "gen2 switch should have restarted canary.service via the stub systemctl"

exit "$fails"
