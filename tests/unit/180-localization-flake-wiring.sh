#!/usr/bin/env bash
# tests/unit/180-localization-flake-wiring.sh — nix/localization.nix
# static wiring checks (SPEC.md §6 "i18n.locale = ...; # -> locales
# debconf/gen", "console.keymap = ...; # -> console-setup", "time.timeZone
# = ...; # -> /etc/localtime + timesyncd"; GitHub issue #97).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so nothing here can actually evaluate or
# build the flake. This test is a machine-checked textual guard instead,
# mirroring tests/unit/178-filesystems-flake-wiring.sh's relationship to
# nix/filesystems.nix: it confirms nix/localization.nix exists, is
# imported by flake.nix, exposes flake.lib.localization, throws on a bad
# declaration, reuses the real ubuntnix.debconf/ubuntnix.etc primitives
# (not a bypass), and is wired to a real per-system proof package.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

loc_nix="nix/localization.nix"

[ -f "$loc_nix" ] || {
  echo "FAIL: $loc_nix does not exist" >&2
  exit 1
}

# flake.nix must actually import the dendritic module (SPEC.md §2 G8).
grep -q '\./nix/localization\.nix' flake.nix ||
  fail "flake.nix does not import ./nix/localization.nix"

# Must expose flake.lib.localization (same dendritic contribution pattern
# nix/crypttab.nix/nix/etc.nix/nix/filesystems.nix each use).
grep -q 'flake.lib.localization' "$loc_nix" ||
  fail "$loc_nix does not expose flake.lib.localization"

for fn in validateDecl render renderJSON splitTz localeGenEntry; do
  grep -q "$fn" "$loc_nix" || fail "$loc_nix does not define/expose '$fn'"
done

# validate must actually `throw` on a violation (a real eval-boundary
# enforcement, not just documentation) -- mirrors tests/unit/178's/175's/
# 170's/161's/041's identical check.
grep -q 'throw' "$loc_nix" ||
  fail "$loc_nix has no throw -- validation must actually refuse a bad declaration"

# perSystem wiring for the fixture proof (mirrors nix/filesystems.nix's
# own filesystems-manifest-proof).
grep -q 'packages.localization-manifest-proof' "$loc_nix" ||
  fail "$loc_nix does not declare packages.localization-manifest-proof"
grep -q 'runInUbuntuBase' "$loc_nix" ||
  fail "$loc_nix does not build localization-manifest-proof via runInUbuntuBase"
grep -qE 'config\.flake\.lib\.stdenv' "$loc_nix" ||
  fail "$loc_nix does not reach the stdenv builder via config.flake.lib.stdenv"

# Must consume the real primitives, not bypass them (issue #97's own
# directive: "Use the ubuntnix.debconf and ubuntnix.etc primitives -- do
# NOT bypass upstream mechanisms"): nix/compose.nix's own preseed
# flattener, and nix/etc.nix's own entry validator.
grep -qE 'config\.flake\.lib\.compose' "$loc_nix" ||
  fail "$loc_nix does not reach nix/compose.nix's renderPreseed via config.flake.lib.compose"
grep -q 'renderPreseed' "$loc_nix" ||
  fail "$loc_nix does not call renderPreseed (the ubuntnix.debconf primitive's own flattener)"
grep -qE 'config\.flake\.lib\.etc' "$loc_nix" ||
  fail "$loc_nix does not reach nix/etc.nix's validate via config.flake.lib.etc"

# The three upstream mechanisms named in the issue must each show up as
# real code, not just documentation.
grep -q 'locales/default_environment_locale' "$loc_nix" ||
  fail "$loc_nix does not render the locales/default_environment_locale debconf question"
grep -q 'locales/locales_to_be_generated' "$loc_nix" ||
  fail "$loc_nix does not render the locales/locales_to_be_generated debconf question"
grep -q 'keyboard-configuration/layoutcode' "$loc_nix" ||
  fail "$loc_nix does not render the keyboard-configuration/layoutcode debconf question"
grep -q 'tzdata/Areas' "$loc_nix" ||
  fail "$loc_nix does not render the tzdata/Areas debconf question"
grep -qE 'tzdata/Zones' "$loc_nix" ||
  fail "$loc_nix does not render a tzdata/Zones/<Area> debconf question"
grep -q 'timesyncd.conf' "$loc_nix" ||
  fail "$loc_nix does not render systemd/timesyncd.conf"

# The flake-wide purity guard must still hold with nix/localization.nix in
# the tree.
purity_test="tests/unit/021-flake-purity.sh"
if [ -x "$purity_test" ]; then
  "$purity_test" || fail "$purity_test no longer passes with nix/localization.nix in the tree"
else
  fail "$purity_test is missing or not executable"
fi

# Mirror the spirit of 021 directly against nix/localization.nix: no
# nixpkgs package/fetcher references at all.
if grep -nE '\bpkgs\.|mkDerivation|buildInputs|fetchFromGitHub' "$loc_nix" > /dev/null 2>&1; then
  fail "$loc_nix references a forbidden nixpkgs-package-set pattern"
fi

exit "$fails"
