#!/usr/bin/env bash
# tests/unit/178-filesystems-flake-wiring.sh — nix/filesystems.nix static
# wiring checks (SPEC.md §4.3 "fstab / systemd mount units + swap", §6
# "fileSystems."/data" = { ... };  # -> fstab / systemd mount units +
# swap"; GitHub issue #96).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so nothing here can actually evaluate or
# build the flake. This test is a machine-checked textual guard instead,
# mirroring tests/unit/175-crypttab-flake-wiring.sh's relationship to
# nix/crypttab.nix: it confirms nix/filesystems.nix exists, is imported by
# flake.nix, exposes flake.lib.fileSystems, throws on a bad declaration, is
# wired to a real per-system proof package, and that the flake-wide purity
# guard (021) still holds with it in the tree.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

fs_nix="nix/filesystems.nix"

[ -f "$fs_nix" ] || {
  echo "FAIL: $fs_nix does not exist" >&2
  exit 1
}

# flake.nix must actually import the dendritic module (SPEC.md §2 G8).
grep -q '\./nix/filesystems\.nix' flake.nix ||
  fail "flake.nix does not import ./nix/filesystems.nix"

# Must expose flake.lib.fileSystems (same dendritic contribution pattern
# nix/crypttab.nix/nix/etc.nix/nix/systemd.nix each use).
grep -q 'flake.lib.fileSystems' "$fs_nix" ||
  fail "$fs_nix does not expose flake.lib.fileSystems"

for fn in validate render renderJSON mountUnitName swapUnitName cryptDepOf; do
  grep -q "$fn" "$fs_nix" || fail "$fs_nix does not define/expose '$fn'"
done

# validate must actually `throw` on a violation (a real eval-boundary
# enforcement, not just documentation) -- mirrors tests/unit/175's/170's/
# 161's/041's identical check.
grep -q 'throw' "$fs_nix" ||
  fail "$fs_nix has no throw -- validate must actually refuse a bad declaration"

# perSystem wiring for the fixture proof (mirrors nix/crypttab.nix's own
# crypttab-manifest-proof).
grep -q 'packages.filesystems-manifest-proof' "$fs_nix" ||
  fail "$fs_nix does not declare packages.filesystems-manifest-proof"
grep -q 'runInUbuntuBase' "$fs_nix" ||
  fail "$fs_nix does not build filesystems-manifest-proof via runInUbuntuBase"
grep -qE 'config\.flake\.lib\.stdenv' "$fs_nix" ||
  fail "$fs_nix does not reach the stdenv builder via config.flake.lib.stdenv"

# Interop with nix/crypttab.nix (issue #96 acceptance criteria: "a LUKS
# device declared in crypttab can be referenced as a fileSystems device")
# must be real code, not just documentation: a /dev/mapper/<name> device
# must be recognized and wired to systemd-cryptsetup@<name>.service.
grep -q '/dev/mapper/' "$fs_nix" ||
  fail "$fs_nix does not recognize /dev/mapper/<name> devices (crypttab interop)"
grep -q 'systemd-cryptsetup@' "$fs_nix" ||
  fail "$fs_nix does not wire crypttab-backed devices to systemd-cryptsetup@<name>.service"

# The flake-wide purity guard must still hold with nix/filesystems.nix in
# the tree.
purity_test="tests/unit/021-flake-purity.sh"
if [ -x "$purity_test" ]; then
  "$purity_test" || fail "$purity_test no longer passes with nix/filesystems.nix in the tree"
else
  fail "$purity_test is missing or not executable"
fi

# Mirror the spirit of 021 directly against nix/filesystems.nix: no
# nixpkgs package/fetcher references at all.
if grep -nE '\bpkgs\.|mkDerivation|buildInputs|fetchFromGitHub' "$fs_nix" > /dev/null 2>&1; then
  fail "$fs_nix references a forbidden nixpkgs-package-set pattern"
fi

exit "$fails"
