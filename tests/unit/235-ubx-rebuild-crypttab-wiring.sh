#!/usr/bin/env bash
# tests/unit/235-ubx-rebuild-crypttab-wiring.sh — `ubx rebuild switch|test|
# boot`, `ubx rollback`, and `ubx diff` wiring the crypttab domain into
# bin/ubx's own convergence orchestration, AFTER secrets and BEFORE pro
# (SPEC.md §11 M4 "passphrase-LUKS groundwork (crypttab/fileSystems)",
# §8.3, §4.2 "generated /etc"; GitHub issue #170, groundwork from issue
# #83). Mirrors tests/unit/174-ubx-rebuild-pro-wiring.sh's and
# tests/unit/165-ubx-rebuild-secrets-wiring.sh's own overall shape, adapted
# to bin/ubx-crypttab-apply's own real dry-run/--apply gate (no snap-purge-
# style "test never applies" carve-out here -- see bin/ubx's own
# execute_domains header, "-- crypttab").
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
[ -x "$ubx" ] || { echo "FAIL: $ubx does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

export UBX_SOFT_REBOOT_CMD=true
export UBX_NEXTROOT_STAGE_CMD=true

crypttab_manifest="$work/crypttab-manifest.json"
cat > "$crypttab_manifest" <<'EOF'
{"version": 1,
 "crypttabContent": "data /dev/disk/by-uuid/1234 none luks\n",
 "volumes": [
   {"name": "data", "device": "/dev/disk/by-uuid/1234", "keyFile": "none", "options": "luks",
    "crypttabLine": "data /dev/disk/by-uuid/1234 none luks",
    "mountPoint": "/mnt/data", "fsType": "ext4", "mountOptions": "defaults",
    "mountUnitName": "mnt-data.mount",
    "mountUnitContent": "[Unit]\nDescription=ubuntnix LUKS-backed mount for data\n\n[Mount]\nWhat=/dev/mapper/data\nWhere=/mnt/data\nType=ext4\nOptions=defaults\n\n[Install]\nWantedBy=local-fs.target\n"}
 ]}
EOF

common_flags=(--rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --crypttab-manifest "$crypttab_manifest" \
  --users-out "$work/users-out.sh" --passwd /dev/null --group /dev/null --shadow /dev/null)

# =====================================================================
# 1) `rebuild switch` (no --apply): dry-run mode, nothing written.
# =====================================================================
root1="$work/gens1"
crypttab_file1="$work/crypttab1"
units_dir1="$work/units1"
mkdir -p "$units_dir1"
out="$("$ubx" rebuild switch --root "$root1" --crypttab-file "$crypttab_file1" --crypttab-units-dir "$units_dir1" "${common_flags[@]}" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild switch' (no --apply) should exit 0, got $rc: $out"
contains "$out" "crypttab: 2 action(s) touched" || fail "'rebuild switch' should report the crypttab domain's 2 touched actions (write-crypttab, create-mount), got: $out"
[ ! -e "$crypttab_file1" ] || fail "'rebuild switch' without --apply must not write $crypttab_file1"
[ ! -e "$units_dir1/mnt-data.mount" ] || fail "'rebuild switch' without --apply must not write $units_dir1/mnt-data.mount"

# =====================================================================
# 2) `rebuild switch --apply`: real convergence -- the declared line lands
#    in --crypttab-file and the .mount unit lands in --crypttab-units-dir.
# =====================================================================
root2="$work/gens2"
crypttab_file2="$work/crypttab2"
units_dir2="$work/units2"
out="$("$ubx" rebuild switch --root "$root2" --crypttab-file "$crypttab_file2" --crypttab-units-dir "$units_dir2" --apply "${common_flags[@]}" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild switch --apply' should exit 0, got $rc: $out"
[ -f "$crypttab_file2" ] || fail "'rebuild switch --apply' should have written $crypttab_file2"
[ "$(cat "$crypttab_file2" 2> /dev/null)" = "data /dev/disk/by-uuid/1234 none luks" ] || fail "written crypttab content mismatch: $(cat "$crypttab_file2" 2> /dev/null)"
[ -f "$units_dir2/mnt-data.mount" ] || fail "'rebuild switch --apply' should have installed $units_dir2/mnt-data.mount"

# =====================================================================
# 3) `rebuild test --apply`: crypttab DOES apply for real under `test` too
#    (writing /etc/crypttab and a .mount file is retry-safe) -- see
#    bin/ubx's execute_domains header, "-- crypttab".
# =====================================================================
root3="$work/gens3"
crypttab_file3="$work/crypttab3"
units_dir3="$work/units3"
out="$("$ubx" rebuild test --root "$root3" --crypttab-file "$crypttab_file3" --crypttab-units-dir "$units_dir3" --apply "${common_flags[@]}" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild test --apply' should exit 0, got $rc: $out"
[ -f "$crypttab_file3" ] || fail "'rebuild test --apply' should also have written $crypttab_file3"

# =====================================================================
# 4) `rebuild boot`: never activates anything live (boot never calls
#    execute_domains at all).
# =====================================================================
root4="$work/gens4"
crypttab_file4="$work/crypttab4"
units_dir4="$work/units4"
out="$("$ubx" rebuild boot --root "$root4" --crypttab-file "$crypttab_file4" --crypttab-units-dir "$units_dir4" --apply "${common_flags[@]}" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild boot --apply' should exit 0, got $rc: $out"
[ ! -e "$crypttab_file4" ] || fail "'rebuild boot' must never write $crypttab_file4"

# =====================================================================
# 5) omitting --crypttab-manifest entirely: the domain is skipped, exactly
#    like every other omitted domain ref.
# =====================================================================
root5="$work/gens5"
crypttab_file5="$work/crypttab5"
units_dir5="$work/units5"
out="$("$ubx" rebuild switch --root "$root5" --crypttab-file "$crypttab_file5" --crypttab-units-dir "$units_dir5" --apply \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --users-out "$work/users-out5.sh" --passwd /dev/null --group /dev/null --shadow /dev/null 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild switch --apply' with no --crypttab-manifest should exit 0, got $rc: $out"
contains "$out" "crypttab: nothing declared" || fail "'rebuild switch' with no --crypttab-manifest declared should report 'nothing declared', got: $out"
[ ! -e "$crypttab_file5" ] || fail "'rebuild switch' with no --crypttab-manifest declared must not create $crypttab_file5 at all"

# =====================================================================
# 6) `ubx rollback` re-converges the crypttab domain too, reading the
#    generation's own crypttab-manifest reference back off the sidecar
#    file.
# =====================================================================
root6="$work/gens6"
crypttab_file6="$work/crypttab6"
units_dir6="$work/units6"
out="$("$ubx" rebuild switch --root "$root6" --crypttab-file "$crypttab_file6" --crypttab-units-dir "$units_dir6" --apply "${common_flags[@]}" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "seeding generation 1 for rollback should exit 0, got $rc: $out"

out2="$("$ubx" rebuild switch --root "$root6" --crypttab-file "$crypttab_file6" --crypttab-units-dir "$units_dir6" --apply "${common_flags[@]}" 2>&1)"
rc2=$?
[ "$rc2" -eq 0 ] || fail "seeding generation 2 for rollback should exit 0, got $rc2: $out2"

rm -f "$crypttab_file6"

# Absent an explicit --crypttab-observed, plan_domains' own default
# SYNTHESIZES the observed state from the OLD generation's own declared
# manifest (assuming it is already fully converged -- see
# crypttab_synthesize_observed's own comment in bin/ubx), which would never
# notice the file this test just deleted by hand. A real, live observe of
# the (now-empty) crypttab_file6 is what makes this scenario re-plan a real
# write-crypttab, exactly the observed-override seam
# --secrets-observed/--etc-observed/--systemd-observed already establish
# for their own domains (see tests/unit/165's own scenario 6).
crypttab_observed6="$work/crypttab-observed6.json"
"$UBX_REPO_ROOT/bin/ubx-crypttab" observe --crypttab-file "$crypttab_file6" --units-dir "$units_dir6" --out "$crypttab_observed6"

rollback_out="$("$ubx" rollback --root "$root6" --crypttab-file "$crypttab_file6" --crypttab-units-dir "$units_dir6" --apply \
  --crypttab-observed "$crypttab_observed6" \
  --users-out "$work/rollback-users.sh" --passwd /dev/null --group /dev/null --shadow /dev/null 2>&1)"
rollback_rc=$?
[ "$rollback_rc" -eq 0 ] || fail "'ubx rollback --apply' should exit 0, got $rollback_rc: $rollback_out"
contains "$rollback_out" "crypttab:" || fail "'ubx rollback' should mention the crypttab domain, got: $rollback_out"
[ -f "$crypttab_file6" ] || fail "'ubx rollback --apply' should have re-written $crypttab_file6"

# =====================================================================
# 7) `ubx diff` reports the crypttab domain in its verbose output.
# =====================================================================
diff_out="$("$ubx" diff --root "$root6" 2>&1)"
diff_rc=$?
[ "$diff_rc" -eq 0 ] || fail "'ubx diff' should exit 0, got $diff_rc: $diff_out"
contains "$diff_out" "crypttab:" || fail "'ubx diff' should mention the crypttab domain, got: $diff_out"

exit "$fails"
