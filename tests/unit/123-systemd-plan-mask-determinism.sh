#!/usr/bin/env bash
# tests/unit/123-systemd-plan-mask-determinism.sh — `ubx-systemd plan`'s
# mask/unmask handling, fully-converged no-op plans, and output
# determinism (byte-identical across repeated runs against unchanged
# inputs) -- SPEC.md §4.3, §6; GitHub issue #27, milestone M2.
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
# mask: a unit transitions unmasked -> masked. mask must be planned;
# no enable/disable action should ALSO fire for the same unit (masking
# makes enabling meaningless -- see this script's own class-rule
# reasoning in bin/ubx-systemd's header).
# =====================================================================
new_mask="$work/new-mask.json"
cat > "$new_mask" <<'EOF'
{"version": 1, "units": [
  {"name": "locked.service", "class": "service", "refuseRestart": false, "hasContent": true, "sha256": "sha1", "enable": true, "mask": true}
]}
EOF
obs_mask="$work/obs-mask.json"
cat > "$obs_mask" <<'EOF'
{"version": 1, "units": [
  {"name": "locked.service", "sha256": "sha1", "enabled": true, "masked": false, "active": true}
]}
EOF
out_mask="$work/out-mask.json"
"$sysd" plan --old-manifest "$empty_old" --new-manifest "$new_mask" --observed-manifest "$obs_mask" --out "$out_mask"
rc=$?
[ "$rc" -eq 0 ] || fail "mask transition plan should exit 0, got rc=$rc"

check_mask="$(python3 - "$out_mask" <<'PYEOF'
import json
import sys

plan = json.load(open(sys.argv[1]))
ops = [a["op"] for a in plan["actions"] if a.get("unit") == "locked.service"]
if "mask" not in ops:
    print(f"expected a 'mask' action, got: {ops}")
    sys.exit(1)
if "enable" in ops or "disable" in ops:
    print(f"masking a unit should not also plan enable/disable for it, got: {ops}")
    sys.exit(1)
print("OK")
PYEOF
)"
[ "$check_mask" = "OK" ] || fail "mask check failed: $check_mask"

# =====================================================================
# unmask: reverse direction.
# =====================================================================
new_unmask="$work/new-unmask.json"
cat > "$new_unmask" <<'EOF'
{"version": 1, "units": [
  {"name": "freed.service", "class": "service", "refuseRestart": false, "hasContent": true, "sha256": "sha2", "enable": true, "mask": false}
]}
EOF
obs_unmask="$work/obs-unmask.json"
cat > "$obs_unmask" <<'EOF'
{"version": 1, "units": [
  {"name": "freed.service", "sha256": "sha2", "enabled": false, "masked": true, "active": false}
]}
EOF
out_unmask="$work/out-unmask.json"
"$sysd" plan --old-manifest "$empty_old" --new-manifest "$new_unmask" --observed-manifest "$obs_unmask" --out "$out_unmask"
rc2=$?
[ "$rc2" -eq 0 ] || fail "unmask transition plan should exit 0, got rc=$rc2"

check_unmask="$(python3 - "$out_unmask" <<'PYEOF'
import json
import sys

plan = json.load(open(sys.argv[1]))
ops = [a["op"] for a in plan["actions"] if a.get("unit") == "freed.service"]
if "unmask" not in ops:
    print(f"expected an 'unmask' action, got: {ops}")
    sys.exit(1)
if "enable" not in ops:
    print(f"unmasked + declared enabled should also plan 'enable', got: {ops}")
    sys.exit(1)
if "start" not in ops:
    print(f"newly unmasked+enabled, currently inactive, should plan 'start', got: {ops}")
    sys.exit(1)
print("OK")
PYEOF
)"
[ "$check_unmask" = "OK" ] || fail "unmask check failed: $check_unmask"

# =====================================================================
# a fully converged input (old == new, observed matches exactly) produces
# an EMPTY action list, daemonReload: false, and exit 0.
# =====================================================================
conv="$work/converged.json"
cat > "$conv" <<'EOF'
{"version": 1, "units": [
  {"name": "steady.service", "class": "service", "refuseRestart": false, "hasContent": true, "sha256": "steady-sha", "enable": true, "mask": false}
]}
EOF
conv_obs="$work/converged-obs.json"
cat > "$conv_obs" <<'EOF'
{"version": 1, "units": [
  {"name": "steady.service", "sha256": "steady-sha", "enabled": true, "masked": false, "active": true}
]}
EOF
conv_out="$work/converged-out.json"
"$sysd" plan --old-manifest "$conv" --new-manifest "$conv" --observed-manifest "$conv_obs" --out "$conv_out"
conv_rc=$?
[ "$conv_rc" -eq 0 ] || fail "a fully converged plan should exit 0, got rc=$conv_rc"

conv_check="$(python3 -c "
import json
plan = json.load(open('$conv_out'))
assert plan == {'version': 1, 'daemonReload': False, 'actions': []}, plan
print('OK')
")"
[ "$conv_check" = "OK" ] || fail "converged plan should be {version:1, daemonReload:false, actions:[]}, check: $conv_check"

# =====================================================================
# determinism: repeated `plan` runs against UNCHANGED inputs are
# byte-identical (mirrors tests/unit/114's same check for bin/ubx-etc).
# =====================================================================
det_out1="$work/det1.json"
det_out2="$work/det2.json"
"$sysd" plan --old-manifest "$empty_old" --new-manifest "$new_mask" --observed-manifest "$obs_mask" --out "$det_out1"
"$sysd" plan --old-manifest "$empty_old" --new-manifest "$new_mask" --observed-manifest "$obs_mask" --out "$det_out2"
diff -u "$det_out1" "$det_out2" > "$work/det-diff.txt" || fail "two plan runs against unchanged inputs are not byte-identical:
$(cat "$work/det-diff.txt")"

stdout1="$("$sysd" plan --old-manifest "$empty_old" --new-manifest "$new_mask" --observed-manifest "$obs_mask")"
stdout2="$("$sysd" plan --old-manifest "$empty_old" --new-manifest "$new_mask" --observed-manifest "$obs_mask")"
[ "$stdout1" = "$stdout2" ] || fail "two plan runs to stdout against unchanged inputs are not identical"

# =====================================================================
# CLI error handling + clean --help text (heredoc/backtick corruption
# guard, mirrors tests/unit/114's own check).
# =====================================================================
missing_arg_rc=0
"$sysd" plan --new-manifest "$new_mask" --observed-manifest "$obs_mask" > /dev/null 2>&1 || missing_arg_rc=$?
[ "$missing_arg_rc" -ne 0 ] || fail "plan without --old-manifest should fail"

nonexistent_rc=0
"$sysd" plan --old-manifest "$work/does-not-exist.json" --new-manifest "$new_mask" --observed-manifest "$obs_mask" \
  > /dev/null 2>&1 || nonexistent_rc=$?
[ "$nonexistent_rc" -ne 0 ] || fail "plan with a nonexistent --old-manifest should fail"

bad_version="$work/bad-version.json"
echo '{"version": 2, "units": []}' > "$bad_version"
bad_version_rc=0
bad_version_out="$("$sysd" plan --old-manifest "$bad_version" --new-manifest "$new_mask" --observed-manifest "$obs_mask" 2>&1)" || bad_version_rc=$?
[ "$bad_version_rc" -ne 0 ] || fail "plan with a manifest 'version' != 1 should fail"
case "$bad_version_out" in
  *"version"*) ;;
  *) fail "bad-version error should mention 'version', got: $bad_version_out" ;;
esac

for args in "--help" "plan --help" "observe --help" "report --help"; do
  # shellcheck disable=SC2086  # intentional word-splitting of $args
  help_err="$("$sysd" $args 2>&1 >/dev/null)"
  [ -z "$help_err" ] || fail "'ubx-systemd $args' wrote to stderr (heredoc/backtick corruption?): $help_err"
done

exit "$fails"
