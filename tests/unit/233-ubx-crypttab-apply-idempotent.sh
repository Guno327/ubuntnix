#!/usr/bin/env bash
# tests/unit/233-ubx-crypttab-apply-idempotent.sh — bin/ubx-crypttab-apply's
# own idempotency + empty-plan posture (SPEC.md §4.3 "Switching and
# convergence" -- activation "touches only what changed"; GitHub issue
# #157, "test coverage for destructive executors"). Mirrors
# tests/unit/230-ubx-secrets-apply-idempotent.sh's own shape (itself
# mirroring tests/unit/138-ubx-systemd-apply-idempotent-teardown.sh) for
# bin/ubx-crypttab-apply's write-crypttab/create-mount/update-mount/
# remove-mount action set. tests/unit/177-ubx-crypttab-apply-executor.sh
# already proves re-PLANNING against a converged real filesystem state is
# a no-op (its own section 3) -- this file adds the executor-level check
# that re-running the SAME compiled plan file a second time is itself
# safe, plus a byte-for-byte "an empty plan touches nothing" snapshot,
# which tests/unit/177 never asserts directly.
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
# 1) first --apply performs the real writes.
# =====================================================================
"$ubx_crypttab_apply" --plan "$plan" --manifest "$manifest" --crypttab-file "$crypttab_file" --units-dir "$units_dir" --apply
rc=$?
[ "$rc" -eq 0 ] || fail "first --apply should exit 0, got $rc"
[ -f "$crypttab_file" ] || fail "first --apply should have created $crypttab_file"
[ -f "$units_dir/mnt-data.mount" ] || fail "first --apply should have created $units_dir/mnt-data.mount"

# =====================================================================
# 2) applying the EXACT SAME (non-empty) compiled plan a second time back
#    to back must still succeed and leave the crypttab file + mount unit
#    byte-for-byte exactly as they were (executor-level idempotency, not
#    just "the planner would no-op on re-plan" -- tests/unit/177's own
#    section 3 already covers the latter via a fresh observe/plan cycle).
# =====================================================================
"$ubx_crypttab_apply" --plan "$plan" --manifest "$manifest" --crypttab-file "$crypttab_file" --units-dir "$units_dir" --apply
rc=$?
[ "$rc" -eq 0 ] || fail "second --apply of the SAME plan should exit 0, got $rc"
if ! python3 - "$crypttab_file" "$manifest" <<'PYEOF'
import json, sys
crypttab_file, manifest_file = sys.argv[1:3]
content = open(crypttab_file, encoding="utf-8").read()
manifest = json.load(open(manifest_file, encoding="utf-8"))
assert content == manifest["crypttabContent"], (content, manifest["crypttabContent"])
PYEOF
then
  fail "$crypttab_file's content changed after re-applying the same plan"
fi
[ "$(stat -c '%a' "$crypttab_file" 2> /dev/null)" = "600" ] || fail "$crypttab_file mode changed after re-applying the same plan"

# =====================================================================
# 3) an empty plan is a real no-op: exit 0, and the already-converged
#    tree (crypttab file + units dir) is byte-for-byte untouched
#    (snapshot before/after, not just "the files we know about still
#    exist").
# =====================================================================
before_snapshot="$( { sha256sum "$crypttab_file"; find "$units_dir" -type f -exec sha256sum {} +; } | sort)"
before_mtime="$(stat -c '%Y' "$crypttab_file")"

empty_manifest="$work/empty-manifest.json"
cat > "$empty_manifest" <<'EOF'
{"version": 1, "crypttabContent": "", "volumes": []}
EOF
observed_converged="$work/observed-converged.json"
"$ubx_crypttab" observe --crypttab-file "$crypttab_file" --units-dir "$units_dir" --out "$observed_converged" \
  || fail "observe (pre-empty-plan) should succeed"
empty_plan="$work/empty-plan.json"
"$ubx_crypttab" plan --manifest "$manifest" --observed "$observed_converged" --out "$empty_plan" \
  || fail "plan (converged state) should succeed"
if ! python3 - "$empty_plan" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["empty"] is True, p
assert p["actions"] == [], p
PYEOF
then
  fail "the seeded 'empty plan' fixture is not actually empty -- got: $(cat "$empty_plan")"
fi

empty_rc=0
"$ubx_crypttab_apply" --plan "$empty_plan" --manifest "$manifest" --crypttab-file "$crypttab_file" --units-dir "$units_dir" --apply > /dev/null 2>&1 || empty_rc=$?
[ "$empty_rc" -eq 0 ] || fail "an empty plan should exit 0, got $empty_rc"

after_snapshot="$( { sha256sum "$crypttab_file"; find "$units_dir" -type f -exec sha256sum {} +; } | sort)"
after_mtime="$(stat -c '%Y' "$crypttab_file")"
[ "$before_snapshot" = "$after_snapshot" ] || fail "an empty plan must not change any file's contents -- before: $before_snapshot / after: $after_snapshot"
[ "$before_mtime" = "$after_mtime" ] || fail "an empty plan must not even re-touch $crypttab_file's mtime (nothing should have been executed at all)"

exit "$fails"
