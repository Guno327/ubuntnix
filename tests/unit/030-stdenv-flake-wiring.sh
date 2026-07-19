#!/usr/bin/env bash
# tests/unit/030-stdenv-flake-wiring.sh — Ubuntu-native stdenv bootstrap,
# static wiring checks (SPEC.md §4.1; issue #6, milestone M1).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so nothing here can actually evaluate or
# build the flake — that's CI-only (the "flake" job in
# .github/workflows/ci.yml, which builds `.#stdenv-proof` and asserts on
# its output). This test is a machine-checked textual guard instead: it
# confirms nix/stdenv.nix exists, declares the pinned trust-root URL and
# well-formed hash pins, is actually imported by flake.nix, is wired to a
# real per-system package, and that the purity guard it deliberately
# carves an exception into (021) still holds.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

stdenv_nix="nix/stdenv.nix"

[ -f "$stdenv_nix" ] || {
  echo "FAIL: $stdenv_nix does not exist" >&2
  exit 1
}

# The pinned trust root must be Canonical's own cdimage host, over https.
grep -qE 'url = "https://cdimage\.ubuntu\.com/ubuntu-base/' "$stdenv_nix" ||
  fail "$stdenv_nix does not declare a pinned https://cdimage.ubuntu.com ubuntu-base URL"

# Every literal sha256 pin (the audited flat-file hash, and the
# recursive-NAR unpacked-tree hash consumed as the `unpacked` fixed-output
# derivation's `outputHash` — which may legitimately still be the
# documented 64-zero placeholder awaiting a real first CI run, per the
# file's own "PM ACTION REQUIRED" comment) must be well-formed: exactly 64
# lowercase hex characters. Malformed forms (base32, SRI, wrong length,
# stray whitespace) would silently fail Nix's own hash parsing later, so
# catch that here without needing `nix` to try.
mapfile -t pins < <(grep -oE '\b(sha256|unpackedSha256) = "[^"]*"' "$stdenv_nix")

[ "${#pins[@]}" -ge 2 ] ||
  fail "$stdenv_nix should declare at least two sha256-shaped pins (flat-file + unpacked-NAR), found ${#pins[@]}"

for pin in "${pins[@]}"; do
  hash="${pin#*\"}"
  hash="${hash%\"}"
  if [[ ! "$hash" =~ ^[0-9a-f]{64}$ ]]; then
    fail "$stdenv_nix: pin '$pin' is not 64 lowercase hex characters (got '$hash', length ${#hash})"
  fi
done

# The documented placeholder must still be clearly flagged as such in the
# file (so it can't silently linger unnoticed after the PM fills in the
# real hash and drops the marker comments — this only checks it's present
# *now*; it's fine for this line to disappear once the pin goes real, at
# which point this grep simply stops matching and the check is skipped).
if grep -q 'unpackedSha256 = "0000000000000000000000000000000000000000000000000000000000000000"' "$stdenv_nix"; then
  grep -q "PM ACTION REQUIRED" "$stdenv_nix" ||
    fail "$stdenv_nix has an unfilled unpackedSha256 placeholder but no PM ACTION REQUIRED note explaining it"
fi

# flake.nix must actually import the dendritic module (SPEC.md §2 G8).
grep -q '\./nix/stdenv\.nix' flake.nix ||
  fail "flake.nix does not import ./nix/stdenv.nix"

# The builder abstraction and its flake.lib exposure (issue #6 task item
# 2) must be present under recognizable names.
grep -q 'runInUbuntuBase' "$stdenv_nix" ||
  fail "$stdenv_nix does not define runInUbuntuBase"
grep -q 'flake.lib.stdenv' "$stdenv_nix" ||
  fail "$stdenv_nix does not expose flake.lib.stdenv"

# perSystem wiring for the proof derivation (issue #6 task item 3): one
# system, minimally, and a packages.stdenv-proof output built from it.
grep -q 'systems = \[ "x86_64-linux" \]' "$stdenv_nix" ||
  fail "$stdenv_nix does not declare systems = [ \"x86_64-linux\" ]"
grep -q 'packages.stdenv-proof' "$stdenv_nix" ||
  fail "$stdenv_nix does not declare packages.stdenv-proof"

# `unpacked`'s bootstrap escape hatch (builtins.fetchTarball turned out to
# be structurally unusable against ubuntu-base's bare, non-single-top-dir
# tarball shape — confirmed against real CI, GitHub Actions run
# 29705143141): a host-`/bin/sh`-and-`tar`-driven fixed-output derivation,
# `__noChroot` to reach the host tools, `outputHash`/`outputHashMode`/
# `outputHashAlgo` to keep it pinned exactly like any other fetch. All four
# must be present together, or the derivation is either unbuildable
# (missing __noChroot) or unpinned (missing the outputHash* trio).
grep -q '__noChroot = true;' "$stdenv_nix" ||
  fail "$stdenv_nix does not set __noChroot = true on the unpacked derivation"
grep -q 'outputHashMode = "recursive";' "$stdenv_nix" ||
  fail "$stdenv_nix does not set outputHashMode = \"recursive\" on the unpacked derivation"
grep -q 'outputHashAlgo = "sha256";' "$stdenv_nix" ||
  fail "$stdenv_nix does not set outputHashAlgo = \"sha256\" on the unpacked derivation"
grep -q 'outputHash = unpackedSha256;' "$stdenv_nix" ||
  fail "$stdenv_nix does not wire outputHash to the unpackedSha256 pin"

# CI must actually build and assert on that proof (issue #6 task item 4) —
# checked here too so the flake-side wiring and the CI-side wiring can't
# silently drift apart, mirroring how tests/unit/020 keeps nix/ubx.nix and
# bin/ubx in lockstep.
ci_yml=".github/workflows/ci.yml"
[ -f "$ci_yml" ] || fail "$ci_yml does not exist"
grep -q 'stdenv-proof' "$ci_yml" 2>/dev/null ||
  fail "$ci_yml does not reference stdenv-proof (the CI build/assert step is missing)"

# The __noChroot derivation above needs relaxed sandboxing to build at all
# (SPEC.md §4.1 bootstrap note); CI's build step must request it, or the
# first real CI run fails on a sandbox-refusal, not the expected hash
# mismatch.
grep -qE 'nix .*--option sandbox relaxed.* build .#stdenv-proof' "$ci_yml" 2>/dev/null ||
  fail "$ci_yml's stdenv-proof build step is missing --option sandbox relaxed"

# The purity guard's `builtins.fetchurl` carve-out (021) must still hold —
# this file is exactly what motivated it, so a regression here means both
# tests should be looked at together.
purity_test="tests/unit/021-flake-purity.sh"
if [ -x "$purity_test" ]; then
  "$purity_test" || fail "$purity_test no longer passes with nix/stdenv.nix in the tree"
else
  fail "$purity_test is missing or not executable"
fi

exit "$fails"
