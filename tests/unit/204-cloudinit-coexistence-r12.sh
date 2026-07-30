#!/usr/bin/env bash
# tests/unit/204-cloudinit-coexistence-r12.sh — locks the cloud-init
# present-but-inert coexistence contract (SPEC.md §12 R12; GitHub issue
# #116): with `profiles.server` enabled, cloud-init ships disabled (the
# `/etc/cloud/cloud-init.disabled` marker) so it never emits its own
# `50-cloud-init.yaml` netplan config to fight ubuntnix's own authoritative
# `/etc/netplan/01-ubuntnix.yaml`.
#
# The mechanism this locks already exists (nix/profiles.nix's
# `cloudInitEtcEntries`/`cloudInitDisabledPath`/`renderDeclaration`) --
# this test is new, formalizing coverage only. It does not reimplement it.
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so — mirroring tests/unit/186-profiles-
# server-flake-wiring.sh's/tests/unit/187-profiles-server-seed-set.sh's own
# posture for this exact file — this is a machine-checked textual/
# structural guard against the real committed nix/profiles.nix and
# nix/networking.nix source, not a live `flake.lib.profiles.server` eval.
# It asserts on the actual declared render shape (the `etc` entry key,
# the `cloudInit.disabledPath` binding, and the distinct netplan key) —
# not just prose — so it cannot pass without the real code in place, and
# would fail if any of the three were renamed, removed, or ever collided.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

profiles_nix="nix/profiles.nix"
networking_nix="nix/networking.nix"

for f in "$profiles_nix" "$networking_nix"; do
  [ -f "$f" ] || {
    echo "FAIL: $f does not exist" >&2
    exit 1
  }
done

# -- (a) render output's `etc` includes the present-but-inert marker ------
#
# `cloudInitEtcEntries` must declare the marker under the etc-primitive's
# relative-path key convention (nix/etc.nix's header: "a RELATIVE path
# under /etc, no leading /etc or /"), and `renderDeclaration`'s enabled
# branch must actually build its `etc` list FROM `cloudInitEtcEntries`
# (not a parallel/unrelated etc list) so the marker really reaches
# `flake.lib.profiles.server`'s render output.
grep -qE '"cloud/cloud-init\.disabled"[[:space:]]*=' "$profiles_nix" ||
  fail "$profiles_nix does not declare the cloud/cloud-init.disabled etc entry key"

grep -qE 'renderEtcEntry[[:space:]]+path[[:space:]]+cloudInitEtcEntries' "$profiles_nix" ||
  fail "$profiles_nix's renderDeclaration does not build its etc list from cloudInitEtcEntries"
grep -qE 'builtins\.attrNames[[:space:]]+cloudInitEtcEntries' "$profiles_nix" ||
  fail "$profiles_nix does not iterate cloudInitEtcEntries's own keys when building the render etc list"

# -- (b) `cloudInit.disabledPath` equals the real, absolute marker path ---
grep -qE '^\s*cloudInitDisabledPath\s*=\s*"/etc/cloud/cloud-init\.disabled";' "$profiles_nix" ||
  fail "$profiles_nix does not bind cloudInitDisabledPath = \"/etc/cloud/cloud-init.disabled\";"

grep -qE 'cloudInit[[:space:]]*=[[:space:]]*\{[[:space:]]*disabledPath[[:space:]]*=[[:space:]]*cloudInitDisabledPath;[[:space:]]*\};' "$profiles_nix" ||
  fail "$profiles_nix's renderDeclaration does not expose cloudInit = { disabledPath = cloudInitDisabledPath; };"

# -- (c) marker path vs. ubuntnix netplan path: distinct, non-conflicting -
#
# Extract the two real path literals from source (not hand-copied) and
# compare them directly, then confirm nix/networking.nix's own netplan
# key is the etc-relative form ("netplan/01-ubuntnix.yaml") that combines
# with the marker's "/etc" root to the well-known absolute path the 050
# server-parity e2e (nix/profiles.nix's serverParityAssertScript) checks.
marker_path="$(grep -oE '"/etc/cloud/cloud-init\.disabled"' "$profiles_nix" | head -n1 | tr -d '"')"
[ -n "$marker_path" ] || fail "could not extract cloudInitDisabledPath literal from $profiles_nix"

grep -qE '"netplan/01-ubuntnix\.yaml"[[:space:]]*=' "$networking_nix" ||
  fail "$networking_nix does not declare the netplan/01-ubuntnix.yaml etc entry key"
netplan_abs="/etc/netplan/01-ubuntnix.yaml"

if [ -n "$marker_path" ] && [ "$marker_path" = "$netplan_abs" ]; then
  fail "cloud-init disabled marker path collides with ubuntnix's own netplan path ($marker_path)"
fi

# -- proof the 050 server-parity e2e actually asserts BOTH files at boot --
#
# Locks that the coexistence contract has a real runtime proof, not just
# an eval-time render: serverParityAssertScript must check the marker AND
# the ubuntnix netplan file exist (nix/profiles.nix ~lines 480-488).
grep -qE '\[ ! -f "\$\{cloudInitDisabledPath\}" \]' "$profiles_nix" ||
  fail "$profiles_nix's serverParityAssertScript does not check the cloud-init disabled marker at boot"
grep -qE '\[ ! -f /etc/netplan/01-ubuntnix\.yaml \]' "$profiles_nix" ||
  fail "$profiles_nix's serverParityAssertScript does not check /etc/netplan/01-ubuntnix.yaml at boot"

exit "$fails"
