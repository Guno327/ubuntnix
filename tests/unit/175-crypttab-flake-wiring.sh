#!/usr/bin/env bash
# tests/unit/175-crypttab-flake-wiring.sh — nix/crypttab.nix static wiring
# checks (SPEC.md §11 M4 "passphrase-LUKS groundwork (crypttab/
# fileSystems)", §4.2 "generated /etc"; GitHub issue #83, milestone M4).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so nothing here can actually evaluate or
# build the flake. This test is a machine-checked textual guard instead,
# mirroring tests/unit/170-pro-flake-wiring.sh's relationship to
# nix/pro.nix: it confirms nix/crypttab.nix exists, is imported by
# flake.nix, exposes flake.lib.crypttab, throws on a bad declaration, is
# wired to a real per-system proof package, and that the flake-wide purity
# guard (021) still holds with it in the tree.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

crypttab_nix="nix/crypttab.nix"

[ -f "$crypttab_nix" ] || {
  echo "FAIL: $crypttab_nix does not exist" >&2
  exit 1
}

# flake.nix must actually import the dendritic module (SPEC.md §2 G8).
grep -q '\./nix/crypttab\.nix' flake.nix ||
  fail "flake.nix does not import ./nix/crypttab.nix"

# Must expose flake.lib.crypttab (same dendritic contribution pattern
# nix/pro.nix/nix/etc.nix/nix/secrets.nix each use).
grep -q 'flake.lib.crypttab' "$crypttab_nix" ||
  fail "$crypttab_nix does not expose flake.lib.crypttab"

for fn in validate render renderJSON mountUnitName; do
  grep -q "$fn" "$crypttab_nix" || fail "$crypttab_nix does not define/expose '$fn'"
done

# validate must actually `throw` on a violation (a real eval-boundary
# enforcement, not just documentation) -- mirrors tests/unit/170's/161's/
# 041's identical check.
grep -q 'throw' "$crypttab_nix" ||
  fail "$crypttab_nix has no throw -- validate must actually refuse a bad declaration"

# perSystem wiring for the fixture proof (mirrors nix/pro.nix's own
# pro-manifest-proof).
grep -q 'packages.crypttab-manifest-proof' "$crypttab_nix" ||
  fail "$crypttab_nix does not declare packages.crypttab-manifest-proof"
grep -q 'runInUbuntuBase' "$crypttab_nix" ||
  fail "$crypttab_nix does not build crypttab-manifest-proof via runInUbuntuBase"
grep -qE 'config\.flake\.lib\.stdenv' "$crypttab_nix" ||
  fail "$crypttab_nix does not reach the stdenv builder via config.flake.lib.stdenv"

# The flake-wide purity guard must still hold with nix/crypttab.nix in the
# tree.
purity_test="tests/unit/021-flake-purity.sh"
if [ -x "$purity_test" ]; then
  "$purity_test" || fail "$purity_test no longer passes with nix/crypttab.nix in the tree"
else
  fail "$purity_test is missing or not executable"
fi

# Mirror the spirit of 021 directly against nix/crypttab.nix: no nixpkgs
# package/fetcher references at all.
if grep -nE '\bpkgs\.|mkDerivation|buildInputs|fetchFromGitHub' "$crypttab_nix" > /dev/null 2>&1; then
  fail "$crypttab_nix references a forbidden nixpkgs-package-set pattern"
fi

# bin/ubx-crypttab / bin/ubx-crypttab-apply must exist and be executable --
# the planner/executor split this manifest is meant to feed (issue #83).
for f in bin/ubx-crypttab bin/ubx-crypttab-apply; do
  [ -x "$f" ] || fail "$f does not exist or is not executable"
done

exit "$fails"
