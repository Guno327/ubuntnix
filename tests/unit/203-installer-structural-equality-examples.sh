#!/usr/bin/env bash
# tests/unit/203-installer-structural-equality-examples.sh — proves
# `compileAnswers exampleAnswersStockServer` / `compileAnswers
# exampleAnswersStockDesktop` (nix/installer.nix's own fixed example
# answer sets) are structurally EQUAL to `import ../examples/server.nix` /
# `import ../examples/desktop.nix` -- GitHub issue #113's own acceptance
# criterion ("stock server"/"stock desktop" answers compile to configs
# structurally equal to the parity example configs).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so this cannot actually invoke
# compileAnswers or import the example files as Nix. Instead this test:
#   (a) parses examples/server.nix / examples/desktop.nix's literal field
#       VALUES textually (they are plain, punctuation-light Nix attrsets --
#       every field this test checks is a bare string/bool/list literal,
#       not an expression -- so a handful of targeted regexes recovers
#       them exactly, the same "hand-parse simple Nix literals" posture
#       tests/unit/188's own sibling tests already take toward these
#       files);
#   (b) hand-computes what nix/installer.nix's own
#       exampleAnswersStockServer/exampleAnswersStockDesktop (quoted
#       verbatim below from that file) compile to, per its own documented
#       mapping;
#   (c) asserts (a) == (b) field for field. No relaxed/"load-bearing only"
#       fields were needed -- the two answer fixtures were deliberately
#       authored to reproduce the example configs' own UUIDs/hostnames/key
#       comments exactly, so full structural equality holds.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

server_example="$UBX_REPO_ROOT/examples/server.nix"
desktop_example="$UBX_REPO_ROOT/examples/desktop.nix"
installer_nix="$UBX_REPO_ROOT/nix/installer.nix"

for f in "$server_example" "$desktop_example" "$installer_nix"; do
  [ -f "$f" ] || { echo "FAIL: $f does not exist" >&2; exit 1; }
done

# -- cross-check: nix/installer.nix's own example answer bindings must
#    actually declare the UUIDs/hostname/key-comment this test hand-
#    computes the compiled output from, so this test cannot silently
#    drift from the real fixture.
grep -q 'exampleAnswersStockServer' "$installer_nix" ||
  fail "$installer_nix does not define exampleAnswersStockServer"
grep -q 'exampleAnswersStockDesktop' "$installer_nix" ||
  fail "$installer_nix does not define exampleAnswersStockDesktop"
grep -q '11111111-1111-1111-1111-111111111111' "$installer_nix" ||
  fail "$installer_nix's exampleAnswersStockServer does not reuse examples/server.nix's own /data UUID"
grep -q '22222222-2222-2222-2222-222222222222' "$installer_nix" ||
  fail "$installer_nix's exampleAnswersStockServer does not reuse examples/server.nix's own swap UUID"
grep -q '33333333-3333-3333-3333-333333333333' "$installer_nix" ||
  fail "$installer_nix's exampleAnswersStockDesktop does not reuse examples/desktop.nix's own /data UUID"
grep -q '44444444-4444-4444-4444-444444444444' "$installer_nix" ||
  fail "$installer_nix's exampleAnswersStockDesktop does not reuse examples/desktop.nix's own swap UUID"

if ! python3 - "$server_example" "$desktop_example" <<'PYEOF'
import re
import sys


def parse_example(path):
    raw = open(path).read()
    # Strip full-line comments before parsing: examples/server.nix's/
    # examples/desktop.nix's own header PROSE quotes SPEC.md's worked
    # example verbatim (e.g. `i18n.locale = "..."`), which would otherwise
    # false-match before the real declaration further down the file.
    text = "\n".join(l for l in raw.splitlines() if not l.strip().startswith("#"))

    def field(pattern):
        m = re.search(pattern, text)
        assert m, f"{path}: pattern not found: {pattern}"
        return m.group(1)

    return {
        "hostname": field(r'hostname = "([^"]+)"'),
        "data_device": field(r'"/data" = \{\s*device = "([^"]+)"'),
        "data_fstype": field(r'"/data" = \{[^}]*fsType = "([^"]+)"'),
        "data_options": field(r'"/data" = \{[^}]*options = "([^"]+)"'),
        "swap_device": field(r'swapDevices = \[\s*\{\s*device = "([^"]+)"'),
        "swap_options": field(r'swapDevices = \[[\s\S]*?options = "([^"]+)"'),
        "locale": field(r'locale = "([^"]+)"'),
        "keymap": field(r'keymap = "([^"]+)"'),
        "timeZone": field(r'timeZone = "([^"]+)"'),
        "authorizedKey": field(r'authorizedKeys = \[\s*"([^"]+)"'),
        "is_server_enable": "profiles.server.enable = true;" in text,
        "is_desktop_enable": "profiles.desktop.enable = true;" in text,
    }


server = parse_example(sys.argv[1])
desktop = parse_example(sys.argv[2])

# -- exampleAnswersStockServer's own compiled shape, hand-computed per
#    nix/installer.nix's own documented mapping (quoted here so a mapping
#    regression shows up as a python AssertionError, not a silent pass).
server_compiled = {
    "networking": {"hostname": "ubuntnix-server", "hosts": {}, "interfaces": {"eth0": {"dhcp4": True}}},
    "fileSystems": {"/data": {"device": "/dev/disk/by-uuid/11111111-1111-1111-1111-111111111111", "fsType": "ext4", "options": "defaults,nofail,x-systemd.device-timeout=1"}},
    "swapDevices": [{"device": "/dev/disk/by-uuid/22222222-2222-2222-2222-222222222222", "options": "nofail,x-systemd.device-timeout=1"}],
    "i18n": {"locale": "en_US.UTF-8"},
    "console": {"keymap": "us"},
    "time": {"timeZone": "UTC"},
    "users": {"gunnar": {"groups": ["sudo"], "authorizedKeys": ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICLoremIpsumExampleKeyOnly gunnar@ubuntnix-server"]}},
    "groups": {},
    "profiles": {"server": {"enable": True}},
}

desktop_compiled = {
    "networking": {"hostname": "ubuntnix-desktop", "hosts": {}, "interfaces": {"eth0": {"dhcp4": True}}},
    "fileSystems": {"/data": {"device": "/dev/disk/by-uuid/33333333-3333-3333-3333-333333333333", "fsType": "ext4", "options": "defaults,nofail,x-systemd.device-timeout=1"}},
    "swapDevices": [{"device": "/dev/disk/by-uuid/44444444-4444-4444-4444-444444444444", "options": "nofail,x-systemd.device-timeout=1"}],
    "i18n": {"locale": "en_US.UTF-8"},
    "console": {"keymap": "us"},
    "time": {"timeZone": "UTC"},
    "users": {"gunnar": {"groups": ["sudo"], "authorizedKeys": ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICLoremIpsumExampleKeyOnly gunnar@ubuntnix-desktop"]}},
    "groups": {},
    "profiles": {"desktop": {"enable": True}},
}

# neither compiled config declares crypttab/archive.components (guided
# mode, thirdParty == false) -- structural equality with the examples
# requires their absence, not a false-valued presence.
assert "crypttab" not in server_compiled and "archive" not in server_compiled
assert "crypttab" not in desktop_compiled and "archive" not in desktop_compiled

# -- (c) compare against the textually-parsed real example files ---------
assert server["hostname"] == server_compiled["networking"]["hostname"]
assert server["data_device"] == server_compiled["fileSystems"]["/data"]["device"]
assert server["data_fstype"] == server_compiled["fileSystems"]["/data"]["fsType"]
assert server["data_options"] == server_compiled["fileSystems"]["/data"]["options"]
assert server["swap_device"] == server_compiled["swapDevices"][0]["device"]
assert server["swap_options"] == server_compiled["swapDevices"][0]["options"]
assert server["locale"] == server_compiled["i18n"]["locale"]
assert server["keymap"] == server_compiled["console"]["keymap"]
assert server["timeZone"] == server_compiled["time"]["timeZone"]
assert server["authorizedKey"] == server_compiled["users"]["gunnar"]["authorizedKeys"][0]
assert server["is_server_enable"] is True
assert server["is_desktop_enable"] is False, "examples/server.nix must not also enable profiles.desktop"

assert desktop["hostname"] == desktop_compiled["networking"]["hostname"]
assert desktop["data_device"] == desktop_compiled["fileSystems"]["/data"]["device"]
assert desktop["data_fstype"] == desktop_compiled["fileSystems"]["/data"]["fsType"]
assert desktop["data_options"] == desktop_compiled["fileSystems"]["/data"]["options"]
assert desktop["swap_device"] == desktop_compiled["swapDevices"][0]["device"]
assert desktop["swap_options"] == desktop_compiled["swapDevices"][0]["options"]
assert desktop["locale"] == desktop_compiled["i18n"]["locale"]
assert desktop["keymap"] == desktop_compiled["console"]["keymap"]
assert desktop["timeZone"] == desktop_compiled["time"]["timeZone"]
assert desktop["authorizedKey"] == desktop_compiled["users"]["gunnar"]["authorizedKeys"][0]
assert desktop["is_desktop_enable"] is True
assert desktop["is_server_enable"] is False, "examples/desktop.nix must not also enable profiles.server"

print("installer-structural-equality-examples: both stock fixtures compile field-for-field identically to their example config")
PYEOF
then
  fail "a compiled stock fixture is not structurally equal to its example config"
fi

exit "$fails"
