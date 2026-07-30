#!/usr/bin/env bash
# tests/unit/181-networking-netplan-render.sh — nix/networking.nix
# rendering-shape checks: netplan YAML (dhcp/static/wifi cases),
# /etc/hostname, /etc/hosts, and the Wi-Fi PSK rendered-config escape
# (SPEC.md §6, §8.1; GitHub issue #95).
#
# Same caveat as tests/unit/180-networking-flake-wiring.sh: this harness
# has no `nix` binary, so the actual netplan YAML text can only be proven
# correct by CI's own "flake" job building `.#networking-proof` (which
# forces validate/render against `exampleNetworking` at eval time -- see
# nix/networking.nix's own header). What CAN be checked here, statically,
# is that the render functions actually build each upstream-schema stanza
# this issue's acceptance criteria calls out, and that the Wi-Fi PSK
# escape never has a path to a real secret value.
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

# -- netplan v2 document shape ------------------------------------------
grep -q '"network:"' "$networking_nix" ||
  fail "$networking_nix does not render a top-level 'network:' key"
grep -q 'version: 2' "$networking_nix" ||
  fail "$networking_nix does not render netplan schema 'version: 2'"

# -- dhcp case: dhcp4/dhcp6 booleans rendered for both ethernets and
# wifis (shared ipEntryLines helper) --------------------------------------
grep -q '"dhcp4"' "$networking_nix" ||
  fail "$networking_nix does not render a dhcp4 key"
grep -q '"dhcp6"' "$networking_nix" ||
  fail "$networking_nix does not render a dhcp6 key"
grep -q 'ethernets' "$networking_nix" ||
  fail "$networking_nix does not render an 'ethernets:' stanza"
grep -q 'wifis' "$networking_nix" ||
  fail "$networking_nix does not render a 'wifis:' stanza"

# -- static case: addresses / routes (to: default / via:) / nameservers --
grep -q 'addresses:' "$networking_nix" ||
  fail "$networking_nix does not render an 'addresses:' key for static addressing"
grep -q 'routes:' "$networking_nix" ||
  fail "$networking_nix does not render a 'routes:' key for the gateway"
grep -q 'to: default' "$networking_nix" ||
  fail "$networking_nix does not render 'to: default' -- upstream netplan's non-deprecated gateway form"
grep -qE 'via: \$\{.*gateway' "$networking_nix" ||
  fail "$networking_nix does not render 'via: \${...gateway}'"
if grep -nE '"gateway4:|gateway4:\s*\$' "$networking_nix" > /dev/null 2>&1; then
  fail "$networking_nix uses the deprecated gateway4/gateway6 netplan keys instead of routes:"
fi
grep -q 'nameservers:' "$networking_nix" ||
  fail "$networking_nix does not render a 'nameservers:' key"

# -- wifi case: access-points / ssid mapping key --------------------------
grep -q 'access-points:' "$networking_nix" ||
  fail "$networking_nix does not render an 'access-points:' key"
grep -q 'escapeYamlDq w.ssid' "$networking_nix" ||
  fail "$networking_nix does not render the SSID as the access-points mapping key"

# -- Wi-Fi PSK: rendered-config escape (SPEC.md §8.1) ---------------------
# The password line must come from a NAME-derived placeholder, never a
# literal secret value; the placeholder shape itself must be present and
# distinctive so activation tooling can find-and-replace it later.
grep -q 'pskPlaceholder' "$networking_nix" ||
  fail "$networking_nix does not define a pskPlaceholder function"
grep -q '@@UBUNTNIX_SECRET:' "$networking_nix" ||
  fail "$networking_nix does not render the @@UBUNTNIX_SECRET:<name>@@ placeholder token"
grep -qE 'password: \$\{escapeYamlDq \(pskPlaceholder' "$networking_nix" ||
  fail "$networking_nix's password: line is not built from pskPlaceholder"

# pskSecret must be typed as a bare secret-name string (nullOr
# strMatching), never lib.types.path or anything that could carry real
# secret material -- mirrors nix/pro.nix's own tokenSecret invariant.
grep -qE 'pskSecret = lib\.mkOption' "$networking_nix" ||
  fail "$networking_nix does not declare pskSecret as a real option"
awk '/pskSecret = lib\.mkOption/,/};/' "$networking_nix" | grep -qE 'type = lib\.types\.nullOr \(lib\.types\.strMatching secretNameRe\)' ||
  fail "$networking_nix's pskSecret option is not typed as nullOr (strMatching secretNameRe) -- must be a bare secret NAME, never a path/value type"

# Defense in depth: no plaintext-looking secret material field (a raw
# "psk =" / "password =" assignment distinct from the placeholder
# machinery above) should ever appear.
if grep -nE '(psk|password)\s*=\s*"[^@]' "$networking_nix" | grep -vE 'password:|description|# ' > /dev/null 2>&1; then
  fail "$networking_nix appears to assign a literal password/psk value outside the placeholder machinery"
fi

# -- hostname / hosts -------------------------------------------------------
grep -q 'renderHostnameContent' "$networking_nix" ||
  fail "$networking_nix does not define renderHostnameContent"
grep -q '"hostname".text' "$networking_nix" ||
  fail "$networking_nix does not wire hostname into the etc entries as \"hostname\".text"
grep -q '127.0.0.1 localhost' "$networking_nix" ||
  fail "$networking_nix does not render the standard 127.0.0.1 localhost /etc/hosts line"
grep -q '127.0.1.1' "$networking_nix" ||
  fail "$networking_nix does not render the standard 127.0.1.1 <hostname> /etc/hosts line"
grep -q '"hosts".text' "$networking_nix" ||
  fail "$networking_nix does not wire hosts into the etc entries as \"hosts\".text"

# -- netplan file path + permission (root-only, matches stock Ubuntu) -----
grep -q 'netplan/01-ubuntnix.yaml' "$networking_nix" ||
  fail "$networking_nix does not emit /etc/netplan/01-ubuntnix.yaml"
awk '/"netplan\/01-ubuntnix\.yaml" = \{/,/};/' "$networking_nix" | grep -q '"0600"' ||
  fail "$networking_nix does not render the netplan file with mode \"0600\""

exit "$fails"
