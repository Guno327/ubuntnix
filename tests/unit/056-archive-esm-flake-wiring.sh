#!/usr/bin/env bash
# tests/unit/056-archive-esm-flake-wiring.sh — esm-tier fetcher, static
# wiring checks (SPEC.md §4.4 second bullet, §8.2; GitHub issue #81,
# milestone M4).
#
# Mirrors tests/unit/041-archive-flake-wiring.sh's relationship to the
# public tier: this harness has no `nix` binary, so nothing here can
# actually evaluate/build the flake (CI-only — the "flake" job in
# .github/workflows/ci.yml, which builds `.#archive-esm-fetch-proof`).
# This is a machine-checked textual guard confirming nix/archive.nix wires
# up fetchEsmDeb/esmDebs, reads the Pro token ONLY via impureEnvVars (never
# embeds a literal secret), never regresses the public tier's fetchDeb/
# debs, and that the flake-purity guard (021) still holds with this file
# in the tree.
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

# -- esm fetch function + attrset must exist, alongside the UNCHANGED
# public-tier ones (this issue's explicit "keep the existing public-pocket
# snapshot tier UNCHANGED" constraint).
for name in fetchDeb debs fetchEsmDeb esmDebs; do
  grep -q "$name" "$archive_nix" ||
    fail "$archive_nix does not define '$name'"
done

# -- the Pro token env var name must be a single named constant, referenced
# by BOTH the impureEnvVars declaration and the shell script's own literal
# check (see nix/archive.nix's own NOTE on why the shell literal is
# hardcoded rather than double-interpolated).
grep -q 'esmProTokenVar = "UBUNTNIX_CI_PRO_TOKEN"' "$archive_nix" ||
  fail "$archive_nix does not define esmProTokenVar = \"UBUNTNIX_CI_PRO_TOKEN\""
grep -q 'impureEnvVars = \[ esmProTokenVar \]' "$archive_nix" ||
  fail "$archive_nix's fetchEsmDeb does not pass the token through impureEnvVars"
grep -q 'UBUNTNIX_CI_PRO_TOKEN' "$archive_nix" ||
  fail "$archive_nix's fetchEsmDeb script does not reference UBUNTNIX_CI_PRO_TOKEN"

# -- bin/ubx-resolve-esm must read the Pro token from the IDENTICAL
# variable name, or the CI-side fetch and the ubx-resolve-esm-side fetch
# would silently disagree about which secret to consume.
resolve_esm="bin/ubx-resolve-esm"
[ -f "$resolve_esm" ] || fail "$resolve_esm does not exist"
if [ -f "$resolve_esm" ]; then
  grep -q 'PRO_TOKEN_VAR="UBUNTNIX_CI_PRO_TOKEN"' "$resolve_esm" ||
    fail "$resolve_esm does not read the token from UBUNTNIX_CI_PRO_TOKEN (must match nix/archive.nix's esmProTokenVar)"
fi

# -- fixed-output verification: the esm fetch must be hash-pinned via
# outputHash, exactly like fetchDeb's own fixed-output fetch.
grep -q 'outputHash = entry.sha256' "$archive_nix" ||
  fail "$archive_nix's fetchEsmDeb does not pin outputHash = entry.sha256"

# -- never a literal, non-env-sourced secret value anywhere in the file:
# a real Ubuntu Pro token has a documented shape this project doesn't
# fabricate one of, but the more directly-checkable invariant is that the
# ONLY appearance of a plausible auth string is the variable reference,
# never a hardcoded "--user <literal>:bearer" with anything other than the
# shell variable.
grep -nE -- '--user "[^$][^"]*:bearer"' "$archive_nix" >/dev/null 2>&1 &&
  fail "$archive_nix appears to hardcode a literal (non-variable) credential in a --user argument"

# -- perSystem wiring for the esm proof package, mirroring the public
# tier's archive-fetch-proof/archive-hash-mismatch-proof pairing.
grep -q 'packages.archive-esm-fetch-proof' "$archive_nix" ||
  fail "$archive_nix does not declare packages.archive-esm-fetch-proof"
grep -q 'ubuntnix-archive-esm-fetch-proof-v1' "$archive_nix" ||
  fail "$archive_nix's archive-esm-fetch-proof does not emit its MARKER/SKIP line"

# -- CI must reference the esm proof and the required secret name.
ci_yml=".github/workflows/ci.yml"
[ -f "$ci_yml" ] || fail "$ci_yml does not exist"
if [ -f "$ci_yml" ]; then
  grep -q 'archive-esm-fetch-proof' "$ci_yml" ||
    fail "$ci_yml does not reference archive-esm-fetch-proof"
  grep -q 'UBUNTNIX_CI_PRO_TOKEN' "$ci_yml" ||
    fail "$ci_yml does not reference the UBUNTNIX_CI_PRO_TOKEN secret"
  grep -qi 'secrets\.UBUNTNIX_CI_PRO_TOKEN' "$ci_yml" ||
    fail "$ci_yml does not source the token from a GitHub Actions secret (secrets.UBUNTNIX_CI_PRO_TOKEN)"
fi

# -- the public-cache-manifest exclusion tool must exist and must never
# even read the esm key of its input (structural guard: this greps for
# the absence of a specific pattern, not its presence).
manifest_tool="bin/ubx-archive-public-manifest"
[ -x "$manifest_tool" ] || fail "$manifest_tool does not exist or is not executable"
if [ -f "$manifest_tool" ]; then
  grep -q '"manifest"\[.esm.\]\|manifest\["esm"\]' "$manifest_tool" >/dev/null 2>&1 &&
    fail "$manifest_tool appears to write an 'esm' key into its own manifest output"
fi

# -- the purity guard must still hold with these new files in the tree.
purity_test="tests/unit/021-flake-purity.sh"
if [ -x "$purity_test" ]; then
  "$purity_test" || fail "$purity_test no longer passes with the esm-tier wiring in the tree"
else
  fail "$purity_test is missing or not executable"
fi

# -- 021's own forbidden-pattern spirit, directly against nix/archive.nix:
# builtins.derivation (used by fetchEsmDeb, exactly like nix/stdenv.nix's
# `unpacked`) is a Nix language primitive, not a nixpkgs pattern, so it is
# NOT checked for here -- only the genuinely forbidden nixpkgs shapes are.
if grep -nE 'pkgs\.[a-zA-Z]|mkDerivation|buildInputs|fetchFromGitHub' "$archive_nix" >/dev/null 2>&1; then
  fail "$archive_nix references a forbidden nixpkgs-package-set pattern"
fi

exit "$fails"
