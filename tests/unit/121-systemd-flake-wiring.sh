#!/usr/bin/env bash
# tests/unit/121-systemd-flake-wiring.sh — systemd units/services primitive,
# static wiring checks (SPEC.md §4.3, §6; GitHub issue #27, milestone M2).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so nothing here can actually evaluate or
# build the flake -- that's CI-only (the "flake" job in
# .github/workflows/ci.yml, expected to build `.#systemd-proof`). This test
# is a machine-checked textual guard instead, mirroring
# tests/unit/111-etc-flake-wiring.sh's relationship to nix/etc.nix: it
# confirms nix/systemd.nix exists, is imported by flake.nix, exposes
# flake.lib.systemd, is wired to a real per-system proof package, and that
# the purity guard (021) still holds.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

systemd_nix="nix/systemd.nix"

[ -f "$systemd_nix" ] || {
  echo "FAIL: $systemd_nix does not exist" >&2
  exit 1
}

# flake.nix must actually import the dendritic module (SPEC.md §2 G8).
grep -q '\./nix/systemd\.nix' flake.nix ||
  fail "flake.nix does not import ./nix/systemd.nix"

grep -q 'flake.lib.systemd' "$systemd_nix" ||
  fail "$systemd_nix does not expose flake.lib.systemd"

for fn in validate render unitClasses classOf; do
  grep -q "$fn" "$systemd_nix" || fail "$systemd_nix does not define/expose '$fn'"
done

# `render` must build via the shared Ubuntu-native builder, never a
# nixpkgs derivation function.
grep -q 'runInUbuntuBase' "$systemd_nix" ||
  fail "$systemd_nix does not build via runInUbuntuBase"
grep -qE 'config\.flake\.lib\.stdenv' "$systemd_nix" ||
  fail "$systemd_nix does not reach the stdenv builder via config.flake.lib.stdenv"

# Every declared unit's bytes must be routed through a real Nix store
# object, never spliced as raw shell text (nix/etc.nix's own "Rendering"
# rationale, mirrored here).
grep -q 'builtins.toFile' "$systemd_nix" ||
  fail "$systemd_nix does not route text entries through builtins.toFile"
grep -qE 'builtins\.hashString|builtins\.hashFile' "$systemd_nix" ||
  fail "$systemd_nix does not hash entry content in pure Nix"

# perSystem wiring for the fixture proof (issue #27).
grep -q 'packages.systemd-proof' "$systemd_nix" ||
  fail "$systemd_nix does not declare packages.systemd-proof"

# Both primitives from SPEC.md §6 must be present: full-content units, and
# packaged-unit state-only services.
grep -q 'ubuntnix.systemd.units' "$systemd_nix" ||
  fail "$systemd_nix's header/comments don't document ubuntnix.systemd.units"
grep -q 'ubuntnix.systemd.services' "$systemd_nix" ||
  fail "$systemd_nix's header/comments don't document ubuntnix.systemd.services"

# The refuse-restart class rule (issue #27 scope) must be real code, not
# just a comment: the class table plus at least the always-cited refuse
# classes (socket, target, mount) must appear as data.
grep -q 'unitClasses' "$systemd_nix" || fail "$systemd_nix does not define a unit class table"
for cls in socket target mount; do
  grep -q "$cls" "$systemd_nix" || fail "$systemd_nix's class table does not mention '$cls'"
done

grep -q 'throw' "$systemd_nix" ||
  fail "$systemd_nix has no throw at all -- eval-boundary validation must fail loudly"

# CI must actually build and assert on systemd-proof, mirroring how
# tests/unit/111 keeps nix/etc.nix and ci.yml in lockstep.
ci_yml=".github/workflows/ci.yml"
[ -f "$ci_yml" ] || fail "$ci_yml does not exist"
if [ -f "$ci_yml" ]; then
  grep -q 'systemd-proof' "$ci_yml" ||
    fail "$ci_yml does not reference systemd-proof (the CI build/assert step is missing)"
fi

# The purity guard must still hold with nix/systemd.nix in the tree.
purity_test="tests/unit/021-flake-purity.sh"
if [ -x "$purity_test" ]; then
  "$purity_test" || fail "$purity_test no longer passes with nix/systemd.nix in the tree"
else
  fail "$purity_test is missing or not executable"
fi

# Mirror the spirit of 021 directly against nix/systemd.nix: no nixpkgs
# package/fetcher references at all.
if grep -nE '\bpkgs\.|mkDerivation|buildInputs|fetchFromGitHub' "$systemd_nix" >/dev/null 2>&1; then
  fail "$systemd_nix references a forbidden nixpkgs-package-set pattern"
fi

# bin/ubx-systemd and bin/ubx-systemd-apply must exist and be executable.
for f in bin/ubx-systemd bin/ubx-systemd-apply; do
  [ -x "$f" ] || fail "$f does not exist or is not executable"
done

exit "$fails"
