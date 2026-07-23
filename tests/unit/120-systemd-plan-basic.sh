#!/usr/bin/env bash
# tests/unit/120-systemd-plan-basic.sh — `ubx-systemd plan`'s core
# unit-diff/restart algorithm: create, remove, content-change -> restart,
# enable/disable state change, single coalesced daemon-reload (SPEC.md
# §4.3 switching-table row 1 "generate + diff + restart changed units";
# GitHub issue #27, milestone M2).
#
# Every fixture manifest here is hand-crafted directly in bin/ubx-systemd's
# own manifest schema (see that script's header) -- no `nix` binary or
# real systemd is needed to exercise `plan` itself.
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

unit() {
  # unit NAME CLASS REFUSE HASCONTENT SHA256 ENABLE MASK -> one JSON object
  printf '{"name":"%s","class":"%s","refuseRestart":%s,"hasContent":%s,"sha256":%s,"enable":%s,"mask":%s}' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}
obs_unit() {
  # obs_unit NAME SHA256 ENABLED MASKED ACTIVE -> one JSON object
  printf '{"name":"%s","sha256":%s,"enabled":%s,"masked":%s,"active":%s}' "$1" "$2" "$3" "$4" "$5"
}

# old: keep.service (converged, active+enabled), gone.service (dropped,
# present+active+enabled in observed -> stop+disable+remove).
old="$work/old.json"
cat > "$old" <<EOF
{"version": 1, "units": [
  $(unit keep.service service false true '"aaa"' true false),
  $(unit gone.service service false true '"ggg"' true false)
]}
EOF

# new: keep.service unchanged (no-op); changed.service content differs
# from observed -> update-content + restart (it's active); brandnew.service
# absent from observed -> create + enable + start; disabled.service
# transitions enabled->disabled while inactive (no stop needed).
new="$work/new.json"
cat > "$new" <<EOF
{"version": 1, "units": [
  $(unit keep.service service false true '"aaa"' true false),
  $(unit changed.service service false true '"new-content"' true false),
  $(unit brandnew.service service false true '"brand"' true false),
  $(unit disabled.service service false true '"ddd"' false false)
]}
EOF

observed="$work/observed.json"
cat > "$observed" <<EOF
{"version": 1, "units": [
  $(obs_unit keep.service '"aaa"' true false true),
  $(obs_unit gone.service '"ggg"' true false true),
  $(obs_unit changed.service '"old-content"' true false true),
  $(obs_unit disabled.service '"ddd"' true false false)
]}
EOF

plan_out="$work/plan.json"
"$sysd" plan --old-manifest "$old" --new-manifest "$new" --observed-manifest "$observed" --out "$plan_out"
rc=$?
[ "$rc" -eq 0 ] || fail "plan should exit 0 for a well-formed diff, got rc=$rc"

check="$(python3 - "$plan_out" <<'PYEOF'
import json
import sys

with open(sys.argv[1]) as f:
    plan = json.load(f)

assert plan["version"] == 1, plan
assert plan["daemonReload"] is True, "daemonReload should be true (files changed)"

ops_by_unit = {}
for a in plan["actions"]:
    ops_by_unit.setdefault(a.get("unit"), []).append(a["op"])

# keep.service is fully converged: no action at all.
if "keep.service" in ops_by_unit:
    print(f"keep.service (converged) should have no actions, got: {ops_by_unit['keep.service']}")
    sys.exit(1)

# brandnew.service: created, enabled, started -- never restarted (it never existed).
if ops_by_unit.get("brandnew.service") != ["write-unit-file", "enable", "start"]:
    print(f"brandnew.service: unexpected op sequence: {ops_by_unit.get('brandnew.service')}")
    sys.exit(1)

# changed.service: content changed while active -> update-content + restart,
# never create (it already existed) and never start (restart covers it).
if ops_by_unit.get("changed.service") != ["write-unit-file", "restart"]:
    print(f"changed.service: unexpected op sequence: {ops_by_unit.get('changed.service')}")
    sys.exit(1)
changed_write = next(a for a in plan["actions"] if a["unit"] == "changed.service" and a["op"] == "write-unit-file")
assert changed_write["action"] == "update-content", changed_write

# disabled.service: transitions enabled->disabled while INACTIVE -> disable
# only, no stop (nothing running to stop).
if ops_by_unit.get("disabled.service") != ["disable"]:
    print(f"disabled.service: unexpected op sequence: {ops_by_unit.get('disabled.service')}")
    sys.exit(1)

# gone.service: dropped from new, was active+enabled -> stop, disable, remove.
if ops_by_unit.get("gone.service") != ["remove-unit-file", "stop", "disable"]:
    print(f"gone.service: unexpected op sequence: {ops_by_unit.get('gone.service')}")
    sys.exit(1)

# exactly one daemon-reload action, total, regardless of how many unit
# files changed (create + update + remove all happened above).
reload_count = sum(1 for a in plan["actions"] if a["op"] == "daemon-reload")
if reload_count != 1:
    print(f"expected exactly one daemon-reload action, got {reload_count}")
    sys.exit(1)

print("OK")
PYEOF
)"
check_rc=$?
if [ "$check_rc" -ne 0 ] || [ "$check" != "OK" ]; then fail "plan content check failed: $check"; fi

exit "$fails"
