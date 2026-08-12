#!/usr/bin/env bash
# tests/unit/218-networking-flake-wiring.sh — nix/networking.nix static
# wiring checks (SPEC.md §6 showcase modules, §8.1 rendered-config escape;
# GitHub issue #95).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so nothing here can actually evaluate or
# build the flake. This test is a machine-checked textual guard instead,
# mirroring tests/unit/175-crypttab-flake-wiring.sh's relationship to
# nix/crypttab.nix: it confirms nix/networking.nix exists, is imported by
# flake.nix, exposes flake.lib.networking, throws on a bad declaration, is
# wired to a real per-system proof package that composes onto
# nix/etc.nix's own render, and that the flake-wide purity guard (021)
# still holds with it in the tree. tests/unit/219-networking-netplan-
# render.sh covers the actual YAML/hosts/hostname content shape.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

networking_nix="nix/networking.nix"

[ -f "$networking_nix" ] || {
  echo "FAIL: $networking_nix does not exist" >&2
  exit 1
}

# flake.nix must actually import the dendritic module (SPEC.md §2 G8).
grep -q '\./nix/networking\.nix' flake.nix ||
  fail "flake.nix does not import ./nix/networking.nix"

# Must expose flake.lib.networking (same dendritic contribution pattern
# nix/pro.nix/nix/etc.nix/nix/crypttab.nix each use).
grep -q 'flake.lib.networking' "$networking_nix" ||
  fail "$networking_nix does not expose flake.lib.networking"

for fn in validate toEtcEntries render renderNetplanYAML renderHostsContent renderHostnameContent pskPlaceholder; do
  grep -q "$fn" "$networking_nix" || fail "$networking_nix does not define/expose '$fn'"
done

# validate must actually `throw` on a violation (a real eval-boundary
# enforcement, not just documentation) -- mirrors tests/unit/175's/170's/
# 161's/041's identical check.
grep -q 'throw' "$networking_nix" ||
  fail "$networking_nix has no throw -- validate must actually refuse a bad declaration"

# This module is a SHOWCASE that composes onto the ubuntnix.etc primitive
# (issue #95's own scope: "Emit ... through the existing ubuntnix.etc
# primitive"), not a parallel rendering mechanism -- confirm it actually
# calls into nix/etc.nix's own render rather than reimplementing it.
grep -qE 'config\.flake\.lib\.etc\.render' "$networking_nix" ||
  fail "$networking_nix does not compose onto config.flake.lib.etc.render"

# perSystem wiring for the fixture proof (mirrors nix/etc.nix's own
# etc-proof / nix/pro.nix's pro-manifest-proof).
grep -q 'packages.networking-proof' "$networking_nix" ||
  fail "$networking_nix does not declare packages.networking-proof"

# The example/proof fixture must cover all three showcase cases this
# issue's acceptance criteria name: dhcp, static, and wifi.
grep -q 'exampleNetworking' "$networking_nix" ||
  fail "$networking_nix does not define an exampleNetworking fixture"
grep -q 'dhcp4 = true' "$networking_nix" ||
  fail "$networking_nix's fixture does not appear to cover a dhcp4 case"
grep -q 'addresses = \[ "192.168.1.5/24" \]' "$networking_nix" ||
  fail "$networking_nix's fixture does not appear to cover a static-address case"
grep -q 'pskSecret = "wifiPsk"' "$networking_nix" ||
  fail "$networking_nix's fixture does not appear to cover a wifi/pskSecret case"

# The flake-wide purity guard must still hold with nix/networking.nix in
# the tree.
purity_test="tests/unit/021-flake-purity.sh"
if [ -x "$purity_test" ]; then
  "$purity_test" || fail "$purity_test no longer passes with nix/networking.nix in the tree"
else
  fail "$purity_test is missing or not executable"
fi

# Mirror the spirit of 021 directly against nix/networking.nix: no
# nixpkgs package/fetcher references at all (SPEC.md §3/§1.3 -- only
# nixpkgs.lib is allowed).
if grep -nE '\bpkgs\.|mkDerivation|buildInputs|fetchFromGitHub' "$networking_nix" > /dev/null 2>&1; then
  fail "$networking_nix references a forbidden nixpkgs-package-set pattern"
fi

exit "$fails"
