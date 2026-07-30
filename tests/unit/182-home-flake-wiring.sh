#!/usr/bin/env bash
# tests/unit/182-home-flake-wiring.sh — per-user home files/services
# primitive, static wiring checks (SPEC.md §9, §4.3; GitHub issue #98,
# milestone M5).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so nothing here can actually evaluate or
# build the flake — that's CI-only (the "flake" job in
# .github/workflows/ci.yml, which builds `.#home-proof`; see nix/home.nix's
# own comments). This test is a machine-checked textual guard instead,
# mirroring tests/unit/111-etc-flake-wiring.sh's/
# tests/unit/121-systemd-flake-wiring.sh's own relationship to their files:
# it confirms nix/home.nix exists, is imported by flake.nix, exposes
# flake.lib.home, is wired to a real per-system proof package, that CI
# builds/asserts it, and that the purity guard (021) still holds.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

home_nix="nix/home.nix"

[ -f "$home_nix" ] || {
  echo "FAIL: $home_nix does not exist" >&2
  exit 1
}

# flake.nix must actually import the dendritic module (SPEC.md §2 G8).
grep -q '\./nix/home\.nix' flake.nix ||
  fail "flake.nix does not import ./nix/home.nix"

grep -q 'flake.lib.home' "$home_nix" ||
  fail "$home_nix does not expose flake.lib.home"

for fn in validate render classOf; do
  grep -q "$fn" "$home_nix" || fail "$home_nix does not define/expose '$fn'"
done

# `render` must build via the shared Ubuntu-native builder, never a
# nixpkgs derivation function.
grep -q 'runInUbuntuBase' "$home_nix" ||
  fail "$home_nix does not build via runInUbuntuBase"
grep -qE 'config\.flake\.lib\.stdenv' "$home_nix" ||
  fail "$home_nix does not reach the stdenv builder via config.flake.lib.stdenv"

# Every declared entry's bytes must be routed through a real Nix store
# object (builtins.toFile / a source path), never spliced as raw shell
# text — see nix/etc.nix's header, "Rendering", for why (heredoc
# corruption risk); nix/home.nix mirrors that reasoning verbatim.
grep -q 'builtins.toFile' "$home_nix" ||
  fail "$home_nix does not route text entries through builtins.toFile"
grep -qE 'builtins\.hashString|builtins\.hashFile' "$home_nix" ||
  fail "$home_nix does not hash entry content in pure Nix"

# perSystem wiring for the fixture proof (issue #98).
grep -q 'packages.home-proof' "$home_nix" ||
  fail "$home_nix does not declare packages.home-proof"

grep -q 'throw' "$home_nix" ||
  fail "$home_nix has no throw at all -- eval-boundary validation must fail loudly"

# No owner/group knob on file entries — SPEC.md §9's own "correct
# ownership" contract (see nix/home.nix's own header) means the primitive
# must never accept one.
if grep -qE '\bowner\b.*mkOption|owner = e\.owner' "$home_nix"; then
  fail "$home_nix's file entries appear to accept an owner override — SPEC.md §9 says home files are always owned by the declaring user"
fi

# CI must actually build and assert on home-proof, mirroring how
# tests/unit/111/121 keep nix/etc.nix/nix/systemd.nix and ci.yml in
# lockstep.
ci_yml=".github/workflows/ci.yml"
[ -f "$ci_yml" ] || fail "$ci_yml does not exist"
if [ -f "$ci_yml" ]; then
  grep -q 'home-proof' "$ci_yml" ||
    fail "$ci_yml does not reference home-proof (the CI build/assert step is missing)"
fi

# The purity guard must still hold with nix/home.nix in the tree.
purity_test="tests/unit/021-flake-purity.sh"
if [ -x "$purity_test" ]; then
  "$purity_test" || fail "$purity_test no longer passes with nix/home.nix in the tree"
else
  fail "$purity_test is missing or not executable"
fi

# Mirror the spirit of 021 directly against nix/home.nix: no nixpkgs
# package/fetcher references at all.
if grep -nE '\bpkgs\.|mkDerivation|buildInputs|fetchFromGitHub' "$home_nix" >/dev/null 2>&1; then
  fail "$home_nix references a forbidden nixpkgs-package-set pattern"
fi

# The planner/executor pair this file's header promises must exist and be
# executable.
for tool in bin/ubx-home bin/ubx-home-apply; do
  [ -x "$tool" ] || fail "$tool does not exist or is not executable"
done

exit "$fails"
