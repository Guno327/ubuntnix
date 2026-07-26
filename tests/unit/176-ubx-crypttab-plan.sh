#!/usr/bin/env bash
# tests/unit/176-ubx-crypttab-plan.sh — bin/ubx-crypttab's own convergence
# planner: a declared LUKS volume renders the correct /etc/crypttab entry
# AND the correct mount unit, and the planner is diff-driven (unchanged
# declaration -> no-op) (SPEC.md §11 M4 "passphrase-LUKS groundwork
# (crypttab/fileSystems)"; GitHub issue #83, milestone M4 — the issue's own
# acceptance criteria). Mirrors tests/unit/172-ubx-pro-plan.sh's own shape
# for bin/ubx-pro.
#
# The manifest fixtures below are hand-crafted to EXACTLY the schema
# nix/crypttab.nix's `render` produces for the given declaration (see that
# file's header for the crypttabLine/mountUnitName/mountUnitContent
# formulas) — this harness has no `nix` binary (tests/unit/021-flake-
# purity.sh's own documented limitation), so this is the same posture
# tests/unit/172 already takes for nix/pro.nix's manifest schema.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

ubx_crypttab="$UBX_REPO_ROOT/bin/ubx-crypttab"
[ -x "$ubx_crypttab" ] || { echo "FAIL: $ubx_crypttab does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# =====================================================================
# 1) a declared LUKS volume ("data", device by-uuid, passphrase (keyFile
#    "none"), options "luks,discard", mountPoint "/mnt/data") renders
#    EXACTLY the crypttab(5) entry and mount unit nix/crypttab.nix's
#    header documents.
# =====================================================================
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
      "mountUnitContent": "[Unit]\nDescription=ubuntnix LUKS-backed mount for \"data\" (SPEC.md's \"Full-disk encryption\"; crypttab groundwork, issue #83, M4)\nAfter=systemd-cryptsetup@data.service\nRequires=systemd-cryptsetup@data.service\n\n[Mount]\nWhat=/dev/mapper/data\nWhere=/mnt/data\nType=ext4\nOptions=defaults\n\n[Install]\nWantedBy=local-fs.target\n"
    }
  ]
}
EOF

if ! python3 - "$manifest" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
v = m["volumes"][0]
# crypttab(5) column order: name device keyfile options.
assert v["crypttabLine"] == "data /dev/disk/by-uuid/00000000-0000-0000-0000-000000000000 none luks,discard", v["crypttabLine"]
assert m["crypttabContent"] == v["crypttabLine"] + "\n", m["crypttabContent"]
# The mount unit filename must equal the escaped form of its Where= path
# (systemd.mount(5); nix/boot.nix's own documented rule): "/mnt/data" -> "mnt-data.mount".
assert v["mountUnitName"] == "mnt-data.mount", v["mountUnitName"]
content = v["mountUnitContent"]
assert "What=/dev/mapper/data" in content, content
assert "Where=/mnt/data" in content, content
assert "Type=ext4" in content, content
assert "Options=defaults" in content, content
# The mount unit must wait on systemd's own auto-generated cryptsetup unit
# for this mapper name (systemd-cryptsetup-generator(8)).
assert "Requires=systemd-cryptsetup@data.service" in content, content
assert "After=systemd-cryptsetup@data.service" in content, content
PYEOF
then
  fail "the fixture manifest does not match nix/crypttab.nix's own documented crypttabLine/mountUnitName/mountUnitContent formulas"
fi

# =====================================================================
# 2) fresh machine (nothing observed): plan is a real, non-empty
#    [write-crypttab, create-mount] in that fixed order.
# =====================================================================
observed_empty="$work/observed-empty.json"
cat > "$observed_empty" <<'EOF'
{"version": 1, "crypttabContent": "", "units": {}}
EOF

plan1="$work/plan1.json"
"$ubx_crypttab" plan --manifest "$manifest" --observed "$observed_empty" --out "$plan1" \
  || fail "plan (fresh machine) should succeed"

if ! python3 - "$plan1" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["empty"] is False, p
ops = [(a["op"], a.get("unitName")) for a in p["actions"]]
assert ops == [("write-crypttab", None), ("create-mount", "mnt-data.mount")], ops
PYEOF
then
  fail "plan (fresh machine) did not produce the expected [write-crypttab, create-mount] action sequence -- got: $(cat "$plan1")"
fi

# =====================================================================
# 3) diff-driven: an ALREADY-CONVERGED observed state (matching the
#    declared manifest exactly) produces a real no-op -- the issue's own
#    acceptance criterion.
# =====================================================================
observed_converged="$work/observed-converged.json"
python3 - "$manifest" "$observed_converged" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
v = m["volumes"][0]
observed = {"version": 1, "crypttabContent": m["crypttabContent"], "units": {v["mountUnitName"]: v["mountUnitContent"]}}
json.dump(observed, open(sys.argv[2], "w"))
PYEOF

plan2="$work/plan2.json"
"$ubx_crypttab" plan --manifest "$manifest" --observed "$observed_converged" --out "$plan2" \
  || fail "plan (already converged) should succeed"

if ! python3 - "$plan2" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["empty"] is True, p
assert p["actions"] == [], p
PYEOF
then
  fail "plan (already converged / unchanged declaration) should be a real no-op -- got: $(cat "$plan2")"
fi

# =====================================================================
# 4) drift: crypttab content on disk differs (e.g. hand-edited) but the
#    mount unit is already correct -> only write-crypttab is planned.
# =====================================================================
observed_drift="$work/observed-drift.json"
python3 - "$manifest" "$observed_drift" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
v = m["volumes"][0]
observed = {"version": 1, "crypttabContent": "# hand-edited, stale\n", "units": {v["mountUnitName"]: v["mountUnitContent"]}}
json.dump(observed, open(sys.argv[2], "w"))
PYEOF

plan3="$work/plan3.json"
"$ubx_crypttab" plan --manifest "$manifest" --observed "$observed_drift" --out "$plan3" \
  || fail "plan (crypttab drift) should succeed"

if ! python3 - "$plan3" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
ops = [(a["op"], a.get("unitName")) for a in p["actions"]]
assert ops == [("write-crypttab", None)], ops
PYEOF
then
  fail "plan (crypttab drift only) should emit exactly [write-crypttab] -- got: $(cat "$plan3")"
fi

# =====================================================================
# 5) mount-unit content drift (e.g. Options= changed on disk) -> only
#    update-mount is planned, crypttab untouched.
# =====================================================================
observed_mount_drift="$work/observed-mount-drift.json"
python3 - "$manifest" "$observed_mount_drift" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
v = m["volumes"][0]
stale_unit = v["mountUnitContent"].replace("Options=defaults", "Options=noatime")
observed = {"version": 1, "crypttabContent": m["crypttabContent"], "units": {v["mountUnitName"]: stale_unit}}
json.dump(observed, open(sys.argv[2], "w"))
PYEOF

plan4="$work/plan4.json"
"$ubx_crypttab" plan --manifest "$manifest" --observed "$observed_mount_drift" --out "$plan4" \
  || fail "plan (mount-unit drift) should succeed"

if ! python3 - "$plan4" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
ops = [(a["op"], a.get("unitName")) for a in p["actions"]]
assert ops == [("update-mount", "mnt-data.mount")], ops
PYEOF
then
  fail "plan (mount-unit drift only) should emit exactly [update-mount mnt-data.mount] -- got: $(cat "$plan4")"
fi

# =====================================================================
# 6) removal scope: a volume dropped from the declaration (present in
#    --old-manifest, absent from the new one) whose mount unit is still
#    observed on disk -> remove-mount; nothing is planned for a
#    similarly-dropped unit that was never observed (already gone).
# =====================================================================
old_manifest="$work/old-manifest.json"
cat > "$old_manifest" <<'EOF'
{
  "version": 1,
  "crypttabContent": "",
  "volumes": [
    {
      "name": "gone",
      "device": "/dev/disk/by-uuid/11111111-1111-1111-1111-111111111111",
      "keyFile": "none",
      "options": "",
      "crypttabLine": "gone /dev/disk/by-uuid/11111111-1111-1111-1111-111111111111 none",
      "mountPoint": "/mnt/gone",
      "fsType": "ext4",
      "mountOptions": "defaults",
      "mountUnitName": "mnt-gone.mount",
      "mountUnitContent": "stale unit content\n"
    },
    {
      "name": "neverobserved",
      "device": "/dev/disk/by-uuid/22222222-2222-2222-2222-222222222222",
      "keyFile": "none",
      "options": "",
      "crypttabLine": "neverobserved /dev/disk/by-uuid/22222222-2222-2222-2222-222222222222 none",
      "mountPoint": "/mnt/neverobserved",
      "fsType": "ext4",
      "mountOptions": "defaults",
      "mountUnitName": "mnt-neverobserved.mount",
      "mountUnitContent": "stale unit content 2\n"
    }
  ]
}
EOF

observed_with_gone="$work/observed-with-gone.json"
python3 - "$manifest" "$observed_with_gone" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
v = m["volumes"][0]
observed = {
    "version": 1,
    "crypttabContent": m["crypttabContent"],
    "units": {
        v["mountUnitName"]: v["mountUnitContent"],
        "mnt-gone.mount": "stale unit content\n",
        # "mnt-neverobserved.mount" deliberately NOT present.
    },
}
json.dump(observed, open(sys.argv[2], "w"))
PYEOF

plan5="$work/plan5.json"
"$ubx_crypttab" plan --manifest "$manifest" --old-manifest "$old_manifest" --observed "$observed_with_gone" --out "$plan5" \
  || fail "plan (removal scope) should succeed"

if ! python3 - "$plan5" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
ops = [(a["op"], a.get("unitName")) for a in p["actions"]]
assert ops == [("remove-mount", "mnt-gone.mount")], ops
PYEOF
then
  fail "plan (removal scope) should emit exactly [remove-mount mnt-gone.mount] (never for the never-observed dropped unit) -- got: $(cat "$plan5")"
fi

# =====================================================================
# 7) bin/ubx-crypttab observe: round-trips a real /etc/crypttab + a real
#    mount-units directory into the observed schema `plan` consumes.
# =====================================================================
crypttab_file="$work/etc-crypttab"
printf 'data /dev/disk/by-uuid/00000000-0000-0000-0000-000000000000 none luks,discard\n' > "$crypttab_file"
units_dir="$work/units"
mkdir -p "$units_dir"
printf 'unit content\n' > "$units_dir/mnt-data.mount"
printf 'not a mount unit\n' > "$units_dir/ignored.txt"

observed_out="$work/observed-from-real.json"
"$ubx_crypttab" observe --crypttab-file "$crypttab_file" --units-dir "$units_dir" --out "$observed_out" \
  || fail "ubx-crypttab observe should succeed"

if ! python3 - "$observed_out" "$crypttab_file" <<'PYEOF'
import json, sys
o = json.load(open(sys.argv[1]))
expected = open(sys.argv[2], encoding="utf-8").read()
assert o["crypttabContent"] == expected, o
assert o["units"] == {"mnt-data.mount": "unit content\n"}, o
PYEOF
then
  fail "ubx-crypttab observe did not correctly round-trip the real crypttab/units-dir fixtures -- got: $(cat "$observed_out")"
fi

exit "$fails"
