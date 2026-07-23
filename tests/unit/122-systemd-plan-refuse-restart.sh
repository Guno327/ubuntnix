#!/usr/bin/env bash
# tests/unit/122-systemd-plan-refuse-restart.sh — `ubx-systemd plan`'s
# refuse-restart class rule: a changed .socket unit must NEVER be blindly
# restarted (nix/systemd.nix's "Unit classes and the refuse-restart rule";
# GitHub issue #27, milestone M2), plus the defense-in-depth refusal when
# a manifest's own `refuseRestart` flag disagrees with what the unit
# name's suffix implies.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

sysd="$UBX_REPO_ROOT/bin/ubx-systemd"
[ -x "$sysd" ] || { echo "FAIL: $sysd does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

empty_old="$work/empty-old.json"
echo '{"version": 1, "units": []}' > "$empty_old"

# =====================================================================
# a changed .socket unit: content update planned, daemon-reload issued,
# but NO restart/start/stop -- a refuse-restart diagnostic instead.
# =====================================================================
new_socket="$work/new-socket.json"
cat > "$new_socket" <<'EOF'
{"version": 1, "units": [
  {"name": "data.socket", "class": "socket", "refuseRestart": true, "hasContent": true, "sha256": "new-sha", "enable": true, "mask": false}
]}
EOF
observed_socket="$work/observed-socket.json"
cat > "$observed_socket" <<'EOF'
{"version": 1, "units": [
  {"name": "data.socket", "sha256": "old-sha", "enabled": true, "masked": false, "active": true}
]}
EOF

out="$work/plan.json"
"$sysd" plan --old-manifest "$empty_old" --new-manifest "$new_socket" --observed-manifest "$observed_socket" --out "$out"
rc=$?
[ "$rc" -eq 0 ] || fail "plan for a changed refuse-restart-class unit should still exit 0, got rc=$rc"

check="$(python3 - "$out" <<'PYEOF'
import json
import sys

with open(sys.argv[1]) as f:
    plan = json.load(f)

ops = [a["op"] for a in plan["actions"] if a.get("unit") == "data.socket"]
if "restart" in ops:
    print(f"data.socket (socket class) must never be blindly restarted, got ops: {ops}")
    sys.exit(1)
if "start" in ops or "stop" in ops:
    print(f"data.socket (socket class, content-changed only) should not be started/stopped, got ops: {ops}")
    sys.exit(1)
if "write-unit-file" not in ops:
    print(f"data.socket's changed content should still be written, got ops: {ops}")
    sys.exit(1)
if "refuse-restart" not in ops:
    print(f"data.socket should carry a refuse-restart diagnostic action, got ops: {ops}")
    sys.exit(1)
if not plan["daemonReload"]:
    print("daemon-reload should still be issued for the changed unit file")
    sys.exit(1)

refuse = next(a for a in plan["actions"] if a["op"] == "refuse-restart" and a["unit"] == "data.socket")
if refuse.get("class") != "socket":
    print(f"refuse-restart action should carry class 'socket', got: {refuse}")
    sys.exit(1)
if not refuse.get("reason"):
    print(f"refuse-restart action should carry a human-readable reason, got: {refuse}")
    sys.exit(1)

print("OK")
PYEOF
)"
check_rc=$?
if [ "$check_rc" -ne 0 ] || [ "$check" != "OK" ]; then fail "socket refuse-restart check failed: $check"; fi

# =====================================================================
# every documented refuse-restart class (socket, mount, swap, target,
# device, slice) must produce a refuse-restart action, never restart, on
# a content change -- and every restart-safe class (service, timer, path,
# scope) must produce restart, never refuse-restart.
# =====================================================================
check_class() {
  local unit="$1" class="$2" want_refuse="$3"
  local new_m="$work/new-$class.json" obs_m="$work/obs-$class.json" out_m="$work/out-$class.json"
  cat > "$new_m" <<EOF
{"version": 1, "units": [
  {"name": "$unit", "class": "$class", "refuseRestart": $want_refuse, "hasContent": true, "sha256": "new", "enable": true, "mask": false}
]}
EOF
  cat > "$obs_m" <<EOF
{"version": 1, "units": [
  {"name": "$unit", "sha256": "old", "enabled": true, "masked": false, "active": true}
]}
EOF
  "$sysd" plan --old-manifest "$empty_old" --new-manifest "$new_m" --observed-manifest "$obs_m" --out "$out_m" \
    || { fail "plan failed for class $class"; return; }

  local ops
  ops="$(python3 -c "
import json
plan = json.load(open('$out_m'))
print(','.join(a['op'] for a in plan['actions'] if a.get('unit') == '$unit'))
")"
  if [ "$want_refuse" = "true" ]; then
    case ",$ops," in
      *,restart,*) fail "class $class: expected NO restart action, got ops: $ops" ;;
    esac
    case ",$ops," in
      *,refuse-restart,*) ;;
      *) fail "class $class: expected a refuse-restart action, got ops: $ops" ;;
    esac
  else
    case ",$ops," in
      *,restart,*) ;;
      *) fail "class $class: expected a restart action, got ops: $ops" ;;
    esac
    case ",$ops," in
      *,refuse-restart,*) fail "class $class: expected NO refuse-restart action, got ops: $ops" ;;
    esac
  fi
}

check_class "d1.socket" "socket" "true"
check_class "d2.mount" "mount" "true"
check_class "d3.swap" "swap" "true"
check_class "d4.target" "target" "true"
check_class "d5.device" "device" "true"
check_class "d6.slice" "slice" "true"
check_class "d7.service" "service" "false"
check_class "d8.timer" "timer" "false"
check_class "d9.path" "path" "false"
check_class "d10.scope" "scope" "false"

# =====================================================================
# defense-in-depth: a manifest whose own refuseRestart flag disagrees
# with what the unit name's suffix implies must be REFUSED outright
# (fail-closed), not silently trusted.
# =====================================================================
bad_manifest="$work/bad.json"
cat > "$bad_manifest" <<'EOF'
{"version": 1, "units": [
  {"name": "lying.socket", "class": "socket", "refuseRestart": false, "hasContent": true, "sha256": "x", "enable": true, "mask": false}
]}
EOF
empty_observed="$work/empty-observed.json"
echo '{"version": 1, "units": []}' > "$empty_observed"

bad_out="$work/bad-out.json"
bad_stderr="$work/bad-stderr.txt"
"$sysd" plan --old-manifest "$empty_old" --new-manifest "$bad_manifest" --observed-manifest "$empty_observed" --out "$bad_out" \
  > "$bad_stderr" 2>&1
bad_rc=$?
[ "$bad_rc" -ne 0 ] || fail "plan should refuse a manifest whose refuseRestart flag disagrees with its unit class"
[ ! -s "$bad_out" ] || fail "plan must print no output when refusing a mismatched refuseRestart flag"
grep -q 'lying.socket' "$bad_stderr" || fail "refusal error should name the offending unit 'lying.socket', got: $(cat "$bad_stderr")"

# =====================================================================
# a unit name with no recognized class suffix is refused outright too.
# =====================================================================
unknown_class="$work/unknown-class.json"
cat > "$unknown_class" <<'EOF'
{"version": 1, "units": [
  {"name": "weird.frobnicate", "class": "frobnicate", "refuseRestart": false, "hasContent": true, "sha256": "x", "enable": true, "mask": false}
]}
EOF
unknown_rc=0
"$sysd" plan --old-manifest "$empty_old" --new-manifest "$unknown_class" --observed-manifest "$empty_observed" \
  > /dev/null 2>&1 || unknown_rc=$?
[ "$unknown_rc" -ne 0 ] || fail "plan should refuse a unit name with no recognized class suffix"

exit "$fails"
