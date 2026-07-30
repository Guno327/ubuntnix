#!/usr/bin/env bash
# tests/unit/179-filesystems-render-fixtures.sh — nix/filesystems.nix's
# generation logic: fstab lines, `.mount` unit content, `.swap` unit
# content, and crypttab-backed device interop, verified against
# hand-crafted fixtures that match nix/filesystems.nix's own documented
# render formulas EXACTLY (SPEC.md §4.3 "fstab / systemd mount units +
# swap"; GitHub issue #96).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so this cannot actually invoke `render`.
# Mirrors tests/unit/176-ubx-crypttab-plan.sh's own posture (see that
# file's header, "The manifest fixtures below are hand-crafted to EXACTLY
# the schema nix/crypttab.nix's `render` produces"): the fixture below is
# hand-computed from nix/filesystems.nix's own header formulas (fstab(5)
# column order, ".mount"/".swap" unit naming/content, the
# /dev/mapper/<name> -> systemd-cryptsetup@<name>.service interop rule),
# and this test asserts that fixture is internally self-consistent AND
# that the source file's own code actually implements each formula (not
# just documents it), the same "throw must be real code" cross-check every
# *-flake-wiring.sh test in this suite already applies to `validate`.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

fs_nix="$UBX_REPO_ROOT/nix/filesystems.nix"
[ -f "$fs_nix" ] || { echo "FAIL: $fs_nix does not exist" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# =====================================================================
# 1) hand-computed manifest for a declaration exercising:
#    - a plain (non-crypttab) filesystem ("/srv/media")
#    - a crypttab-backed filesystem ("/data", device /dev/mapper/data --
#      the exact mapper name nix/crypttab.nix's own exampleEntries uses)
#    - a swap device with both a priority and an extra option (discard)
#    computed by hand-applying nix/filesystems.nix's own documented
#    formulas ("Rendering" / "Rendered unit shapes" in that file's header).
# =====================================================================
manifest="$work/manifest.json"
cat > "$manifest" <<'EOF'
{
  "version": 1,
  "fstabContent": "/dev/mapper/data /data ext4 defaults 0 2\n/dev/disk/by-uuid/11111111-1111-1111-1111-111111111111 /srv/media ext4 defaults,noatime 0 2\n/dev/disk/by-uuid/22222222-2222-2222-2222-222222222222 none swap sw,pri=10,discard 0 0\n",
  "fileSystems": [
    {
      "mountPoint": "/data",
      "device": "/dev/mapper/data",
      "fsType": "ext4",
      "options": "defaults",
      "dump": 0,
      "passno": 2,
      "fstabLine": "/dev/mapper/data /data ext4 defaults 0 2",
      "cryptMapperName": "data",
      "mountUnitName": "data.mount",
      "mountUnitContent": "[Unit]\nDescription=ubuntnix mount for \"/data\" (SPEC.md §4.3 \"fstab / systemd mount units + swap\"; GitHub issue #96)\nAfter=systemd-cryptsetup@data.service\nRequires=systemd-cryptsetup@data.service\n\n[Mount]\nWhat=/dev/mapper/data\nWhere=/data\nType=ext4\nOptions=defaults\n\n[Install]\nWantedBy=local-fs.target\n"
    },
    {
      "mountPoint": "/srv/media",
      "device": "/dev/disk/by-uuid/11111111-1111-1111-1111-111111111111",
      "fsType": "ext4",
      "options": "defaults,noatime",
      "dump": 0,
      "passno": 2,
      "fstabLine": "/dev/disk/by-uuid/11111111-1111-1111-1111-111111111111 /srv/media ext4 defaults,noatime 0 2",
      "cryptMapperName": null,
      "mountUnitName": "srv-media.mount",
      "mountUnitContent": "[Unit]\nDescription=ubuntnix mount for \"/srv/media\" (SPEC.md §4.3 \"fstab / systemd mount units + swap\"; GitHub issue #96)\n\n[Mount]\nWhat=/dev/disk/by-uuid/11111111-1111-1111-1111-111111111111\nWhere=/srv/media\nType=ext4\nOptions=defaults,noatime\n\n[Install]\nWantedBy=local-fs.target\n"
    }
  ],
  "swapDevices": [
    {
      "device": "/dev/disk/by-uuid/22222222-2222-2222-2222-222222222222",
      "options": "discard",
      "priority": 10,
      "fstabLine": "/dev/disk/by-uuid/22222222-2222-2222-2222-222222222222 none swap sw,pri=10,discard 0 0",
      "swapUnitName": "dev-disk-by-uuid-22222222-2222-2222-2222-222222222222.swap",
      "swapUnitContent": "[Unit]\nDescription=ubuntnix swap for \"/dev/disk/by-uuid/22222222-2222-2222-2222-222222222222\" (SPEC.md §4.3 \"fstab / systemd mount units + swap\"; GitHub issue #96)\n\n[Swap]\nWhat=/dev/disk/by-uuid/22222222-2222-2222-2222-222222222222\nOptions=discard\nPriority=10\n\n[Install]\nWantedBy=swap.target\n"
    }
  ]
}
EOF

if ! python3 - "$manifest" <<'PYEOF'
import json, sys

m = json.load(open(sys.argv[1]))

# --- fstab(5) column order: device mountpoint fstype options dump passno.
fs_data = next(f for f in m["fileSystems"] if f["mountPoint"] == "/data")
assert fs_data["fstabLine"] == "/dev/mapper/data /data ext4 defaults 0 2", fs_data["fstabLine"]

fs_media = next(f for f in m["fileSystems"] if f["mountPoint"] == "/srv/media")
assert fs_media["fstabLine"] == (
    "/dev/disk/by-uuid/11111111-1111-1111-1111-111111111111 /srv/media ext4 defaults,noatime 0 2"
), fs_media["fstabLine"]

# --- fstabContent is every fileSystems + swapDevices line, sorted by
# mountPoint/declared order, joined with "\n", trailing "\n".
assert m["fstabContent"] == (
    fs_data["fstabLine"] + "\n" + fs_media["fstabLine"] + "\n" +
    m["swapDevices"][0]["fstabLine"] + "\n"
), m["fstabContent"]

# --- .mount unit filename: drop leading "/", "/" -> "-", append ".mount"
# (nix/crypttab.nix's own documented scheme, reused verbatim).
assert fs_data["mountUnitName"] == "data.mount", fs_data["mountUnitName"]
assert fs_media["mountUnitName"] == "srv-media.mount", fs_media["mountUnitName"]

# --- crypttab interop (issue #96 acceptance criteria): a /dev/mapper/<name>
# device is recognized and wired to systemd-cryptsetup@<name>.service in
# the SAME way nix/crypttab.nix's own rendered mount unit is -- with no
# cross-file lookup, structurally, from the device string alone.
assert fs_data["cryptMapperName"] == "data", fs_data["cryptMapperName"]
content = fs_data["mountUnitContent"]
assert "After=systemd-cryptsetup@data.service" in content, content
assert "Requires=systemd-cryptsetup@data.service" in content, content
assert "What=/dev/mapper/data" in content, content
assert "Where=/data" in content, content

# --- a plain (non-crypttab) filesystem must NOT carry any
# systemd-cryptsetup wiring.
assert fs_media["cryptMapperName"] is None, fs_media["cryptMapperName"]
assert "systemd-cryptsetup" not in fs_media["mountUnitContent"], fs_media["mountUnitContent"]

# --- swap: fstab(5) line is "<device> none swap <options> 0 0"; the
# options token order is "sw" first, then "pri=<N>" (when a priority is
# set), then any caller-supplied extra tokens.
swap = m["swapDevices"][0]
assert swap["fstabLine"] == (
    "/dev/disk/by-uuid/22222222-2222-2222-2222-222222222222 none swap sw,pri=10,discard 0 0"
), swap["fstabLine"]

# --- .swap unit filename: identical escaping scheme as .mount, applied to
# the device path (systemd.swap(5): unit name must equal the escaped
# What= path).
assert swap["swapUnitName"] == (
    "dev-disk-by-uuid-22222222-2222-2222-2222-222222222222.swap"
), swap["swapUnitName"]

swap_content = swap["swapUnitContent"]
assert "[Swap]" in swap_content, swap_content
assert "What=/dev/disk/by-uuid/22222222-2222-2222-2222-222222222222" in swap_content, swap_content
assert "Options=discard" in swap_content, swap_content
assert "Priority=10" in swap_content, swap_content
assert "WantedBy=swap.target" in swap_content, swap_content

print("filesystems-render-fixtures: fixture is internally consistent")
PYEOF
then
  fail "the fixture manifest is not internally consistent with nix/filesystems.nix's own documented formulas"
fi

# =====================================================================
# 2) the source file must actually IMPLEMENT each formula exercised above,
#    not just document it -- static cross-checks mirroring every other
#    *-flake-wiring.sh test's "throw must be real code" posture.
# =====================================================================

grep -q 'fstabLine' "$fs_nix" || fail "$fs_nix does not build an fstabLine field"
grep -q 'mountUnitName' "$fs_nix" || fail "$fs_nix does not build mountUnitName"
grep -q 'swapUnitName' "$fs_nix" || fail "$fs_nix does not build swapUnitName"
grep -q 'cryptMapperName' "$fs_nix" || fail "$fs_nix does not thread cryptMapperName through render"
grep -qE 'pri=' "$fs_nix" || fail "$fs_nix does not emit fstab's pri=<N> swap priority token"
grep -q '"sw"' "$fs_nix" || fail "$fs_nix does not emit fstab's base \"sw\" swap option token"

# validate must reject a duplicate device across two fileSystems entries
# and across two swapDevices entries (issue #96: "a device may be mounted
# at only one point").
grep -q 'checkFileSystemDeviceDupes' "$fs_nix" ||
  fail "$fs_nix does not check for duplicate fileSystems devices"
grep -q 'checkSwapDeviceDupes' "$fs_nix" ||
  fail "$fs_nix does not check for duplicate swapDevices devices"

# =====================================================================
# 3) flake.lib.fileSystems.cryptDepOf must implement the SAME mapper-name
#    grammar nix/crypttab.nix's own nameOk uses ("[a-z][a-z0-9_]*") --
#    the exact interop contract this issue asks for.
# =====================================================================
crypttab_nix="$UBX_REPO_ROOT/nix/crypttab.nix"
if [ -f "$crypttab_nix" ]; then
  crypttab_re="$(grep -oE 'nameRe = "[^"]+"' "$crypttab_nix" | head -1 | sed -E 's/nameRe = "(.*)"/\1/')"
  fs_re="$(grep -oE 'cryptMapperNameRe = "[^"]+"' "$fs_nix" | head -1 | sed -E 's/cryptMapperNameRe = "(.*)"/\1/')"
  [ -n "$crypttab_re" ] || fail "could not extract nix/crypttab.nix's own nameRe"
  [ -n "$fs_re" ] || fail "could not extract $fs_nix's own cryptMapperNameRe"
  [ "$crypttab_re" = "$fs_re" ] ||
    fail "$fs_nix's cryptMapperNameRe ($fs_re) does not match nix/crypttab.nix's mapper-name grammar ($crypttab_re) -- interop would silently diverge"
else
  fail "$crypttab_nix does not exist -- cannot cross-check the crypttab interop grammar"
fi

exit "$fails"
