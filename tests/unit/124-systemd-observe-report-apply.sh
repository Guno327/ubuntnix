#!/usr/bin/env bash
# tests/unit/124-systemd-observe-report-apply.sh — `ubx-systemd observe`,
# `ubx-systemd report`, and `bin/ubx-systemd-apply`'s dry-run/no-op
# executor posture (SPEC.md §4.3, §7; GitHub issue #27, milestone M2).
#
# No live systemd is available in this harness (tests/README.md's "no
# root, no network" posture) -- `ubx-systemd-apply` must default to a safe
# dry-run print, and refuse outright (never silently no-op) if asked to
# --apply without a real systemctl on PATH.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

sysd="$UBX_REPO_ROOT/bin/ubx-systemd"
apply="$UBX_REPO_ROOT/bin/ubx-systemd-apply"
[ -x "$sysd" ] || { echo "FAIL: $sysd does not exist or is not executable" >&2; exit 1; }
[ -x "$apply" ] || { echo "FAIL: $apply does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# =====================================================================
# observe: walks a flat directory of managed unit files + an optional
# --state fixture for enabled/masked/active booleans.
# =====================================================================
unitdir="$work/units"
mkdir -p "$unitdir"
printf '[Service]\nExecStart=/usr/bin/true\n' > "$unitdir/present.service"

state="$work/state.json"
cat > "$state" <<'EOF'
{
  "present.service": {"enabled": true, "masked": false, "active": true},
  "packaged.service": {"enabled": false, "masked": false, "active": false}
}
EOF

observed_out="$work/observed.json"
"$sysd" observe --dir "$unitdir" --state "$state" --out "$observed_out"
rc=$?
[ "$rc" -eq 0 ] || fail "observe should exit 0, got rc=$rc"

check_observe="$(python3 - "$observed_out" "$unitdir/present.service" <<'PYEOF'
import hashlib
import json
import sys

out_path, unit_path = sys.argv[1:3]
data = json.load(open(out_path))
assert data["version"] == 1, data

units = {u["name"]: u for u in data["units"]}
if set(units) != {"present.service", "packaged.service"}:
    print(f"unexpected unit set: {sorted(units)}")
    sys.exit(1)

want_sha = hashlib.sha256(open(unit_path, "rb").read()).hexdigest()
if units["present.service"]["sha256"] != want_sha:
    print(f"present.service sha256 mismatch: {units['present.service']['sha256']} != {want_sha}")
    sys.exit(1)
if units["present.service"]["active"] is not True:
    print(f"present.service should be active per --state, got: {units['present.service']}")
    sys.exit(1)

# packaged.service: named in --state but has no file on disk -> sha256 null.
if units["packaged.service"]["sha256"] is not None:
    print(f"packaged.service (no file present) should have sha256: null, got: {units['packaged.service']}")
    sys.exit(1)

print("OK")
PYEOF
)"
[ "$check_observe" = "OK" ] || fail "observe content check failed: $check_observe"

# -- observe with no --state at all: every found file defaults to
# enabled/masked/active all false.
observed_nostate="$work/observed-nostate.json"
"$sysd" observe --dir "$unitdir" --out "$observed_nostate"
nostate_check="$(python3 -c "
import json
d = json.load(open('$observed_nostate'))
u = next(x for x in d['units'] if x['name'] == 'present.service')
assert u['enabled'] is False and u['masked'] is False and u['active'] is False, u
print('OK')
")"
[ "$nostate_check" = "OK" ] || fail "observe with no --state did not default to all-false: $nostate_check"

# -- a nonexistent --dir is a hard error.
missing_dir_rc=0
"$sysd" observe --dir "$work/does-not-exist" > /dev/null 2>&1 || missing_dir_rc=$?
[ "$missing_dir_rc" -ne 0 ] || fail "observe --dir <missing> should fail"

# =====================================================================
# report: renders a plan JSON as human-readable text.
# =====================================================================
old="$work/old.json"
echo '{"version": 1, "units": []}' > "$old"
new="$work/new.json"
cat > "$new" <<'EOF'
{"version": 1, "units": [
  {"name": "myapp.service", "class": "service", "refuseRestart": false, "hasContent": true, "sha256": "abc", "enable": true, "mask": false}
]}
EOF
observed_empty="$work/observed-empty.json"
echo '{"version": 1, "units": []}' > "$observed_empty"

plan_json="$work/plan.json"
"$sysd" plan --old-manifest "$old" --new-manifest "$new" --observed-manifest "$observed_empty" --out "$plan_json"

report_out="$("$sysd" report --plan "$plan_json")"
case "$report_out" in
  *"myapp.service"*) ;;
  *) fail "report output does not mention myapp.service: $report_out" ;;
esac
case "$report_out" in
  *"action(s) planned"*) ;;
  *) fail "report output does not summarize action count: $report_out" ;;
esac

# -- report on a fully converged (empty-actions) plan says so plainly.
empty_plan="$work/empty-plan.json"
"$sysd" plan --old-manifest "$old" --new-manifest "$old" --observed-manifest "$observed_empty" --out "$empty_plan"
empty_report="$("$sysd" report --plan "$empty_plan")"
case "$empty_report" in
  *"nothing to do"*|*"fully converged"*) ;;
  *) fail "report on an empty plan should say there's nothing to do, got: $empty_report" ;;
esac

# =====================================================================
# ubx-systemd-apply: default dry-run prints the exact command sequence,
# never runs anything.
# =====================================================================
dryrun_out="$("$apply" --plan "$plan_json" --content-dir "$unitdir")"
case "$dryrun_out" in
  *"install"*"myapp.service"*) ;;
  *) fail "dry-run apply output missing an install command for myapp.service: $dryrun_out" ;;
esac
case "$dryrun_out" in
  *"systemctl daemon-reload"*) ;;
  *) fail "dry-run apply output missing 'systemctl daemon-reload': $dryrun_out" ;;
esac
case "$dryrun_out" in
  *"systemctl enable myapp.service"*) ;;
  *) fail "dry-run apply output missing enable: $dryrun_out" ;;
esac
case "$dryrun_out" in
  *"systemctl start myapp.service"*) ;;
  *) fail "dry-run apply output missing start: $dryrun_out" ;;
esac

# -- default mode with no --apply/--dry-run flag is dry-run (never
# actually invokes systemctl even if it happened to exist).
default_out="$("$apply" --plan "$plan_json" --content-dir "$unitdir")"
[ "$default_out" = "$dryrun_out" ] || fail "default mode does not match explicit --dry-run output"

# -- --apply without a real systemctl on PATH refuses outright (never
# silently downgrades to a no-op). Built by mirroring every OTHER binary
# from /usr/bin and /bin (so bash/env/python3/coreutils still resolve)
# into a scratch PATH with systemctl deliberately excluded -- this dev
# sandbox happens to have a real `systemctl` binary present (container
# image default), even though nothing here can actually run systemd
# (tests/README.md's "no root, no network" posture), so a plain PATH
# override would just find it again from wherever it really lives.
fakebin="$work/fakebin"
mkdir -p "$fakebin"
for d in /usr/bin /bin; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b="$(basename "$f")"
    [ "$b" = "systemctl" ] && continue
    [ -e "$fakebin/$b" ] || ln -s "$f" "$fakebin/$b" 2> /dev/null
  done
done
apply_rc=0
apply_err="$(PATH="$fakebin" "$apply" --plan "$plan_json" --content-dir "$unitdir" --apply 2>&1)" || apply_rc=$?
[ "$apply_rc" -ne 0 ] || fail "--apply with no systemctl on PATH should refuse (fail), got exit 0: $apply_err"
case "$apply_err" in
  *systemctl*) ;;
  *) fail "refusal error should mention systemctl, got: $apply_err" ;;
esac

# =====================================================================
# refuse-restart actions never appear as a runnable command in apply
# output -- only a comment marker.
# =====================================================================
socket_new="$work/socket-new.json"
cat > "$socket_new" <<'EOF'
{"version": 1, "units": [
  {"name": "data.socket", "class": "socket", "refuseRestart": true, "hasContent": true, "sha256": "newsha", "enable": true, "mask": false}
]}
EOF
socket_obs="$work/socket-obs.json"
cat > "$socket_obs" <<'EOF'
{"version": 1, "units": [
  {"name": "data.socket", "sha256": "oldsha", "enabled": true, "masked": false, "active": true}
]}
EOF
socket_plan="$work/socket-plan.json"
"$sysd" plan --old-manifest "$old" --new-manifest "$socket_new" --observed-manifest "$socket_obs" --out "$socket_plan"
socket_apply_out="$("$apply" --plan "$socket_plan" --content-dir "$work")"
case "$socket_apply_out" in
  *"systemctl restart data.socket"*) fail "apply output must never contain a restart command for a refuse-restart unit: $socket_apply_out" ;;
esac
case "$socket_apply_out" in
  *"# refuse-restart: data.socket"*) ;;
  *) fail "apply output should carry a refuse-restart comment marker for data.socket: $socket_apply_out" ;;
esac

exit "$fails"
