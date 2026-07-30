#!/usr/bin/env bash
# tests/unit/200-installer-flake-wiring.sh — nix/installer.nix static
# wiring checks (SPEC.md §10 "the installer ... compiles the user's
# answers into config"; GitHub issue #113).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so this is a machine-checked textual guard,
# mirroring tests/unit/180-localization-flake-wiring.sh's relationship to
# nix/localization.nix: confirms nix/installer.nix exists, is imported by
# flake.nix, exposes flake.lib.installer.{validateAnswers,compileAnswers},
# throws on a bad declaration, and is wired to a real per-system proof
# package.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

installer_nix="nix/installer.nix"

[ -f "$installer_nix" ] || {
  echo "FAIL: $installer_nix does not exist" >&2
  exit 1
}

# flake.nix must actually import the dendritic module (SPEC.md §2 G8).
grep -q '\./nix/installer\.nix' flake.nix ||
  fail "flake.nix does not import ./nix/installer.nix"

# Must expose flake.lib.installer with both required functions (issue
# #113's own acceptance criteria: "flake.lib.installer.compileAnswers"
# and "validateAnswers").
grep -q 'flake.lib.installer' "$installer_nix" ||
  fail "$installer_nix does not expose flake.lib.installer"

for fn in validateAnswers compileAnswers; do
  grep -q "$fn" "$installer_nix" || fail "$installer_nix does not define/expose '$fn'"
done

# validateAnswers must actually `throw` on a violation (a real
# eval-boundary enforcement, not just documentation) -- mirrors
# tests/unit/180's/182's/178's own identical check.
grep -q 'throw' "$installer_nix" ||
  fail "$installer_nix has no throw -- validation must actually refuse a bad declaration"

# compileAnswers must actually run its input through validateAnswers (not
# bypass it) -- mirrors nix/localization.nix's own
# 'render = decl: renderDeclaration (validateDecl decl);' posture.
grep -qE 'compileAnswers[[:space:]]*=' "$installer_nix" ||
  fail "$installer_nix does not define compileAnswers as a binding"
grep -qE 'validateAnswers[[:space:]]+answers' "$installer_nix" ||
  fail "$installer_nix's compileAnswers does not appear to call validateAnswers on its input"

# perSystem wiring for the fixture proof (mirrors nix/localization.nix's
# own localization-manifest-proof).
grep -q 'packages.installer-compiler-proof' "$installer_nix" ||
  fail "$installer_nix does not declare packages.installer-compiler-proof"
grep -q 'runInUbuntuBase' "$installer_nix" ||
  fail "$installer_nix does not build installer-compiler-proof via runInUbuntuBase"
grep -qE 'config\.flake\.lib\.stdenv' "$installer_nix" ||
  fail "$installer_nix does not reach the stdenv builder via config.flake.lib.stdenv"

# The full mapping (SPEC.md §10) must show up as real fields being
# compiled, not just documentation.
for field in fileSystems swapDevices i18n console time users groups profiles crypttab; do
  grep -q "$field" "$installer_nix" || fail "$installer_nix does not compile a '$field' field"
done
grep -q 'archive.components' "$installer_nix" ||
  fail "$installer_nix does not compile the third-party checkbox to archive.components"
grep -q 'hashedPasswordSecret' "$installer_nix" ||
  fail "$installer_nix does not route identity's password through hashedPasswordSecret"

# The flake-wide purity guard must still hold with nix/installer.nix in
# the tree.
purity_test="tests/unit/021-flake-purity.sh"
if [ -x "$purity_test" ]; then
  "$purity_test" || fail "$purity_test no longer passes with nix/installer.nix in the tree"
else
  fail "$purity_test is missing or not executable"
fi

# Mirror the spirit of 021 directly against nix/installer.nix: no
# nixpkgs package/fetcher references, no ISO/network/IFD-shaped calls (a
# PURE compiler must never reach for any of these -- issue #113's own
# "no ISO, no network, no IFD, no runtime side effects" requirement).
if grep -nE '\bpkgs\.|mkDerivation|buildInputs|fetchFromGitHub' "$installer_nix" > /dev/null 2>&1; then
  fail "$installer_nix references a forbidden nixpkgs-package-set pattern"
fi
if grep -nE 'builtins\.(fetchTarball|fetchGit|fetchurl)|import[[:space:]]*<' "$installer_nix" > /dev/null 2>&1; then
  fail "$installer_nix references a forbidden network/IFD-shaped fetcher"
fi

exit "$fails"
