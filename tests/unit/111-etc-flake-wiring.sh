#!/usr/bin/env bash
# tests/unit/111-etc-flake-wiring.sh — generated /etc, static wiring checks
# (SPEC.md §4.2, §4.3; GitHub issue #26, milestone M2).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so nothing here can actually evaluate or
# build the flake — that's CI-only (the "flake" job in
# .github/workflows/ci.yml, which builds `.#etc-proof`; see nix/etc.nix's
# own comments). This test is a machine-checked textual guard instead,
# mirroring tests/unit/041-archive-flake-wiring.sh's relationship to
# nix/archive.nix: it confirms nix/etc.nix exists, is imported by
# flake.nix, actually reads etc.exceptions.json via builtins.fromJSON,
# exposes flake.lib.etc, is wired to a real per-system proof package, that
# CI builds/asserts it, and that the purity guard (021) still holds.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

etc_nix="nix/etc.nix"

[ -f "$etc_nix" ] || {
  echo "FAIL: $etc_nix does not exist" >&2
  exit 1
}

# flake.nix must actually import the dendritic module (SPEC.md §2 G8).
grep -q '\./nix/etc\.nix' flake.nix ||
  fail "flake.nix does not import ./nix/etc.nix"

# The loader must read etc.exceptions.json from the repo root as JSON, and
# expose validate/render/exceptions under flake.lib.etc — the same
# contribution pattern nix/archive.nix uses for flake.lib.archive.
grep -q 'builtins.fromJSON' "$etc_nix" ||
  fail "$etc_nix does not parse etc.exceptions.json with builtins.fromJSON"
grep -qE '\.\./etc\.exceptions\.json' "$etc_nix" ||
  fail "$etc_nix does not read ../etc.exceptions.json"
grep -q 'flake.lib.etc' "$etc_nix" ||
  fail "$etc_nix does not expose flake.lib.etc"

for fn in validate render exceptions exceptionPaths isExceptionPath; do
  grep -q "$fn" "$etc_nix" || fail "$etc_nix does not define/expose '$fn'"
done

# `render` must build via the shared Ubuntu-native builder, never a
# nixpkgs derivation function.
grep -q 'runInUbuntuBase' "$etc_nix" ||
  fail "$etc_nix does not build via runInUbuntuBase"
grep -qE 'config\.flake\.lib\.stdenv' "$etc_nix" ||
  fail "$etc_nix does not reach the stdenv builder via config.flake.lib.stdenv"

# Every declared entry's bytes must be routed through a real Nix store
# object (builtins.toFile / a source path), never spliced as raw shell
# text — see nix/etc.nix's header, "Rendering", for why (heredoc
# corruption risk).
grep -q 'builtins.toFile' "$etc_nix" ||
  fail "$etc_nix does not route text entries through builtins.toFile"
grep -qE 'builtins\.hashString|builtins\.hashFile' "$etc_nix" ||
  fail "$etc_nix does not hash entry content in pure Nix"

# perSystem wiring for the fixture proof (issue #26).
grep -q 'packages.etc-proof' "$etc_nix" ||
  fail "$etc_nix does not declare packages.etc-proof"

# The machine-local mutable exception enforcement (issue #26 scope item 3)
# must reject a declared exception path at THIS eval boundary, independent
# of bin/ubx-etc's own defense-in-depth refusal.
grep -q 'isExceptionPath' "$etc_nix" ||
  fail "$etc_nix's validate does not check isExceptionPath"
grep -q 'throw' "$etc_nix" ||
  fail "$etc_nix has no throw at all -- eval-boundary validation must fail loudly"

# CI must actually build and assert on etc-proof, mirroring how
# tests/unit/041 keeps nix/archive.nix and ci.yml in lockstep.
ci_yml=".github/workflows/ci.yml"
[ -f "$ci_yml" ] || fail "$ci_yml does not exist"
if [ -f "$ci_yml" ]; then
  grep -q 'etc-proof' "$ci_yml" ||
    fail "$ci_yml does not reference etc-proof (the CI build/assert step is missing)"
fi

# The purity guard must still hold with nix/etc.nix in the tree.
purity_test="tests/unit/021-flake-purity.sh"
if [ -x "$purity_test" ]; then
  "$purity_test" || fail "$purity_test no longer passes with nix/etc.nix in the tree"
else
  fail "$purity_test is missing or not executable"
fi

# Mirror the spirit of 021 directly against nix/etc.nix: no nixpkgs
# package/fetcher references at all. `\bpkgs\.` (not a bare "pkgs."
# substring) to avoid false-positiving on the legitimate `nixpkgs.lib`
# reference -- see tests/unit/021-flake-purity.sh's own comment for why.
if grep -nE '\bpkgs\.|mkDerivation|buildInputs|fetchFromGitHub' "$etc_nix" >/dev/null 2>&1; then
  fail "$etc_nix references a forbidden nixpkgs-package-set pattern"
fi

exit "$fails"
