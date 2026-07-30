#!/usr/bin/env bash
# tests/unit/182-profiles-flake-wiring.sh — nix/profiles.nix static wiring
# checks (SPEC.md §6 "profiles.server.enable = true;", §11 M5 exit
# criterion; GitHub issue #99).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so nothing here can actually evaluate or
# build the flake. This test is a machine-checked textual guard instead,
# mirroring tests/unit/178-filesystems-flake-wiring.sh's/tests/unit/180's
# relationship to their own subject files: it confirms nix/profiles.nix
# exists, is imported by flake.nix, exposes flake.lib.profiles.server,
# throws on a bad declaration, is wired to real per-system proof/image
# packages, that examples/server.nix exists and is actually consumed, and
# that the flake-wide purity guard (021) still holds with it in the tree.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

profiles_nix="nix/profiles.nix"
example_config="examples/server.nix"

[ -f "$profiles_nix" ] || {
  echo "FAIL: $profiles_nix does not exist" >&2
  exit 1
}
[ -f "$example_config" ] || fail "$example_config does not exist"

# flake.nix must actually import the dendritic module (SPEC.md §2 G8).
grep -q '\./nix/profiles\.nix' flake.nix ||
  fail "flake.nix does not import ./nix/profiles.nix"

# Must expose flake.lib.profiles.server (same dendritic contribution
# pattern nix/filesystems.nix/nix/localization.nix/nix/networking.nix each
# use for their own file).
grep -q 'flake.lib.profiles' "$profiles_nix" ||
  fail "$profiles_nix does not expose flake.lib.profiles"

for fn in validateDecl render renderJSON serverSeedPackages serverSeedExceptions; do
  grep -q "$fn" "$profiles_nix" || fail "$profiles_nix does not define/expose '$fn'"
done

# validateDecl must actually `throw` on a violation (a real eval-boundary
# enforcement, not just documentation) -- mirrors tests/unit/178's/180's/
# 175's identical check.
grep -q 'throw' "$profiles_nix" ||
  fail "$profiles_nix has no throw -- validateDecl must actually refuse a bad declaration"

# The profiles.server manifest proof, forced at eval time (CI's "flake"
# job) -- mirrors nix/filesystems.nix's own filesystems-manifest-proof.
grep -q 'packages.profiles-server-manifest-proof' "$profiles_nix" ||
  fail "$profiles_nix does not declare packages.profiles-server-manifest-proof"
grep -q 'runInUbuntuBase' "$profiles_nix" ||
  fail "$profiles_nix does not build profiles-server-manifest-proof via runInUbuntuBase"

# The actual bootable QEMU e2e image output (GitHub issue #99 task item 4).
grep -q 'packages.server-parity-image' "$profiles_nix" ||
  fail "$profiles_nix does not declare packages.server-parity-image"

# The image must actually go through nix/boot.nix's own pipeline (never a
# parallel/reimplemented one -- SPEC.md §11 M5 reuses M1's boot machinery).
for fn in bootRootfs kernelArtifacts grubCfg diskImage; do
  grep -q "$fn" "$profiles_nix" || fail "$profiles_nix does not use nix/boot.nix's '$fn'"
done

# The example config must actually be consumed, not just sit unreferenced.
grep -q '\.\./examples/server\.nix' "$profiles_nix" ||
  fail "$profiles_nix does not import ../examples/server.nix"

# cloud-init present-but-inert (SPEC.md §12 R12).
grep -q 'cloud-init.disabled' "$profiles_nix" ||
  fail "$profiles_nix does not render the cloud-init disabled marker (SPEC.md sec12 R12)"

# The QEMU e2e test this issue adds must exist and be executable.
e2e_test="tests/e2e/050-qemu-server-parity-e2e.sh"
[ -x "$e2e_test" ] || fail "$e2e_test does not exist or is not executable"

# examples/server.nix must actually wire the landed M5 base modules
# (networking, fileSystems+swap, i18n/console/time, users) plus
# profiles.server.enable -- SPEC.md §10's own worked-example shape.
if [ -f "$example_config" ]; then
  for field in networking fileSystems swapDevices i18n console time users profiles.server.enable; do
    grep -q "$field" "$example_config" || fail "$example_config does not declare '$field'"
  done
fi

# The flake-wide purity guard must still hold with nix/profiles.nix and
# examples/server.nix in the tree.
purity_test="tests/unit/021-flake-purity.sh"
if [ -x "$purity_test" ]; then
  "$purity_test" || fail "$purity_test no longer passes with nix/profiles.nix in the tree"
else
  fail "$purity_test is missing or not executable"
fi

# Mirror the spirit of 021 directly against nix/profiles.nix/examples/
# server.nix: no nixpkgs package/fetcher references at all.
for f in "$profiles_nix" "$example_config"; do
  [ -f "$f" ] || continue
  if grep -nE '\bpkgs\.|mkDerivation|buildInputs|fetchFromGitHub' "$f" > /dev/null 2>&1; then
    fail "$f references a forbidden nixpkgs-package-set pattern"
  fi
done

exit "$fails"
