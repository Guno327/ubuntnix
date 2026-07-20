#!/usr/bin/env bash
# tests/unit/041-archive-flake-wiring.sh — archive lockfile fetcher, static
# wiring checks (SPEC.md §4.4; GitHub issue #7, milestone M1).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so nothing here can actually evaluate or
# build the flake — that's CI-only (the "flake" job in
# .github/workflows/ci.yml, which builds `.#archive-fetch-proof` and
# asserts the negative-path failure of `.#archive-hash-mismatch-proof`;
# see nix/archive.nix's own comments). This test is a machine-checked
# textual guard instead, mirroring tests/unit/030-stdenv-flake-wiring.sh's
# relationship to nix/stdenv.nix: it confirms nix/archive.nix exists, is
# imported by flake.nix, actually reads archive.lock.json via
# builtins.fromJSON, fetches through Nix's own <nix/fetchurl.nix> (never a
# nixpkgs fetcher), exposes flake.lib.archive, is wired to real per-system
# proof packages, that CI builds/asserts them (including the negative
# hash-mismatch case), and that the purity guard it exercises a carve-out
# in (021) still holds.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

archive_nix="nix/archive.nix"

[ -f "$archive_nix" ] || {
  echo "FAIL: $archive_nix does not exist" >&2
  exit 1
}

# flake.nix must actually import the dendritic module (SPEC.md §2 G8).
grep -q '\./nix/archive\.nix' flake.nix ||
  fail "flake.nix does not import ./nix/archive.nix"

# The loader must read the lockfile from the repo root as JSON, and expose
# it (plus the fetch machinery) under flake.lib.archive — the same
# contribution pattern nix/ubx.nix and nix/stdenv.nix use for
# flake.lib.ubx / flake.lib.stdenv.
grep -q 'builtins.fromJSON' "$archive_nix" ||
  fail "$archive_nix does not parse the lockfile with builtins.fromJSON"
grep -qE '\.\./archive\.lock\.json' "$archive_nix" ||
  fail "$archive_nix does not read ../archive.lock.json"
grep -q 'flake.lib.archive' "$archive_nix" ||
  fail "$archive_nix does not expose flake.lib.archive"

# fetchDeb must exist and must use Nix's OWN internal fetchurl.nix (never a
# nixpkgs fetcher — the exact spelling 021's carve-out allows).
grep -q 'fetchDeb' "$archive_nix" ||
  fail "$archive_nix does not define fetchDeb"
grep -q '<nix/fetchurl.nix>' "$archive_nix" ||
  fail "$archive_nix does not fetch debs via <nix/fetchurl.nix>"

# debs must exist, mapping the lockfile's public packages through fetchDeb.
grep -q 'debs' "$archive_nix" ||
  fail "$archive_nix does not define debs"

# perSystem wiring for both proof derivations (issue #7 task item 3): the
# positive fetch-and-verify proof, and the negative deliberately-wrong-hash
# proof CI asserts FAILS to build.
grep -q 'packages.archive-fetch-proof' "$archive_nix" ||
  fail "$archive_nix does not declare packages.archive-fetch-proof"
grep -q 'packages.archive-hash-mismatch-proof' "$archive_nix" ||
  fail "$archive_nix does not declare packages.archive-hash-mismatch-proof"
grep -q 'runInUbuntuBase' "$archive_nix" ||
  fail "$archive_nix does not build archive-fetch-proof via runInUbuntuBase"
grep -qE 'config\.flake\.lib\.stdenv' "$archive_nix" ||
  fail "$archive_nix does not reach the stdenv builder via config.flake.lib.stdenv"

# The mismatch proof must actually be wrong on purpose: a 64-zero sha256,
# unmistakably not a real digest.
grep -q '"0000000000000000000000000000000000000000000000000000000000000000"' "$archive_nix" ||
  fail "$archive_nix's archive-hash-mismatch-proof does not use the documented 64-zero placeholder hash"

# CI must actually build and assert on the fetch proof, AND run the
# negative case for the mismatch proof, mirroring how tests/unit/030 keeps
# nix/stdenv.nix and ci.yml in lockstep.
ci_yml=".github/workflows/ci.yml"
[ -f "$ci_yml" ] || fail "$ci_yml does not exist"
if [ -f "$ci_yml" ]; then
  grep -q 'archive-fetch-proof' "$ci_yml" ||
    fail "$ci_yml does not reference archive-fetch-proof (the CI build/assert step is missing)"
  grep -q 'archive-hash-mismatch-proof' "$ci_yml" ||
    fail "$ci_yml does not reference archive-hash-mismatch-proof (the negative-path CI step is missing)"
  grep -qi 'hash mismatch' "$ci_yml" ||
    fail "$ci_yml's negative step does not assert on 'hash mismatch' in the failed build's output"
fi

# The purity guard's <nix/fetchurl.nix> carve-out (021) must still hold —
# this file is exactly what motivated it, so a regression here means both
# tests should be looked at together.
purity_test="tests/unit/021-flake-purity.sh"
if [ -x "$purity_test" ]; then
  "$purity_test" || fail "$purity_test no longer passes with nix/archive.nix in the tree"
else
  fail "$purity_test is missing or not executable"
fi

# Mirror the spirit of 021 directly against nix/archive.nix: no nixpkgs
# package/fetcher references at all, beyond the already-permitted
# <nix/fetchurl.nix>/builtins.fetchurl spellings that 021 itself carves
# out (checked above via running 021 in full).
if grep -nE 'pkgs\.[a-zA-Z]|mkDerivation|buildInputs|fetchFromGitHub' "$archive_nix" >/dev/null 2>&1; then
  fail "$archive_nix references a forbidden nixpkgs-package-set pattern"
fi

exit "$fails"
