#!/usr/bin/env bash
# tests/unit/186-profiles-server-flake-wiring.sh — nix/profiles.nix static
# wiring checks (SPEC.md §6 "profiles.server.enable = true; # -> upstream
# server seed", §5 "Package policy", §10 "parity example configs"; GitHub
# issue #99, first slice — nix/profiles.nix + examples/server.nix already
# landed under GitHub issue #99's own earlier work; this is the Engineer's
# independently-numbered wiring test for that same module, per this
# project's convention of one flake-wiring test per dendritic file).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so nothing here can actually evaluate or
# build the flake. This test is a machine-checked textual guard instead,
# mirroring tests/unit/178-filesystems-flake-wiring.sh's/tests/unit/180's
# relationship to their own subject files: it confirms nix/profiles.nix
# exists, is imported by flake.nix, exposes flake.lib.profiles.server,
# throws on a bad declaration, is wired to a real per-system proof
# package, and that the flake-wide purity guard (021) still holds with it
# in the tree.
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

# flake.nix must actually import the dendritic module (SPEC.md §2 G8).
grep -q '\./nix/profiles\.nix' flake.nix ||
  fail "flake.nix does not import ./nix/profiles.nix"

# Must expose flake.lib.profiles.server (same dendritic contribution
# pattern nix/filesystems.nix/nix/localization.nix/nix/networking.nix each
# use for their own file).
grep -q 'flake.lib.profiles' "$profiles_nix" ||
  fail "$profiles_nix does not expose flake.lib.profiles"
grep -q 'server' "$profiles_nix" ||
  fail "$profiles_nix does not expose a 'server' key under flake.lib.profiles"

for fn in serverSeedPackages serverSeedExceptions; do
  grep -q "$fn" "$profiles_nix" || fail "$profiles_nix does not define/expose '$fn'"
done

# The declaration surface's own validator/renderer -- exact spellings may
# differ across sibling showcase modules (validate vs validateDecl), so
# accept either, but at least one real validate+render pair must exist.
grep -qE '\bvalidate(Decl)?\b' "$profiles_nix" ||
  fail "$profiles_nix does not define a validate/validateDecl function"
grep -qE '\brender\b' "$profiles_nix" ||
  fail "$profiles_nix does not define a render function"

# The validator must actually `throw` on a violation (a real eval-boundary
# enforcement, not just documentation) -- mirrors tests/unit/178's/180's/
# 175's identical check.
grep -q 'throw' "$profiles_nix" ||
  fail "$profiles_nix has no throw -- its validator must actually refuse a bad declaration"

# A real per-system proof package forced at eval time (CI's "flake" job),
# built via the project's own hardened stdenv builder -- mirrors
# nix/filesystems.nix's own filesystems-manifest-proof/nix/networking.nix's
# own networking-proof.
grep -qE 'packages\.[A-Za-z0-9_-]*profiles[A-Za-z0-9_-]*(-proof|-manifest-proof)' "$profiles_nix" ||
  fail "$profiles_nix does not declare a profiles-*-proof package"
grep -q 'runInUbuntuBase' "$profiles_nix" ||
  fail "$profiles_nix does not build its proof package(s) via runInUbuntuBase"

# cloud-init present-but-inert (SPEC.md §12 R12) must be real code, not
# just documentation.
grep -q 'cloud-init.disabled' "$profiles_nix" ||
  fail "$profiles_nix does not render the cloud-init disabled marker (SPEC.md sec12 R12)"

# Package seed must be sourced from the archive lockfile (nix/archive.nix),
# never a hand-invented package list disconnected from it (this issue's own
# scoping: "declare via the existing surface, don't invent a fetch path").
grep -qE 'config\.flake\.lib\.archive' "$profiles_nix" ||
  fail "$profiles_nix does not source its package seed from config.flake.lib.archive"

# The flake-wide purity guard must still hold with nix/profiles.nix in the
# tree.
purity_test="tests/unit/021-flake-purity.sh"
if [ -x "$purity_test" ]; then
  "$purity_test" || fail "$purity_test no longer passes with nix/profiles.nix in the tree"
else
  fail "$purity_test is missing or not executable"
fi

# Mirror the spirit of 021 directly against nix/profiles.nix: no nixpkgs
# package/fetcher references at all.
if grep -nE '\bpkgs\.|mkDerivation|buildInputs|fetchFromGitHub' "$profiles_nix" > /dev/null 2>&1; then
  fail "$profiles_nix references a forbidden nixpkgs-package-set pattern"
fi

exit "$fails"
