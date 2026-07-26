#!/usr/bin/env bash
# tests/unit/170-pro-flake-wiring.sh — nix/pro.nix static wiring checks
# (SPEC.md §8.2 "Ubuntu Pro", §5, §11 M4; GitHub issue #82, milestone M4).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so nothing here can actually evaluate or
# build the flake. This test is a machine-checked textual guard instead,
# mirroring tests/unit/161-secrets-flake-wiring.sh's relationship to
# nix/secrets.nix: it confirms nix/pro.nix exists, is imported by flake.nix,
# exposes flake.lib.pro, throws on a bad declaration, is wired to a real
# per-system proof package, and that the purity guards (021, 171) still
# hold.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

pro_nix="nix/pro.nix"

[ -f "$pro_nix" ] || {
  echo "FAIL: $pro_nix does not exist" >&2
  exit 1
}

# flake.nix must actually import the dendritic module (SPEC.md §2 G8).
grep -q '\./nix/pro\.nix' flake.nix ||
  fail "flake.nix does not import ./nix/pro.nix"

# Must expose flake.lib.pro (same dendritic contribution pattern
# nix/secrets.nix/nix/users.nix/nix/etc.nix/nix/snap.nix each use).
grep -q 'flake.lib.pro' "$pro_nix" ||
  fail "$pro_nix does not expose flake.lib.pro"

for fn in proType mkManifest renderManifestJSON; do
  grep -q "$fn" "$pro_nix" || fail "$pro_nix does not define/expose '$fn'"
done

# mkManifest must actually `throw` on a violation (a real eval-boundary
# enforcement, not just documentation) -- mirrors tests/unit/041's/161's
# identical check.
grep -q 'throw' "$pro_nix" ||
  fail "$pro_nix has no throw -- mkManifest must actually refuse a bad declaration"

# lib.evalModules is the real Nix module system, not hand-rolled type
# checking -- mirrors nix/secrets.nix's own posture.
grep -q 'lib.evalModules' "$pro_nix" ||
  fail "$pro_nix does not validate via lib.evalModules"

# perSystem wiring for the fixture proof (mirrors nix/secrets.nix's own
# secrets-manifest-proof).
grep -q 'packages.pro-manifest-proof' "$pro_nix" ||
  fail "$pro_nix does not declare packages.pro-manifest-proof"
grep -q 'runInUbuntuBase' "$pro_nix" ||
  fail "$pro_nix does not build pro-manifest-proof via runInUbuntuBase"
grep -qE 'config\.flake\.lib\.stdenv' "$pro_nix" ||
  fail "$pro_nix does not reach the stdenv builder via config.flake.lib.stdenv"

# The purity guards must still hold with nix/pro.nix in the tree.
purity_test="tests/unit/021-flake-purity.sh"
if [ -x "$purity_test" ]; then
  "$purity_test" || fail "$purity_test no longer passes with nix/pro.nix in the tree"
else
  fail "$purity_test is missing or not executable"
fi

own_purity="tests/unit/171-pro-purity-guard.sh"
if [ -x "$own_purity" ]; then
  "$own_purity" || fail "$own_purity no longer passes"
else
  fail "$own_purity is missing or not executable"
fi

# Mirror the spirit of 021 directly against nix/pro.nix: no nixpkgs
# package/fetcher references at all.
if grep -nE '\bpkgs\.|mkDerivation|buildInputs|fetchFromGitHub' "$pro_nix" > /dev/null 2>&1; then
  fail "$pro_nix references a forbidden nixpkgs-package-set pattern"
fi

# bin/ubx-pro / bin/ubx-pro-apply must exist and be executable -- the
# planner/executor split this manifest is meant to feed (issue #82).
for f in bin/ubx-pro bin/ubx-pro-apply; do
  [ -x "$f" ] || fail "$f does not exist or is not executable"
done

exit "$fails"
