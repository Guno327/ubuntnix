#!/usr/bin/env bash
# tests/unit/231-nix-lib-purity.sh — nix/lib.nix's own metadata + purity
# guard (SPEC.md §2 G8 "dendritic layout, one file per feature"; SPEC.md
# §1.3 "the Nix ecosystem may contribute pure source libraries ONLY";
# GitHub issue #157, "test coverage for destructive executors" — nix/
# lib.nix had zero test coverage before this file).
#
# This harness has NO `nix` binary (tests/unit/021-flake-purity.sh's own
# documented limitation, repeated here rather than re-derived), so exactly
# like that file, this is a machine-checked TEXTUAL guard, not a real Nix
# evaluation: it greps nix/lib.nix's own source for
#   (a) `config.flake.lib.meta.name` being the literal string "ubuntnix",
#   (b) `config.flake.lib.meta.version` looking like a real SemVer core
#       triple (MAJOR.MINOR.PATCH), and
#   (c) nix/lib.nix:1-7's own header promise held: "this file must never
#       gain a reference to a package, a builder, or a fetcher from
#       nixpkgs" — the banned patterns below are lifted DIRECTLY from that
#       sentence's own three nouns (package / builder / fetcher), not
#       guessed. Unlike tests/unit/021's project-wide sweep, nix/lib.nix's
#       own header grants NO carve-out (no `builtins.fetchurl`, no
#       `<nix/fetchurl.nix>` — those are nix/stdenv.nix's and
#       nix/archive.nix's own documented exceptions, not this file's), so
#       every fetcher spelling is banned here outright.
set -u

cd "$UBX_REPO_ROOT" || exit 1

lib_file="nix/lib.nix"
[ -f "$lib_file" ] || { echo "FAIL: $lib_file does not exist" >&2; exit 1; }

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

# =====================================================================
# 1) meta.name is exactly "ubuntnix".
# =====================================================================
if ! grep -nE 'name = "ubuntnix";' "$lib_file" > /dev/null 2>&1; then
  fail "$lib_file should declare meta.name = \"ubuntnix\"; (grep found no such line)"
fi

# =====================================================================
# 2) the declared version matches a SemVer core triple (MAJOR.MINOR.PATCH)
#    — nix/lib.nix's own `isSemver` helper's contract (splitString "."
#    yields exactly 3 parts), checked here independently of that helper
#    (this test must fail if the DECLARED version string itself regresses,
#    not just if isSemver's own logic breaks).
# =====================================================================
version_line="$(grep -nE '^\s*version = "[^"]*";' "$lib_file" | head -1)"
if [ -z "$version_line" ]; then
  fail "$lib_file should declare a version = \"...\"; line (grep found none)"
else
  version_value="$(printf '%s\n' "$version_line" | sed -E 's/^[0-9]+:\s*version = "([^"]*)";.*/\1/')"
  case "$version_value" in
    [0-9]*.[0-9]*.[0-9]*)
      # Further validate each of the 3 dot-separated components is
      # ALL-digits (a bare glob match above also accepts e.g. "0.0.0a" or
      # "0.x.0" since '*' is greedy and unanchored within each segment).
      if ! printf '%s\n' "$version_value" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        fail "$lib_file's declared version \"$version_value\" is not a strict MAJOR.MINOR.PATCH SemVer triple"
      fi
      ;;
    *)
      fail "$lib_file's declared version \"$version_value\" does not look like a SemVer triple (MAJOR.MINOR.PATCH)"
      ;;
  esac
fi

# =====================================================================
# 3) purity: no package / builder / fetcher reference from nixpkgs
#    (nix/lib.nix's own header, lines 5-7). Patterns mirror tests/unit/
#    021-flake-purity.sh's own project-wide set, minus that file's two
#    documented builtins.fetchurl / <nix/fetchurl.nix> carve-outs, which
#    belong to OTHER files (nix/stdenv.nix, nix/archive.nix), not this one.
# =====================================================================
check_banned() {
  local desc="$1" pattern="$2"
  if grep -nE "$pattern" "$lib_file" > /dev/null 2>&1; then
    fail "$lib_file references forbidden pattern ($desc) — violates its own header's \"never gain a reference to a package, a builder, or a fetcher from nixpkgs\""
    grep -nE "$pattern" "$lib_file" >&2
  fi
}
check_banned "nixpkgs.legacyPackages (package set access)" 'nixpkgs\.legacyPackages'
# `\bpkgs\.` rather than a bare substring match — see tests/unit/021's own
# comment: this avoids false-positiving on the legitimate `nixpkgs.lib`
# reference this file (nix/lib.nix:10) actually makes.
check_banned "pkgs.<attr> access (package set access)" '\bpkgs\.'
check_banned "buildInputs (builder)" 'buildInputs'
check_banned "mkDerivation (builder)" 'mkDerivation'
check_banned "fetchFromGitHub (fetcher)" 'fetchFromGitHub'
check_banned "fetchTarball (fetcher)" 'fetchTarball'
check_banned "fetchurl, any spelling (fetcher — no carve-out in this file)" 'fetchurl'
check_banned "fetchGit (fetcher)" 'fetchGit'

exit "$fails"
