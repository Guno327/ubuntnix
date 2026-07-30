#!/usr/bin/env bash
# tests/unit/193-profiles-desktop-flake-wiring.sh — nix/profiles.nix static
# wiring checks for `profiles.desktop` (SPEC.md §6 "profiles.desktop.enable
# = true; # -> upstream desktop seed", §5 "Package policy", §10 "parity
# example configs", §11 M6; GitHub issue #107). Direct sibling of
# tests/unit/186-profiles-server-flake-wiring.sh -- same checks, desktop's
# own spellings.
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so nothing here can actually evaluate or
# build the flake. This test is a machine-checked textual guard instead: it
# confirms nix/profiles.nix exposes flake.lib.profiles.desktop, throws on a
# bad declaration, is wired to a real per-system proof package, and that
# the flake-wide purity guard (021) still holds with it in the tree.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

profiles_nix="nix/profiles.nix"

[ -f "$profiles_nix" ] || {
  echo "FAIL: $profiles_nix does not exist" >&2
  exit 1
}

# flake.nix must actually import the dendritic module (SPEC.md §2 G8) --
# same file as profiles.server, so re-asserted here for completeness.
grep -q '\./nix/profiles\.nix' flake.nix ||
  fail "flake.nix does not import ./nix/profiles.nix"

# Must expose flake.lib.profiles.desktop (same dendritic contribution
# pattern nix/profiles.nix's own `server` key already uses).
grep -q 'flake.lib.profiles' "$profiles_nix" ||
  fail "$profiles_nix does not expose flake.lib.profiles"
grep -q 'desktop = {' "$profiles_nix" ||
  fail "$profiles_nix does not expose a 'desktop' key under flake.lib.profiles"

for fn in desktopSeedPackages desktopSeedExceptions; do
  grep -q "$fn" "$profiles_nix" || fail "$profiles_nix does not define/expose '$fn'"
done

# The declaration surface's own validator/renderer.
grep -q 'desktopValidateDecl' "$profiles_nix" ||
  fail "$profiles_nix does not define a desktopValidateDecl function"
grep -q 'desktopRender' "$profiles_nix" ||
  fail "$profiles_nix does not define a desktopRender function"

# The validator must actually `throw` on a violation for profiles.desktop
# specifically (a real eval-boundary enforcement, not just documentation).
grep -q 'profiles.desktop failed eval-boundary validation' "$profiles_nix" ||
  fail "$profiles_nix's desktopValidateDecl has no throw -- it must actually refuse a bad declaration"

# A real per-system proof package forced at eval time (CI's "flake" job),
# built via the project's own hardened stdenv builder -- mirrors
# profiles-server-manifest-proof.
grep -qE 'packages\.[A-Za-z0-9_-]*profiles-desktop[A-Za-z0-9_-]*(-proof|-manifest-proof)' "$profiles_nix" ||
  fail "$profiles_nix does not declare a profiles-desktop-*-proof package"

# The actual desktop-parity-image build-time proof target this issue's own
# acceptance criteria call for (GitHub issue #107).
grep -qE 'packages\.desktop-parity-image[[:space:]]*=' "$profiles_nix" ||
  fail "$profiles_nix does not declare packages.desktop-parity-image"

# Display-manager / graphical-target wiring must be real code, not just
# documentation (GitHub issue #107's own acceptance criterion 3).
grep -q 'graphical.target' "$profiles_nix" ||
  fail "$profiles_nix does not reference graphical.target"
grep -qE 'gdm\.service' "$profiles_nix" ||
  fail "$profiles_nix does not reference gdm.service (the display-manager unit)"

# Package seed must be sourced from the archive lockfile (nix/archive.nix),
# never a hand-invented package list disconnected from it -- desktop shares
# the same `lockfile` binding profiles.server already reads.
grep -qE 'config\.flake\.lib\.archive' "$profiles_nix" ||
  fail "$profiles_nix does not source its package seed from config.flake.lib.archive"

# The flake-wide purity guard must still hold with nix/profiles.nix
# (desktop additions included) in the tree.
purity_test="tests/unit/021-flake-purity.sh"
if [ -x "$purity_test" ]; then
  "$purity_test" || fail "$purity_test no longer passes with nix/profiles.nix's desktop additions in the tree"
else
  fail "$purity_test is missing or not executable"
fi

# Mirror the spirit of 021 directly against nix/profiles.nix: no nixpkgs
# package/fetcher references at all.
if grep -nE '\bpkgs\.|mkDerivation|buildInputs|fetchFromGitHub' "$profiles_nix" > /dev/null 2>&1; then
  fail "$profiles_nix references a forbidden nixpkgs-package-set pattern"
fi

exit "$fails"
