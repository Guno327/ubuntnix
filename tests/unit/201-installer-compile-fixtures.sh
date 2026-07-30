#!/usr/bin/env bash
# tests/unit/201-installer-compile-fixtures.sh — nix/installer.nix's
# compileAnswers logic, verified against hand-crafted fixtures that match
# nix/installer.nix's own documented mapping EXACTLY (SPEC.md §10; GitHub
# issue #113): guided stock server, LUKS-encrypted desktop (with the
# third-party checkbox on), and a plain third-party-off/on contrast.
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so this cannot actually invoke
# compileAnswers. Mirrors tests/unit/181-localization-render-fixtures.sh's
# own posture: each fixture below is hand-computed from
# nix/installer.nix's own header formulas ("The mapping (SPEC.md §10)"),
# and this test asserts each fixture is internally self-consistent AND
# that the source file's own code actually implements each formula (not
# just documents it).
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

installer_nix="$UBX_REPO_ROOT/nix/installer.nix"
[ -f "$installer_nix" ] || { echo "FAIL: $installer_nix does not exist" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# =====================================================================
# 1) guided stock server: answers -> hand-computed compiled config,
#    following nix/installer.nix's own documented mapping verbatim.
# =====================================================================
server_compiled="$work/server-compiled.json"
cat > "$server_compiled" <<'EOF'
{
  "networking": {
    "hostname": "ubuntnix-server",
    "hosts": {},
    "interfaces": { "eth0": { "dhcp4": true } }
  },
  "fileSystems": {
    "/data": {
      "device": "/dev/disk/by-uuid/11111111-1111-1111-1111-111111111111",
      "fsType": "ext4",
      "options": "defaults,nofail,x-systemd.device-timeout=1"
    }
  },
  "swapDevices": [
    { "device": "/dev/disk/by-uuid/22222222-2222-2222-2222-222222222222", "options": "nofail,x-systemd.device-timeout=1" }
  ],
  "i18n": { "locale": "en_US.UTF-8" },
  "console": { "keymap": "us" },
  "time": { "timeZone": "UTC" },
  "users": {
    "gunnar": {
      "groups": ["sudo"],
      "authorizedKeys": ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICLoremIpsumExampleKeyOnly gunnar@ubuntnix-server"]
    }
  },
  "groups": {},
  "profiles": { "server": { "enable": true } }
}
EOF

# =====================================================================
# 2) LUKS-encrypted desktop, third-party checkbox on: answers ->
#    hand-computed compiled config -- exercises crypttab + archive.components
#    compilation, neither of which fixture (1) touches.
# =====================================================================
luks_compiled="$work/luks-desktop-compiled.json"
cat > "$luks_compiled" <<'EOF'
{
  "networking": {
    "hostname": "ubuntnix-luks-desktop",
    "hosts": {},
    "interfaces": { "eth0": { "dhcp4": true } }
  },
  "fileSystems": {
    "/": {
      "device": "/dev/mapper/cryptroot",
      "fsType": "ext4",
      "options": "defaults"
    }
  },
  "swapDevices": [],
  "i18n": { "locale": "en_US.UTF-8" },
  "console": { "keymap": "us" },
  "time": { "timeZone": "Europe/Oslo" },
  "users": {
    "alex": {
      "groups": ["sudo"],
      "authorizedKeys": ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICLoremIpsumExampleKeyOnly alex@ubuntnix-desktop"],
      "hashedPasswordSecret": "alexPassword"
    }
  },
  "groups": {},
  "profiles": { "desktop": { "enable": true } },
  "crypttab": {
    "cryptroot": {
      "device": "/dev/disk/by-uuid/55555555-5555-5555-5555-555555555555",
      "keyFile": "none",
      "options": "luks,discard"
    }
  },
  "archive": { "components": { "restricted": true, "multiverse": true } }
}
EOF

if ! python3 - "$server_compiled" "$luks_compiled" <<'PYEOF'
import json
import sys

server = json.load(open(sys.argv[1]))
luks = json.load(open(sys.argv[2]))

# -- fixture 1: guided stock server ------------------------------------
assert server["networking"]["hostname"] == "ubuntnix-server"
assert server["networking"]["hosts"] == {}
assert server["networking"]["interfaces"]["eth0"]["dhcp4"] is True
assert server["fileSystems"]["/data"]["device"].startswith("/dev/disk/by-uuid/")
assert server["fileSystems"]["/data"]["fsType"] == "ext4"
assert server["swapDevices"][0]["device"].startswith("/dev/disk/by-uuid/")
assert server["i18n"]["locale"] == "en_US.UTF-8"
assert server["console"]["keymap"] == "us"
assert server["time"]["timeZone"] == "UTC"
assert "gunnar" in server["users"]
assert server["users"]["gunnar"]["groups"] == ["sudo"]
assert "hashedPasswordSecret" not in server["users"]["gunnar"], \
    "no hashedPasswordSecret was declared in answers -- it must not appear in the compiled user entry"
assert server["groups"] == {}
# desktop-vs-server: exactly one profile compiled, the other absent entirely.
assert server["profiles"] == {"server": {"enable": True}}, server["profiles"]
assert "crypttab" not in server, "guided mode must never compile a crypttab entry"
assert "archive" not in server, "thirdParty == false must never compile archive.components"

# -- fixture 2: LUKS-encrypted desktop, third-party on -------------------
assert luks["profiles"] == {"desktop": {"enable": True}}, luks["profiles"]
# storage.mode == "luks": the mounted device is the /dev/mapper/<luksName>
# path, NEVER the raw physical device -- that physical device instead
# shows up as the crypttab entry's own `device`.
assert luks["fileSystems"]["/"]["device"] == "/dev/mapper/cryptroot"
assert luks["crypttab"]["cryptroot"]["device"] == "/dev/disk/by-uuid/55555555-5555-5555-5555-555555555555"
assert luks["crypttab"]["cryptroot"]["keyFile"] == "none"
# identity.hashedPasswordSecret, when set, is compiled through verbatim --
# a REFERENCE only (never a hash value, never anything secret-shaped).
assert luks["users"]["alex"]["hashedPasswordSecret"] == "alexPassword"
assert not luks["users"]["alex"]["hashedPasswordSecret"].startswith("$"), \
    "hashedPasswordSecret must be a secret NAME, never a crypt(3) hash value"
# thirdParty == true compiles the restricted+multiverse toggle, both true.
assert luks["archive"]["components"] == {"restricted": True, "multiverse": True}, luks["archive"]

print("installer-compile-fixtures: both fixtures are internally consistent")
PYEOF
then
  fail "the fixture manifests are not internally consistent with nix/installer.nix's own documented mapping"
fi

# =====================================================================
# 2) the source file must actually IMPLEMENT each formula exercised above,
#    not just document it -- static cross-checks mirroring every other
#    *-fixtures.sh test's posture.
# =====================================================================

grep -qE '/dev/mapper/\$\{a\.storage\.luksName\}' "$installer_nix" ||
  fail "$installer_nix does not route a LUKS-mode mount through /dev/mapper/<luksName>"
grep -q 'isLuks' "$installer_nix" ||
  fail "$installer_nix does not branch storage compilation on a LUKS-mode check"
grep -qE 'desktop\.enable = true' "$installer_nix" ||
  fail "$installer_nix does not compile profiles.desktop.enable = true"
grep -qE 'server\.enable = true' "$installer_nix" ||
  fail "$installer_nix does not compile profiles.server.enable = true"
grep -qE 'restricted = true' "$installer_nix" ||
  fail "$installer_nix does not compile archive.components.restricted = true"
grep -qE 'multiverse = true' "$installer_nix" ||
  fail "$installer_nix does not compile archive.components.multiverse = true"
grep -q 'lib.optionalAttrs' "$installer_nix" ||
  fail "$installer_nix does not conditionally omit crypttab/archive.components (lib.optionalAttrs expected)"
grep -q 'hashedPasswordSecret = a.identity.hashedPasswordSecret' "$installer_nix" ||
  fail "$installer_nix does not compile identity.hashedPasswordSecret through verbatim"

exit "$fails"
