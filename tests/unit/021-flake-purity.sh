#!/usr/bin/env bash
# tests/unit/021-flake-purity.sh — static purity guard.
#
# SPEC.md §1.3 / §3: the Nix ecosystem may contribute pure source
# libraries ONLY. No nixpkgs package, binary, builder, or formatter may
# ever be referenced by this flake. We have no `nix` binary in this
# harness to actually evaluate/build against forbidden nixpkgs attributes
# (that's CI-only — see the "flake" CI job), so this is a machine-checked
# textual guard instead: grep flake.nix and nix/*.nix for the telltale
# signs of the rule being crossed.
set -u

cd "$UBX_REPO_ROOT" || exit 1

shopt -s nullglob
files=(flake.nix nix/*.nix)
shopt -u nullglob

[ "${#files[@]}" -gt 0 ] || {
  echo "FAIL: no flake.nix / nix/*.nix files found to check" >&2
  exit 1
}

fails=0

check() {
  # check DESCRIPTION PATTERN(extended-regex)
  local desc="$1" pattern="$2" f
  for f in "${files[@]}"; do
    if grep -nE "$pattern" "$f" >/dev/null 2>&1; then
      echo "FAIL: $f references forbidden pattern ($desc) — a no-nixpkgs-binaries violation (SPEC.md §1.3)" >&2
      grep -nE "$pattern" "$f" >&2
      fails=$((fails + 1))
    fi
  done
}

check "nixpkgs.legacyPackages" 'nixpkgs\.legacyPackages'
# `\bpkgs\.` rather than a bare "pkgs." substring: the latter would
# false-positive on every legitimate `nixpkgs.lib` reference (the "pkgs."
# tail of "nixpkgs.lib" isn't preceded by a word boundary, since "x" and
# "p" are both word characters). This still catches the real violation
# shape: a standalone `pkgs.<attr>` access.
check "pkgs.<attr> access" '\bpkgs\.'
check "buildInputs" 'buildInputs'
check "mkDerivation" 'mkDerivation'
check "fetchurl" 'fetchurl'
check "fetchFromGitHub" 'fetchFromGitHub'

exit "$fails"
