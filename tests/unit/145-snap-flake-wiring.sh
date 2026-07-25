#!/usr/bin/env bash
# tests/unit/145-snap-flake-wiring.sh — nix/snap.nix static wiring checks
# (SPEC.md §4.3, §4.4, §4.5, §6; GitHub issue #60, milestone M3).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so nothing here can actually evaluate or
# build the flake — that's CI-only. This test is a machine-checked textual
# guard instead, mirroring tests/unit/041-archive-flake-wiring.sh's
# relationship to nix/archive.nix: it confirms nix/snap.nix exists, is
# imported by flake.nix, actually reads snaps.lock.json via
# builtins.fromJSON, fetches through Nix's own <nix/fetchurl.nix> (never a
# nixpkgs fetcher), exposes flake.lib.snap with the expected functions, is
# wired to a real per-system proof package, and that the purity guard it
# exercises a carve-out in (021) still holds.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

snap_nix="nix/snap.nix"

[ -f "$snap_nix" ] || {
  echo "FAIL: $snap_nix does not exist" >&2
  exit 1
}

# flake.nix must actually import the dendritic module (SPEC.md §2 G8).
grep -q '\./nix/snap\.nix' flake.nix ||
  fail "flake.nix does not import ./nix/snap.nix"

# Must read snaps.lock.json as JSON and expose flake.lib.snap (same
# contribution pattern nix/archive.nix/nix/etc.nix/nix/systemd.nix use).
grep -q 'builtins.fromJSON' "$snap_nix" ||
  fail "$snap_nix does not parse the lockfile with builtins.fromJSON"
grep -qE '\.\./snaps\.lock\.json' "$snap_nix" ||
  fail "$snap_nix does not read ../snaps.lock.json"
grep -q 'flake.lib.snap' "$snap_nix" ||
  fail "$snap_nix does not expose flake.lib.snap"

# The core functions this issue's scope requires must all exist.
for fn in validate compileManifest renderManifest fetchSnap fetchAssert; do
  grep -q "$fn" "$snap_nix" ||
    fail "$snap_nix does not define $fn"
done

# fetchSnap/fetchAssert must use Nix's OWN internal fetchurl.nix (never a
# nixpkgs fetcher — the exact spelling 021's carve-out allows).
grep -q '<nix/fetchurl.nix>' "$snap_nix" ||
  fail "$snap_nix does not fetch via <nix/fetchurl.nix>"

# `snaps` (the name -> {snap; assert;} fetcher attrset, mirroring
# nix/archive.nix's `debs`) must exist.
grep -qE '^\s*snaps = builtins.listToAttrs' "$snap_nix" ||
  fail "$snap_nix does not define the snaps = builtins.listToAttrs (...) fetcher attrset"

# Both validate/compileManifest must actually `throw` on a violation (a
# real eval-boundary enforcement, not just documentation) -- mirrors
# tests/unit/041's identical check for nix/archive.nix's `validate`.
grep -q 'throw' "$snap_nix" ||
  fail "$snap_nix has no throw -- validate/compileManifest must actually refuse bad input"

# The verified-publisher policy (SPEC.md §4.5/§5) must be a real,
# grep-able enforcement point, not just prose.
grep -qi 'publisherVerified' "$snap_nix" ||
  fail "$snap_nix does not reference publisherVerified -- the verified-publisher policy is not wired"
grep -qi 'allowUnverifiedPublishers' "$snap_nix" ||
  fail "$snap_nix does not reference allowUnverifiedPublishers -- the per-system policy toggle is not wired"

# perSystem wiring for the proof derivation.
grep -q 'packages.snap-proof' "$snap_nix" ||
  fail "$snap_nix does not declare packages.snap-proof"
grep -q 'runInUbuntuBase' "$snap_nix" ||
  fail "$snap_nix does not build snap-proof via runInUbuntuBase"
grep -qE 'config\.flake\.lib\.stdenv' "$snap_nix" ||
  fail "$snap_nix does not reach the stdenv builder via config.flake.lib.stdenv"

# perSystem wiring for the fetch/mismatch proofs too (mirrors
# tests/unit/041's identical archive checks).
grep -q 'packages.snap-fetch-proof' "$snap_nix" ||
  fail "$snap_nix does not declare packages.snap-fetch-proof"
grep -q 'packages.snap-hash-mismatch-proof' "$snap_nix" ||
  fail "$snap_nix does not declare packages.snap-hash-mismatch-proof"
grep -q '"0000000000000000000000000000000000000000000000000000000000000000"' "$snap_nix" ||
  fail "$snap_nix's snap-hash-mismatch-proof does not use the documented 64-zero placeholder hash"

# CI must actually build and assert on the proofs, mirroring how
# tests/unit/041 keeps nix/archive.nix and ci.yml in lockstep.
ci_yml=".github/workflows/ci.yml"
[ -f "$ci_yml" ] || fail "$ci_yml does not exist"
if [ -f "$ci_yml" ]; then
  grep -q 'snap-proof' "$ci_yml" ||
    fail "$ci_yml does not reference snap-proof (the CI build/assert step is missing)"
  grep -q 'snap-fetch-proof' "$ci_yml" ||
    fail "$ci_yml does not reference snap-fetch-proof (the CI build/assert step is missing)"
  grep -q 'snap-hash-mismatch-proof' "$ci_yml" ||
    fail "$ci_yml does not reference snap-hash-mismatch-proof (the negative-path CI step is missing)"
fi

# The purity guard's <nix/fetchurl.nix> carve-out (021) must still hold.
purity_test="tests/unit/021-flake-purity.sh"
if [ -x "$purity_test" ]; then
  "$purity_test" || fail "$purity_test no longer passes with nix/snap.nix in the tree"
else
  fail "$purity_test is missing or not executable"
fi

# Mirror the spirit of 021 directly against nix/snap.nix: no nixpkgs
# package/fetcher references at all, beyond the already-permitted
# <nix/fetchurl.nix>/builtins.fetchurl spellings 021 itself carves out
# (checked above via running 021 in full).
if grep -nE '\bpkgs\.|mkDerivation|buildInputs|fetchFromGitHub' "$snap_nix" > /dev/null 2>&1; then
  fail "$snap_nix references a forbidden nixpkgs-package-set pattern"
fi

exit "$fails"
