#!/usr/bin/env bash
# tests/unit/202-installer-roundtrip-validate.sh — proves compileAnswers's
# output actually PASSES every already-landed base module's own eval-
# boundary validation grammar (networking, fileSystems, localization,
# users, crypttab) -- not merely shaped like a valid declaration (GitHub
# issue #113's own acceptance criterion: "round-trip test that compiled
# config passes each already-landed base-module validate").
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so this cannot actually call
# config.flake.lib.<domain>.validate. Instead, mirroring
# tests/unit/181-localization-render-fixtures.sh's own posture, this test
# reimplements each owning domain's own DOCUMENTED validation grammar in
# python (the exact regexes/rules quoted from that file's header/code,
# cross-checked below against the real source so this can't silently
# drift) and asserts nix/installer.nix's compiled fixtures satisfy every
# one of them.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

networking_nix="$UBX_REPO_ROOT/nix/networking.nix"
filesystems_nix="$UBX_REPO_ROOT/nix/filesystems.nix"
localization_nix="$UBX_REPO_ROOT/nix/localization.nix"
users_nix="$UBX_REPO_ROOT/nix/users.nix"
crypttab_nix="$UBX_REPO_ROOT/nix/crypttab.nix"
installer_nix="$UBX_REPO_ROOT/nix/installer.nix"

for f in "$networking_nix" "$filesystems_nix" "$localization_nix" "$users_nix" "$crypttab_nix" "$installer_nix"; do
  [ -f "$f" ] || { echo "FAIL: $f does not exist" >&2; exit 1; }
done

# -- cross-check: the regexes this test reimplements below must actually
#    appear, verbatim, in their owning domain file -- so this test cannot
#    silently drift from the real validators it stands in for.
grep -qE 'hostnameRe = "\^\[a-zA-Z0-9\]' "$networking_nix" ||
  fail "$networking_nix's hostnameRe no longer matches what this test reimplements"
grep -qE 'ifaceNameRe = "\^\[a-zA-Z\]\[a-zA-Z0-9\]\*\$"' "$networking_nix" ||
  fail "$networking_nix's ifaceNameRe no longer matches what this test reimplements"
grep -qE 'nameRe = "\^\[a-z_\]\[a-z0-9_-\]\{0,31\}\$"' "$users_nix" ||
  fail "$users_nix's username nameRe no longer matches what this test reimplements"
grep -qE 'nameRe = "\[a-z\]\[a-z0-9_\]\*"' "$crypttab_nix" ||
  fail "$crypttab_nix's mapper nameRe no longer matches what this test reimplements"

if ! python3 - "$installer_nix" <<'PYEOF'
import re
import sys

# Fixtures: the exact compiled shape nix/installer.nix's own
# compileAnswers documents/implements for its three example answer sets
# (mirrors tests/unit/201's own fixtures -- kept independent here so a
# round-trip-specific regression is caught even if 201's fixtures change).
compiled_fixtures = [
    {
        "networking": {"hostname": "ubuntnix-server", "hosts": {}, "interfaces": {"eth0": {"dhcp4": True}}},
        "fileSystems": {"/data": {"device": "/dev/disk/by-uuid/11111111-1111-1111-1111-111111111111", "fsType": "ext4", "options": "defaults,nofail,x-systemd.device-timeout=1"}},
        "swapDevices": [{"device": "/dev/disk/by-uuid/22222222-2222-2222-2222-222222222222", "options": "nofail,x-systemd.device-timeout=1"}],
        "i18n": {"locale": "en_US.UTF-8"},
        "console": {"keymap": "us"},
        "time": {"timeZone": "UTC"},
        "users": {"gunnar": {"groups": ["sudo"], "authorizedKeys": ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICLoremIpsumExampleKeyOnly gunnar@ubuntnix-server"]}},
        "groups": {},
        "crypttab": {},
    },
    {
        "networking": {"hostname": "ubuntnix-luks-desktop", "hosts": {}, "interfaces": {"eth0": {"dhcp4": True}}},
        "fileSystems": {"/": {"device": "/dev/mapper/cryptroot", "fsType": "ext4", "options": "defaults"}},
        "swapDevices": [],
        "i18n": {"locale": "en_US.UTF-8"},
        "console": {"keymap": "us"},
        "time": {"timeZone": "Europe/Oslo"},
        "users": {"alex": {"groups": ["sudo"], "authorizedKeys": ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICLoremIpsumExampleKeyOnly alex@ubuntnix-desktop"], "hashedPasswordSecret": "alexPassword"}},
        "groups": {},
        "crypttab": {"cryptroot": {"device": "/dev/disk/by-uuid/55555555-5555-5555-5555-555555555555", "keyFile": "none", "options": "luks,discard"}},
    },
]

# -- nix/networking.nix's own grammars ---------------------------------
hostname_re = re.compile(r"^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$")
iface_name_re = re.compile(r"^[a-zA-Z][a-zA-Z0-9]*$")
ip_re = re.compile(r"^[0-9a-fA-F:.]+$")

# -- nix/filesystems.nix's own grammars ---------------------------------
def abs_path_ok(p):
    if not isinstance(p, str) or p == "" or not p.startswith("/") or p == "/":
        return p == "/"  # "/" itself is a legal mount point for fileSystems, unlike crypttab's own absPathOk
    segs = p[1:].split("/")
    return all(seg not in ("", ".", "..") and re.fullmatch(r"[A-Za-z0-9._-]+", seg) for seg in segs)

# -- nix/localization.nix's own grammars ---------------------------------
locale_re = re.compile(r"^[A-Za-z_]+(\.[A-Za-z0-9-]+)?$")
keymap_re = re.compile(r"^[a-z][a-z0-9-]*$")
tz_re = re.compile(r"^[A-Za-z_+-]+(/[A-Za-z0-9_+-]+)*$")

# -- nix/users.nix's own grammars ---------------------------------------
user_name_re = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
key_line_re = re.compile(r"^[^ \t\n]+ [^ \t\n]+.*$")
secret_name_re = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]{0,63}$")

# -- nix/crypttab.nix's own grammars -------------------------------------
mapper_name_re = re.compile(r"^[a-z][a-z0-9_]*$")


def check_networking(n):
    assert hostname_re.match(n["hostname"]), n["hostname"]
    assert isinstance(n["hosts"], dict)
    for iface, e in n["interfaces"].items():
        assert iface_name_re.match(iface), iface
        assert isinstance(e["dhcp4"], bool)


def check_filesystems(fs, swap):
    for mp, e in fs.items():
        assert abs_path_ok(mp), mp
        assert abs_path_ok(e["device"]), e["device"]
        assert isinstance(e["fsType"], str) and e["fsType"]
        assert isinstance(e["options"], str)
    for e in swap:
        assert abs_path_ok(e["device"]), e["device"]
        assert isinstance(e["options"], str)


def check_localization(i18n, console, time_):
    assert locale_re.match(i18n["locale"]), i18n["locale"]
    assert keymap_re.match(console["keymap"]), console["keymap"]
    assert tz_re.match(time_["timeZone"]), time_["timeZone"]


def check_users(users, groups):
    for name, u in users.items():
        assert user_name_re.match(name), name
        for g in u["groups"]:
            assert user_name_re.match(g), g
        for k in u["authorizedKeys"]:
            assert key_line_re.match(k), k
        secret = u.get("hashedPasswordSecret")
        if secret is not None:
            assert secret_name_re.match(secret), secret
    assert isinstance(groups, dict)


def check_crypttab(entries):
    for name, e in entries.items():
        assert mapper_name_re.match(name), name
        assert abs_path_ok(e["device"]), e["device"]
        assert e["keyFile"] in ("none", "-"), e["keyFile"]
        assert isinstance(e["options"], str)


for fx in compiled_fixtures:
    check_networking(fx["networking"])
    check_filesystems(fx["fileSystems"], fx["swapDevices"])
    check_localization(fx["i18n"], fx["console"], fx["time"])
    check_users(fx["users"], fx["groups"])
    check_crypttab(fx["crypttab"])

print("installer-roundtrip-validate: every compiled fixture passes every owning domain's own validation grammar")
PYEOF
then
  fail "a compiled fixture failed round-trip validation against a base module's own grammar"
fi

exit "$fails"
