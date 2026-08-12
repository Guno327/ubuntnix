#!/usr/bin/env bash
# tests/unit/177-ubx-crypttab-apply-executor.sh — bin/ubx-crypttab-apply's
# own executor: applies a plan's write-crypttab/create-mount/update-mount/
# remove-mount actions to a temp crypttab file + temp units dir, and
# --dry-run never touches either (SPEC.md §11 M4 "passphrase-LUKS
# groundwork (crypttab/fileSystems)"; GitHub issue #83, milestone M4).
# Mirrors tests/unit/173-ubx-pro-apply-executor.sh's own shape.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

ubx_crypttab="$UBX_REPO_ROOT/bin/ubx-crypttab"
ubx_crypttab_apply="$UBX_REPO_ROOT/bin/ubx-crypttab-apply"
[ -x "$ubx_crypttab" ] || { echo "FAIL: $ubx_crypttab does not exist or is not executable" >&2; exit 1; }
[ -x "$ubx_crypttab_apply" ] || { echo "FAIL: $ubx_crypttab_apply does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

manifest="$work/manifest.json"
cat > "$manifest" <<'EOF'
{
  "version": 1,
  "crypttabContent": "data /dev/disk/by-uuid/00000000-0000-0000-0000-000000000000 none luks,discard\n",
  "volumes": [
    {
      "name": "data",
      "device": "/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000",
      "keyFile": "none",
      "options": "luks,discard",
      "crypttabLine": "data /dev/disk/by-uuid/00000000-0000-0000-0000-000000000000 none luks,discard",
      "mountPoint": "/mnt/data",
      "fsType": "ext4",
      "mountOptions": "defaults",
      "mountUnitName": "mnt-data.mount",
      "mountUnitContent": "[Unit]\nDescription=ubuntnix LUKS-backed mount for \"data\"\nAfter=systemd-cryptsetup@data.service\nRequires=systemd-cryptsetup@data.service\n\n[Mount]\nWhat=/dev/mapper/data\nWhere=/mnt/data\nType=ext4\nOptions=defaults\n\n[Install]\nWantedBy=local-fs.target\n"
    }
  ]
}
EOF

observed_empty="$work/observed-empty.json"
cat > "$observed_empty" <<'EOF'
{"version": 1, "crypttabContent": "", "units": {}}
EOF

plan="$work/plan.json"
"$ubx_crypttab" plan --manifest "$manifest" --observed "$observed_empty" --out "$plan" \
  || fail "seeding the plan should succeed"

crypttab_file="$work/etc-crypttab"
units_dir="$work/units"

# =====================================================================
# 1) --dry-run (default): prints commands, never touches the real
#    filesystem targets.
# =====================================================================
dryrun_out="$("$ubx_crypttab_apply" --plan "$plan" --manifest "$manifest" --crypttab-file "$crypttab_file" --units-dir "$units_dir" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "--dry-run should exit 0, got $rc: $dryrun_out"
[ ! -e "$crypttab_file" ] || fail "--dry-run must never create $crypttab_file"
[ ! -e "$units_dir/mnt-data.mount" ] || fail "--dry-run must never create $units_dir/mnt-data.mount"
case "$dryrun_out" in
  *"$crypttab_file"*) ;;
  *) fail "--dry-run output should mention the target crypttab path, got: $dryrun_out" ;;
esac
case "$dryrun_out" in
  *"mnt-data.mount"*) ;;
  *) fail "--dry-run output should mention the target mount unit, got: $dryrun_out" ;;
esac

# =====================================================================
# 2) --apply: real convergence -- crypttab file + mount unit are written
#    with the manifest's exact bytes.
# =====================================================================
"$ubx_crypttab_apply" --plan "$plan" --manifest "$manifest" --crypttab-file "$crypttab_file" --units-dir "$units_dir" --apply
rc=$?
[ "$rc" -eq 0 ] || fail "--apply should exit 0, got $rc"

[ -f "$crypttab_file" ] || fail "--apply should have created $crypttab_file"
if ! python3 - "$crypttab_file" "$manifest" <<'PYEOF'
import json, sys
crypttab_file, manifest_file = sys.argv[1:3]
content = open(crypttab_file, encoding="utf-8").read()
manifest = json.load(open(manifest_file, encoding="utf-8"))
assert content == manifest["crypttabContent"], (content, manifest["crypttabContent"])
PYEOF
then
  fail "$crypttab_file's content does not exactly match the manifest's crypttabContent"
fi

unit_file="$units_dir/mnt-data.mount"
[ -f "$unit_file" ] || fail "--apply should have created $unit_file"
if ! python3 - "$unit_file" "$manifest" <<'PYEOF'
import json, sys
unit_file, manifest_file = sys.argv[1:3]
content = open(unit_file, encoding="utf-8").read()
manifest = json.load(open(manifest_file, encoding="utf-8"))
assert content == manifest["volumes"][0]["mountUnitContent"], (content, manifest["volumes"][0]["mountUnitContent"])
PYEOF
then
  fail "$unit_file's content does not exactly match the manifest's mountUnitContent"
fi

# crypttab file must not be world-readable (crypttab(5) may carry a
# keyfile path in a real deployment even though this issue's own entries
# never do).
perm="$(stat -c '%a' "$crypttab_file")"
[ "$perm" = "600" ] || fail "expected $crypttab_file to be mode 0600, got $perm"

# =====================================================================
# 3) re-planning against the now-converged real filesystem state (via a
#    real `observe`) is a real no-op -- proves the planner + executor
#    together actually converge, not just independently claim to.
# =====================================================================
observed_real="$work/observed-real.json"
"$ubx_crypttab" observe --crypttab-file "$crypttab_file" --units-dir "$units_dir" --out "$observed_real" \
  || fail "observe (post-apply) should succeed"

plan2="$work/plan2.json"
"$ubx_crypttab" plan --manifest "$manifest" --observed "$observed_real" --out "$plan2" \
  || fail "plan (post-apply) should succeed"
if ! python3 - "$plan2" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["empty"] is True, p
PYEOF
then
  fail "re-planning against the just-applied real filesystem state should be a no-op -- got: $(cat "$plan2")"
fi

# =====================================================================
# 4) remove-mount: applying a plan that drops the volume actually deletes
#    the unit file; idempotent on a second apply.
# =====================================================================
empty_manifest="$work/empty-manifest.json"
cat > "$empty_manifest" <<'EOF'
{"version": 1, "crypttabContent": "", "volumes": []}
EOF

plan_remove="$work/plan-remove.json"
"$ubx_crypttab" plan --manifest "$empty_manifest" --old-manifest "$manifest" --observed "$observed_real" --out "$plan_remove" \
  || fail "plan (removal) should succeed"

"$ubx_crypttab_apply" --plan "$plan_remove" --manifest "$empty_manifest" --crypttab-file "$crypttab_file" --units-dir "$units_dir" --apply
rc=$?
[ "$rc" -eq 0 ] || fail "--apply (removal) should exit 0, got $rc"
[ ! -e "$unit_file" ] || fail "--apply (removal) should have deleted $unit_file"

# idempotent: applying the same removal plan again is still a clean exit.
"$ubx_crypttab_apply" --plan "$plan_remove" --manifest "$empty_manifest" --crypttab-file "$crypttab_file" --units-dir "$units_dir" --apply
rc=$?
[ "$rc" -eq 0 ] || fail "--apply (removal, second time) should exit 0 idempotently, got $rc"

# =====================================================================
# 5) applying the ORIGINAL create/write plan a SECOND time, back to back,
#    must still exit 0 and leave the crypttab/mount-unit bytes exactly as
#    they were (SPEC.md §4.3: activation "touches only what changed";
#    GitHub issue #157). Re-seeds fresh crypttab-file/units-dir so this
#    section is independent of section 4's removal above.
# =====================================================================
reapply_crypttab="$work/reapply-crypttab"
reapply_units="$work/reapply-units"

"$ubx_crypttab_apply" --plan "$plan" --manifest "$manifest" --crypttab-file "$reapply_crypttab" --units-dir "$reapply_units" --apply
rc=$?
[ "$rc" -eq 0 ] || fail "first --apply (reapply fixture) should exit 0, got $rc"

"$ubx_crypttab_apply" --plan "$plan" --manifest "$manifest" --crypttab-file "$reapply_crypttab" --units-dir "$reapply_units" --apply
rc=$?
[ "$rc" -eq 0 ] || fail "applying the SAME (non-removal) plan a second time should exit 0, got $rc"

if ! python3 - "$reapply_crypttab" "$manifest" <<'PYEOF'
import json, sys
crypttab_file, manifest_file = sys.argv[1:3]
content = open(crypttab_file, encoding="utf-8").read()
manifest = json.load(open(manifest_file, encoding="utf-8"))
assert content == manifest["crypttabContent"], (content, manifest["crypttabContent"])
PYEOF
then
  fail "re-applying the same plan a second time must not corrupt $reapply_crypttab's content"
fi
[ "$(stat -c '%a' "$reapply_crypttab")" = "600" ] || fail "re-applying the same plan a second time must not change $reapply_crypttab's mode"

# =====================================================================
# 6) an empty plan (no actions) is a real no-op: exit 0, and an
#    already-converged crypttab-file/units-dir tree is left byte-for-byte
#    untouched (snapshot before/after, not just "still exists").
# =====================================================================
before_crypttab_sha="$(sha256sum "$reapply_crypttab" | cut -d' ' -f1)"
before_unit_sha="$(sha256sum "$reapply_units/mnt-data.mount" | cut -d' ' -f1)"
# mtime has only whole-second resolution via `stat -c '%Y'`; sleep past a
# second boundary first so a regression that spuriously re-touches (but
# does not otherwise corrupt) the file is still caught below.
sleep 1
before_crypttab_mtime="$(stat -c '%Y' "$reapply_crypttab")"

empty_actions_plan="$work/empty-actions-plan.json"
echo '{"version": 1, "empty": true, "actions": []}' > "$empty_actions_plan"
empty_rc=0
"$ubx_crypttab_apply" --plan "$empty_actions_plan" --manifest "$manifest" --crypttab-file "$reapply_crypttab" --units-dir "$reapply_units" --apply > /dev/null 2>&1 || empty_rc=$?
[ "$empty_rc" -eq 0 ] || fail "an empty (no-actions) plan should exit 0, got $empty_rc"

after_crypttab_sha="$(sha256sum "$reapply_crypttab" | cut -d' ' -f1)"
after_unit_sha="$(sha256sum "$reapply_units/mnt-data.mount" | cut -d' ' -f1)"
after_crypttab_mtime="$(stat -c '%Y' "$reapply_crypttab")"
[ "$before_crypttab_sha" = "$after_crypttab_sha" ] || fail "an empty plan must not change $reapply_crypttab's content"
[ "$before_unit_sha" = "$after_unit_sha" ] || fail "an empty plan must not change $reapply_units/mnt-data.mount's content"
[ "$before_crypttab_mtime" = "$after_crypttab_mtime" ] || fail "an empty plan must not even re-touch $reapply_crypttab's mtime (nothing should have been executed at all)"

exit "$fails"
