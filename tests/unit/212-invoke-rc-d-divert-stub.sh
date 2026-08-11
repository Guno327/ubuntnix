#!/usr/bin/env bash
# tests/unit/212-invoke-rc-d-divert-stub.sh — regression guard for the
# in-chroot `invoke-rc.d` divert stub (GitHub issue #118 follow-up).
#
# The `server-parity`/`desktop-parity` e2e image builds kept failing at
# `dpkg --configure -a` byte-identically -- same
# "invoke-rc.d: unknown initscript, /etc/init.d/rsyslog not found" /
# "invoke-rc.d: could not determine current runlevel" text, same
# "Errors were encountered while processing: ubuntu-standard" -- after
# 211's policy-rc.d shim landed. Reading init-system-helpers' actual
# /usr/sbin/invoke-rc.d source shows why that shim could never have fixed
# this: the "unknown initscript ... not found" message comes from an
# unconditional `test ! -f "${INITDPREFIX}${INITSCRIPTID}"` existence check
# at the very top of the script, run long before policy-rc.d is ever
# consulted -- there is nothing left for a policy-rc.d exit code to
# short-circuit. The canonical, comprehensive fix used by debootstrap and
# live-build for exactly this class of chroot-compose problem is to divert
# invoke-rc.d itself (via `dpkg-divert --rename`) to an unconditional no-op
# for the duration of the compose, covering every maintainer script's
# invoke-rc.d call regardless of whether that script's own policy-rc.d
# handling is complete -- then un-divert it again before packing, so a real
# booted system runs the genuine init-system-helpers invoke-rc.d.
#
# This is a static textual guard, mirroring tests/unit/211's own
# policy-rc.d regression check just above it in nix/compose.nix: this dev
# harness has no `nix` binary to actually evaluate/build the flake (that is
# CI-only), so it asserts on the composed in-chroot script's SOURCE TEXT
# instead -- that the stub is diverted into place before dpkg does any
# unpack/configure work, exits 0 unconditionally, is executable, and is
# un-diverted again before the rootfs is packed so neither the diversion
# nor the stub leaks into $out (R1 build determinism / no build-time
# artifacts in the shipped image).
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

compose_nix="nix/compose.nix"

[ -f "$compose_nix" ] || {
  echo "FAIL: $compose_nix does not exist" >&2
  exit 1
}

# The stub must actually be diverted into place: `dpkg-divert --rename
# --add` on /usr/sbin/invoke-rc.d, then a replacement file written there
# that exits 0 unconditionally, chmod'd executable.
grep -qE 'dpkg-divert --local --rename' "$compose_nix" ||
  fail "$compose_nix does not dpkg-divert --local --rename anything"
grep -qE -- '--divert /usr/sbin/invoke-rc\.d\.ubx-real --add /usr/sbin/invoke-rc\.d' "$compose_nix" ||
  fail "$compose_nix does not dpkg-divert --add /usr/sbin/invoke-rc.d into place"
grep -qE "printf '#!/bin/sh\\\\nexit 0\\\\n' ?>/usr/sbin/invoke-rc\\.d" "$compose_nix" ||
  fail "$compose_nix does not write an invoke-rc.d stub that exits 0"
grep -qE 'chmod 0755 /usr/sbin/invoke-rc\.d' "$compose_nix" ||
  fail "$compose_nix does not chmod the invoke-rc.d stub executable"

# The diversion must be undone (not just the stub file deleted) before the
# rootfs is packed, or the real binary would never come back.
grep -qE -- '--divert /usr/sbin/invoke-rc\.d\.ubx-real --remove /usr/sbin/invoke-rc\.d' "$compose_nix" ||
  fail "$compose_nix does not dpkg-divert --remove /usr/sbin/invoke-rc.d to restore the real binary"

# Ordering: the stub must be diverted in BEFORE dpkg does any unpack/
# configure work, and removed/un-diverted again AFTER dpkg --configure -a
# but before the rootfs is packed (i.e. before the /.ubx-compose staging
# cleanup), so it never ships in the final image.
divert_add_line="$(grep -n -- '--add /usr/sbin/invoke-rc.d' "$compose_nix" | head -n1 | cut -d: -f1)"
stub_write_line="$(grep -n '>/usr/sbin/invoke-rc.d$' "$compose_nix" | head -n1 | cut -d: -f1)"
unpack_line="$(grep -n 'dpkg --unpack every declared package' "$compose_nix" | head -n1 | cut -d: -f1)"
configure_line="$(grep -n '^\s*dpkg --configure -a\s*$' "$compose_nix" | head -n1 | cut -d: -f1)"
stub_remove_line="$(grep -n 'rm -f /usr/sbin/invoke-rc.d$' "$compose_nix" | head -n1 | cut -d: -f1)"
divert_remove_line="$(grep -n -- '--remove /usr/sbin/invoke-rc.d' "$compose_nix" | head -n1 | cut -d: -f1)"
compose_cleanup_line="$(grep -n 'rm -rf /\.ubx-compose$' "$compose_nix" | head -n1 | cut -d: -f1)"

[ -n "$divert_add_line" ] || fail "$compose_nix: could not locate the invoke-rc.d dpkg-divert --add line"
[ -n "$stub_write_line" ] || fail "$compose_nix: could not locate the invoke-rc.d stub-write line"
[ -n "$unpack_line" ] || fail "$compose_nix: could not locate the dpkg --unpack comment marker"
[ -n "$configure_line" ] || fail "$compose_nix: could not locate the dpkg --configure -a invocation"
[ -n "$stub_remove_line" ] || fail "$compose_nix: invoke-rc.d stub is never removed (would leak into \$out)"
[ -n "$divert_remove_line" ] || fail "$compose_nix: invoke-rc.d diversion is never removed (real binary would never come back)"
[ -n "$compose_cleanup_line" ] || fail "$compose_nix: could not locate the /.ubx-compose staging cleanup"

if [ -n "$divert_add_line" ] && [ -n "$unpack_line" ]; then
  [ "$divert_add_line" -lt "$unpack_line" ] ||
    fail "$compose_nix diverts invoke-rc.d AFTER dpkg --unpack begins (must be staged first, before ANY maintainer script can run)"
fi
if [ -n "$stub_write_line" ] && [ -n "$configure_line" ]; then
  [ "$stub_write_line" -lt "$configure_line" ] ||
    fail "$compose_nix writes the invoke-rc.d stub AFTER dpkg --configure -a (too late)"
fi
if [ -n "$configure_line" ] && [ -n "$stub_remove_line" ]; then
  [ "$configure_line" -lt "$stub_remove_line" ] ||
    fail "$compose_nix removes the invoke-rc.d stub BEFORE dpkg --configure -a runs (maintainer scripts would fail to be suppressed)"
fi
if [ -n "$stub_remove_line" ] && [ -n "$divert_remove_line" ]; then
  [ "$stub_remove_line" -le "$divert_remove_line" ] ||
    fail "$compose_nix undoes the dpkg-divert BEFORE deleting the stub file"
fi
if [ -n "$divert_remove_line" ] && [ -n "$compose_cleanup_line" ]; then
  [ "$divert_remove_line" -le "$compose_cleanup_line" ] ||
    fail "$compose_nix un-diverts invoke-rc.d AFTER the /.ubx-compose staging cleanup, not alongside it"
fi

exit "$fails"
