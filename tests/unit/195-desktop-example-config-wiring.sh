#!/usr/bin/env bash
# tests/unit/195-desktop-example-config-wiring.sh — the desktop parity
# example config (examples/desktop.nix) actually wires the landed base
# modules together and is actually consumed by nix/profiles.nix, not just
# documentation (SPEC.md §10: "The parity example configs double as
# ubuntnix's reference configurations in the repo and CI"; GitHub issue
# #107). Direct sibling of tests/unit/188-server-example-config-wiring.sh.
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so this is a machine-checked textual guard:
# it confirms examples/desktop.nix exists, declares every landed base
# module's own surface field (networking, fileSystems, swapDevices, i18n,
# console, time, users) plus profiles.desktop.enable, and that
# nix/profiles.nix actually `import`s it (not a dead, unreferenced fixture).
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

example_config="examples/desktop.nix"
profiles_nix="nix/profiles.nix"

for f in "$example_config" "$profiles_nix"; do
  [ -f "$f" ] || {
    echo "FAIL: $f does not exist" >&2
    exit 1
  }
done

# examples/desktop.nix must actually wire the landed base modules
# (networking, fileSystems+swap, i18n/console/time, users) plus
# profiles.desktop.enable -- SPEC.md §10's own worked-example shape, and
# this issue's own acceptance criteria (GitHub issue #107).
for field in networking fileSystems swapDevices i18n console time users 'profiles.desktop.enable'; do
  grep -q "$field" "$example_config" || fail "$example_config does not declare '$field'"
done

# It must actually be an "enable = true" config -- a parity reference
# config that never turns the profile on would be a contradiction.
grep -qE 'profiles\.desktop\.enable[[:space:]]*=[[:space:]]*true' "$example_config" ||
  fail "$example_config does not set profiles.desktop.enable = true"

# nix/profiles.nix must actually `import` this file (not a dead fixture
# nothing in the flake ever reads).
grep -q '\.\./examples/desktop\.nix' "$profiles_nix" ||
  fail "$profiles_nix does not import ../examples/desktop.nix"

# The imported config must actually be run through each owning base
# module's own render/validate function -- proving examples/desktop.nix's
# fields are valid declarations for those modules, not just prose that
# happens to share field names.
for owner in 'flake.lib.networking' 'flake.lib.fileSystems' 'flake.lib.localization' 'flake.lib.users'; do
  grep -qF "config.$owner" "$profiles_nix" ||
    fail "$profiles_nix does not run examples/desktop.nix's fields through config.$owner"
done

# examples/desktop.nix must be pure declaration data -- the same purity
# posture every nix/*.nix file in this tree is held to (SPEC.md §1.3).
if grep -nE '\bpkgs\.|mkDerivation|buildInputs|fetchFromGitHub' "$example_config" > /dev/null 2>&1; then
  fail "$example_config references a forbidden nixpkgs-package-set pattern"
fi

exit "$fails"
