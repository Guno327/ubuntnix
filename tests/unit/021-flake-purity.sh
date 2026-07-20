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
check "fetchFromGitHub" 'fetchFromGitHub'

# `fetchurl` gets a narrower, deliberate carve-out rather than the blanket
# `check` above (SPEC.md §4.1 / issue #6): nix/stdenv.nix legitimately calls
# `builtins.fetchurl` — a Nix LANGUAGE PRIMITIVE, always built into Nix
# itself, not a nixpkgs fetcher — to pin Canonical's ubuntu-base tarball,
# the project's one deliberate trust root besides Nix (SPEC.md §1.3/§4.1).
#
# A SECOND, equally narrow carve-out (SPEC.md §4.4 / issue #7):
# nix/archive.nix legitimately calls `import <nix/fetchurl.nix>` — the
# plain-Nix-expression sibling of the same `builtins.fetchurl` primitive,
# shipped INSIDE NIX'S OWN source tree (`src/libexpr/fetchurl.nix`,
# historically `corepkgs/fetchurl.nix`) and resolved via Nix's built-in
# `<nix/...>` search path, which points at Nix's own data directory — NOT
# `NIX_PATH`, not a channel, not nixpkgs. It's used instead of
# `builtins.fetchurl` there specifically because it accepts an explicit
# `name` argument (needed to sanitize deb filenames for the Nix store name
# grammar), which the C++ `builtins.fetchurl` primitive does not expose.
#
# Only these two exact spellings are allowed; any OTHER shape (bare
# `fetchurl`, `pkgs.fetchurl`, an aliased/`with`-imported `fetchurl`, a
# nixpkgs-channel `<nixpkgs/...>`-style path, ...) still trips this guard,
# since those shapes indicate a nixpkgs fetcher rather than one of Nix's
# own two built-in fetchurl forms.
check_fetchurl() {
  local f matches
  for f in "${files[@]}"; do
    matches="$(grep -nE 'fetchurl' "$f" 2>/dev/null | grep -vE 'builtins\.fetchurl|<nix/fetchurl\.nix>')"
    if [ -n "$matches" ]; then
      echo "FAIL: $f references forbidden pattern (fetchurl, non-builtin spelling) — a no-nixpkgs-binaries violation (SPEC.md §1.3)" >&2
      echo "$matches" >&2
      fails=$((fails + 1))
    fi
  done
}
check_fetchurl

exit "$fails"
