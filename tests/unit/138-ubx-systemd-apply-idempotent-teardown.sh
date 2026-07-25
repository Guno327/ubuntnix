#!/usr/bin/env bash
# tests/unit/138-ubx-systemd-apply-idempotent-teardown.sh -- removing a unit
# whose live state is already gone must still converge cleanly (SPEC.md §11
# M2 exit criterion; GitHub issue #32).
#
# -- Why this test exists --------------------------------------------------
#
# When a rollback/switch REMOVES a unit, ubx-systemd-apply emits `systemctl
# stop`/`disable` for it. If that unit is not loaded -- e.g. it was never
# started this boot, or (as in the switch-loop e2e) its transient
# /run/systemd/system unit was wiped by a reboot -- `systemctl stop` exits 5
# ("Unit ... not loaded") and `disable` exits non-zero too. The desired
# end-state (not running, not enabled, file removed) already holds, so this
# must NOT abort convergence. This surfaced end to end as
# tests/e2e/020-qemu-switch-e2e.sh's scenario 4 failing with
# "ubx rollback exited 5" after a real reboot wiped canary-c's /run unit.
# Best-effort teardown for stop/disable pins that; install/daemon-reload/
# enable/start/restart/mask stay fatal (a separate assertion below).
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
[ -x "$apply" ] || { echo "FAIL: $apply does not exist or is not executable" >&2; exit 1; }
[ -x "$sysd" ] || { echo "FAIL: $sysd does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# -- a stub `systemctl` that FAILS `stop`/`disable` (as a not-loaded unit
#    makes the real one do) but succeeds otherwise, logging its argv -------
fakebin="$work/fakebin"
mkdir -p "$fakebin"
cat > "$fakebin/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$STUB_SYSTEMCTL_LOG"
case "$1" in
  stop)    echo "Failed to stop $2: Unit $2 not loaded." >&2; exit 5 ;;
  disable) echo "Failed to disable $2: does not exist." >&2;  exit 1 ;;
  *)       exit 0 ;;
esac
EOF
chmod +x "$fakebin/systemctl"
export STUB_SYSTEMCTL_LOG="$work/systemctl.log"
: > "$STUB_SYSTEMCTL_LOG"

# =====================================================================
# 1) REMOVE a unit whose live state is gone: old declares canary.service,
#    new declares nothing, observed shows it active+enabled -> the plan
#    stops/disables/removes it. With a stub systemctl that fails stop (5)
#    and disable, --apply must STILL exit 0 (idempotent teardown).
# =====================================================================
old="$work/old.json"
new="$work/new.json"
cat > "$old" <<'EOF'
{"version": 1, "units": [
  {"name": "canary.service", "class": "service", "refuseRestart": false, "hasContent": true, "sha256": "s", "enable": true, "mask": false}
]}
EOF
cat > "$new" <<'EOF'
{"version": 1, "units": []}
EOF
observed="$work/observed.json"
cat > "$observed" <<'EOF'
{"version": 1, "units": [
  {"name": "canary.service", "sha256": "s", "enabled": true, "masked": false, "active": true}
]}
EOF
plan="$work/plan.json"
"$sysd" plan --old-manifest "$old" --new-manifest "$new" --observed-manifest "$observed" --out "$plan" \
  || fail "ubx-systemd plan (removal) failed unexpectedly"

unit_dir="$work/units"
mkdir -p "$unit_dir"
: > "$unit_dir/canary.service"

out="$(PATH="$fakebin:$PATH" "$apply" --plan "$plan" --unit-dir "$unit_dir" --apply 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "--apply of a removal must tolerate stop/disable of a not-loaded unit and exit 0, got $rc: $out"
contains "$(cat "$STUB_SYSTEMCTL_LOG" 2> /dev/null)" "stop canary.service" || fail "the stub systemctl should have been asked to stop canary.service"
[ -f "$unit_dir/canary.service" ] && fail "--apply should have removed canary.service's unit file from --unit-dir"

# =====================================================================
# 2) A genuinely fatal op still aborts: a plan that installs a unit whose
#    content file is missing must NOT be swallowed (exit non-zero).
# =====================================================================
old2="$work/old2.json"
new2="$work/new2.json"
cat > "$old2" <<'EOF'
{"version": 1, "units": [
  {"name": "canary.service", "class": "service", "refuseRestart": false, "hasContent": true, "sha256": "a", "enable": true, "mask": false}
]}
EOF
cat > "$new2" <<'EOF'
{"version": 1, "units": [
  {"name": "canary.service", "class": "service", "refuseRestart": false, "hasContent": true, "sha256": "b", "enable": true, "mask": false}
]}
EOF
observed2="$work/observed2.json"
cat > "$observed2" <<'EOF'
{"version": 1, "units": [
  {"name": "canary.service", "sha256": "a", "enabled": true, "masked": false, "active": true}
]}
EOF
plan2="$work/plan2.json"
"$sysd" plan --old-manifest "$old2" --new-manifest "$new2" --observed-manifest "$observed2" --out "$plan2" \
  || fail "ubx-systemd plan (change) failed unexpectedly"

empty_content="$work/empty-content"
mkdir -p "$empty_content"   # deliberately does NOT contain canary.service
if PATH="$fakebin:$PATH" "$apply" --plan "$plan2" --unit-dir "$unit_dir" --content-dir "$empty_content" --apply > /dev/null 2>&1; then
  fail "--apply must still FAIL when a write-unit-file's content file is missing (fatal ops not swallowed)"
fi

exit "$fails"
