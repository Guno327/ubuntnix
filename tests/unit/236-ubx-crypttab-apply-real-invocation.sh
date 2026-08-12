#!/usr/bin/env bash
# tests/unit/236-ubx-crypttab-apply-real-invocation.sh — a REAL `--apply`
# invocation of `bin/ubx-crypttab-apply` (and, end to end, `ubx rebuild
# switch --apply`), run all the way to completion against real temp
# `--crypttab-file`/`--units-dir` paths (GitHub issue #170; groundwork from
# issue #83). Analogue of
# tests/unit/137-ubx-systemd-apply-real-invocation.sh: that test exists
# because bin/ubx-systemd-apply's dry-run/refusal coverage never exercised
# its actual --apply code path to completion, which hid a real bug. This
# test is the same kind of proof for the crypttab domain, and is the exact
# test tests/unit/234-docs-status-consistency.sh's section 5 cites as
# evidence bin/ubx really invokes bin/ubx-crypttab-apply once this domain
# is wired.
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

apply="$UBX_REPO_ROOT/bin/ubx-crypttab-apply"
plan_tool="$UBX_REPO_ROOT/bin/ubx-crypttab"
ubx="$UBX_REPO_ROOT/bin/ubx"
[ -x "$apply" ] || { echo "FAIL: $apply does not exist or is not executable" >&2; exit 1; }
[ -x "$plan_tool" ] || { echo "FAIL: $plan_tool does not exist or is not executable" >&2; exit 1; }
[ -x "$ubx" ] || { echo "FAIL: $ubx does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# =====================================================================
# 1) ubx-crypttab-apply --apply, directly: a real, non-trivial plan
#    (write-crypttab + create-mount + update-mount + remove-mount) run to
#    completion against real temp paths must exit 0 -- the exact call
#    shape bin/ubx's execute_domains uses.
# =====================================================================
old_manifest="$work/old.json"
new_manifest="$work/new.json"
cat > "$old_manifest" <<'EOF'
{"version": 1,
 "crypttabContent": "data /dev/disk/by-uuid/1234 none luks\nstale /dev/disk/by-uuid/9999 none luks\n",
 "volumes": [
   {"name": "data", "device": "/dev/disk/by-uuid/1234", "keyFile": "none", "options": "luks",
    "crypttabLine": "data /dev/disk/by-uuid/1234 none luks",
    "mountPoint": "/mnt/data", "fsType": "ext4", "mountOptions": "defaults",
    "mountUnitName": "mnt-data.mount", "mountUnitContent": "[Mount]\nWhat=/dev/mapper/data\nWhere=/mnt/data\n"},
   {"name": "stale", "device": "/dev/disk/by-uuid/9999", "keyFile": "none", "options": "luks",
    "crypttabLine": "stale /dev/disk/by-uuid/9999 none luks",
    "mountPoint": "/mnt/stale", "fsType": "ext4", "mountOptions": "defaults",
    "mountUnitName": "mnt-stale.mount", "mountUnitContent": "[Mount]\nWhat=/dev/mapper/stale\nWhere=/mnt/stale\n"}
 ]}
EOF
cat > "$new_manifest" <<'EOF'
{"version": 1,
 "crypttabContent": "data /dev/disk/by-uuid/1234 none luks,discard\n",
 "volumes": [
   {"name": "data", "device": "/dev/disk/by-uuid/1234", "keyFile": "none", "options": "luks,discard",
    "crypttabLine": "data /dev/disk/by-uuid/1234 none luks,discard",
    "mountPoint": "/mnt/data", "fsType": "ext4", "mountOptions": "defaults",
    "mountUnitName": "mnt-data.mount", "mountUnitContent": "[Mount]\nWhat=/dev/mapper/data\nWhere=/mnt/data\nOptions=discard\n"}
 ]}
EOF

observed="$work/observed.json"
cat > "$observed" <<'EOF'
{"version": 1,
 "crypttabContent": "data /dev/disk/by-uuid/1234 none luks\nstale /dev/disk/by-uuid/9999 none luks\n",
 "units": {
   "mnt-data.mount": "[Mount]\nWhat=/dev/mapper/data\nWhere=/mnt/data\n",
   "mnt-stale.mount": "[Mount]\nWhat=/dev/mapper/stale\nWhere=/mnt/stale\n"
 }}
EOF

plan="$work/plan.json"
"$plan_tool" plan --manifest "$new_manifest" --old-manifest "$old_manifest" --observed "$observed" --out "$plan" \
  || fail "ubx-crypttab plan failed unexpectedly"
contains "$(cat "$plan")" '"write-crypttab"' || fail "plan should contain a write-crypttab action"
contains "$(cat "$plan")" '"update-mount"' || fail "plan should contain an update-mount action for mnt-data.mount"
contains "$(cat "$plan")" '"remove-mount"' || fail "plan should contain a remove-mount action for mnt-stale.mount"

crypttab_file="$work/crypttab"
units_dir="$work/units"
mkdir -p "$units_dir"
# Seed the "observed" units directory for real, so remove-mount has a real
# file to delete.
printf '[Mount]\nWhat=/dev/mapper/stale\nWhere=/mnt/stale\n' > "$units_dir/mnt-stale.mount"

apply_out="$("$apply" --plan "$plan" --manifest "$new_manifest" --crypttab-file "$crypttab_file" --units-dir "$units_dir" --apply 2>&1)"
apply_rc=$?
[ "$apply_rc" -eq 0 ] || fail "ubx-crypttab-apply --apply (write+create/update+remove, all real filesystem calls) should exit 0, got $apply_rc: $apply_out"
[ -f "$crypttab_file" ] || fail "--apply should have written $crypttab_file"
[ "$(cat "$crypttab_file")" = "data /dev/disk/by-uuid/1234 none luks,discard" ] || fail "written crypttab content mismatch: $(cat "$crypttab_file")"
[ -f "$units_dir/mnt-data.mount" ] || fail "--apply should have installed mnt-data.mount"
contains "$(cat "$units_dir/mnt-data.mount")" "Options=discard" || fail "mnt-data.mount should carry the updated content"
[ ! -e "$units_dir/mnt-stale.mount" ] || fail "--apply should have removed mnt-stale.mount (dropped from the new manifest)"

# Idempotency: re-applying the SAME plan against the now-converged real
# state must still exit 0 and change nothing further.
apply_out2="$("$apply" --plan "$plan" --manifest "$new_manifest" --crypttab-file "$crypttab_file" --units-dir "$units_dir" --apply 2>&1)"
apply_rc2=$?
[ "$apply_rc2" -eq 0 ] || fail "re-applying the same plan should still exit 0, got $apply_rc2: $apply_out2"

# =====================================================================
# 2) end to end: `ubx rebuild switch --apply` really invokes
#    bin/ubx-crypttab-apply and lands the declared crypttab line + mount
#    unit on real temp paths.
# =====================================================================
export UBX_SOFT_REBOOT_CMD=true
export UBX_NEXTROOT_STAGE_CMD=true

root="$work/gens"
e2e_crypttab_file="$work/e2e-crypttab"
e2e_units_dir="$work/e2e-units"
out="$("$ubx" rebuild switch --root "$root" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --crypttab-manifest "$new_manifest" \
  --crypttab-file "$e2e_crypttab_file" --crypttab-units-dir "$e2e_units_dir" \
  --apply --users-out "$work/users-out.sh" --passwd /dev/null --group /dev/null --shadow /dev/null 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'ubx rebuild switch --apply' should exit 0, got $rc: $out"
[ -f "$e2e_crypttab_file" ] || fail "'ubx rebuild switch --apply' should have written $e2e_crypttab_file via bin/ubx-crypttab-apply"
[ -f "$e2e_units_dir/mnt-data.mount" ] || fail "'ubx rebuild switch --apply' should have installed $e2e_units_dir/mnt-data.mount via bin/ubx-crypttab-apply"

exit "$fails"
