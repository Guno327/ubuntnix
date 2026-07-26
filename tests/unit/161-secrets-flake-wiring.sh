#!/usr/bin/env bash
# tests/unit/161-secrets-flake-wiring.sh — nix/secrets.nix static wiring
# checks (SPEC.md §8.1, §6, §4.3; GitHub issue #78, milestone M4).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so nothing here can actually evaluate or
# build the flake. This test is a machine-checked textual guard instead,
# mirroring tests/unit/041-archive-flake-wiring.sh's relationship to
# nix/archive.nix and nix/users.nix's own (lighter, no-CI-proof) wiring
# precedent: it confirms nix/secrets.nix exists, is imported by flake.nix,
# exposes flake.lib.secrets, throws on a bad declaration, is wired to a
# real per-system proof package, and that the purity guard (021) still
# holds.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

secrets_nix="nix/secrets.nix"

[ -f "$secrets_nix" ] || {
  echo "FAIL: $secrets_nix does not exist" >&2
  exit 1
}

# flake.nix must actually import the dendritic module (SPEC.md §2 G8).
grep -q '\./nix/secrets\.nix' flake.nix ||
  fail "flake.nix does not import ./nix/secrets.nix"

# Must expose flake.lib.secrets (same contribution pattern nix/users.nix/
# nix/etc.nix/nix/snap.nix each use).
grep -q 'flake.lib.secrets' "$secrets_nix" ||
  fail "$secrets_nix does not expose flake.lib.secrets"

for fn in secretType mkManifest renderManifestJSON; do
  grep -q "$fn" "$secrets_nix" || fail "$secrets_nix does not define/expose '$fn'"
done

# mkManifest must actually `throw` on a violation (a real eval-boundary
# enforcement, not just documentation) -- mirrors tests/unit/041's
# identical check for nix/archive.nix's `validate`.
grep -q 'throw' "$secrets_nix" ||
  fail "$secrets_nix has no throw -- mkManifest must actually refuse a bad declaration"

# lib.evalModules is the real Nix module system, not hand-rolled type
# checking -- mirrors nix/users.nix's own posture.
grep -q 'lib.evalModules' "$secrets_nix" ||
  fail "$secrets_nix does not validate via lib.evalModules"

# perSystem wiring for the fixture proof (mirrors nix/users.nix's own
# users-manifest-proof).
grep -q 'packages.secrets-manifest-proof' "$secrets_nix" ||
  fail "$secrets_nix does not declare packages.secrets-manifest-proof"
grep -q 'runInUbuntuBase' "$secrets_nix" ||
  fail "$secrets_nix does not build secrets-manifest-proof via runInUbuntuBase"
grep -qE 'config\.flake\.lib\.stdenv' "$secrets_nix" ||
  fail "$secrets_nix does not reach the stdenv builder via config.flake.lib.stdenv"

# The example fixture files the proof's exampleManifest points at must be
# real, committed placeholder (NOT real secret material) files.
for f in pro-token api-token wg0.key; do
  [ -f "nix/example-secrets/$f" ] || fail "nix/example-secrets/$f (referenced by secrets-manifest-proof's exampleManifest) is missing"
done
grep -q 'PLACEHOLDER-NOT-REAL-MATERIAL' nix/example-secrets/pro-token 2>/dev/null ||
  fail "nix/example-secrets/pro-token does not look like the documented placeholder content"

# The purity guard must still hold with nix/secrets.nix in the tree.
purity_test="tests/unit/021-flake-purity.sh"
if [ -x "$purity_test" ]; then
  "$purity_test" || fail "$purity_test no longer passes with nix/secrets.nix in the tree"
else
  fail "$purity_test is missing or not executable"
fi

# tests/unit/160's own purity guard must still hold too.
own_purity="tests/unit/160-secrets-purity-guard.sh"
if [ -x "$own_purity" ]; then
  "$own_purity" || fail "$own_purity no longer passes"
else
  fail "$own_purity is missing or not executable"
fi

# Mirror the spirit of 021 directly against nix/secrets.nix: no nixpkgs
# package/fetcher references at all.
if grep -nE '\bpkgs\.|mkDerivation|buildInputs|fetchFromGitHub' "$secrets_nix" > /dev/null 2>&1; then
  fail "$secrets_nix references a forbidden nixpkgs-package-set pattern"
fi

exit "$fails"
