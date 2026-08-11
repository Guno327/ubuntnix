#!/usr/bin/env bash
# tests/unit/211-policy-rc-d-suppression.sh — regression guard for the
# in-chroot `policy-rc.d` service-start suppression (GitHub issue #118).
#
# The `server-parity`/`desktop-parity` e2e image builds started failing at
# `dpkg --configure -a` once the ubuntu-standard metapackage pulled in
# rsyslog: its postinst calls `invoke-rc.d`, which in a chroot has no PID 1
# init and no /etc/init.d SysV entry to query --
# "invoke-rc.d: unknown initscript, /etc/init.d/rsyslog not found" /
# "invoke-rc.d: could not determine current runlevel" -- and its non-zero
# exit aborts `dpkg --configure -a` under `set -eu`, cascading every
# not-yet-configured package into "Errors were encountered while
# processing". The canonical fix (debootstrap, live-build, every Debian/
# Ubuntu image builder) is a `/usr/sbin/policy-rc.d` shim that exits 101
# ("action forbidden by policy"), which invoke-rc.d(8) treats as "policy
# forbids starting services here" and reports as success rather than
# actually trying to start anything in an unbootable chroot.
#
# This is a static textual guard, mirroring tests/unit/060's own TMPDIR/
# issue-#118 regression check just above it in nix/compose.nix: this dev
# harness has no `nix` binary to actually evaluate/build the flake (that is
# CI-only), so it asserts on the composed in-chroot script's SOURCE TEXT
# instead -- that the shim is staged before dpkg does any unpack/configure
# work, exits 101, is executable, and is removed again before the rootfs is
# packed so it never leaks into $out (R1 build determinism / no build-time
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

# The shim must actually be staged: a policy-rc.d file written under
# /usr/sbin that exits 101, chmod'd executable.
grep -q '/usr/sbin/policy-rc.d' "$compose_nix" ||
  fail "$compose_nix does not reference /usr/sbin/policy-rc.d"
grep -qE "printf '#!/bin/sh\\\\nexit 101\\\\n' ?>/usr/sbin/policy-rc\\.d" "$compose_nix" ||
  fail "$compose_nix does not write a policy-rc.d shim that exits 101"
grep -qE 'chmod 0755 /usr/sbin/policy-rc\.d' "$compose_nix" ||
  fail "$compose_nix does not chmod the policy-rc.d shim executable"

# Ordering: the shim must be staged BEFORE dpkg does any unpack/configure
# work, and removed again AFTER dpkg --configure -a but before the rootfs
# is packed (i.e. before the /.ubx-compose staging cleanup), so it never
# ships in the final image.
stage_line="$(grep -n '/usr/sbin/policy-rc.d' "$compose_nix" | grep 'printf' | head -n1 | cut -d: -f1)"
unpack_line="$(grep -n 'dpkg --unpack every declared package' "$compose_nix" | head -n1 | cut -d: -f1)"
configure_line="$(grep -n '^\s*dpkg --configure -a\s*$' "$compose_nix" | head -n1 | cut -d: -f1)"
remove_line="$(grep -n 'rm -f /usr/sbin/policy-rc.d' "$compose_nix" | head -n1 | cut -d: -f1)"
compose_cleanup_line="$(grep -n 'rm -rf /\.ubx-compose$' "$compose_nix" | head -n1 | cut -d: -f1)"

[ -n "$stage_line" ] || fail "$compose_nix: could not locate the policy-rc.d staging line"
[ -n "$unpack_line" ] || fail "$compose_nix: could not locate the dpkg --unpack comment marker"
[ -n "$configure_line" ] || fail "$compose_nix: could not locate the dpkg --configure -a invocation"
[ -n "$remove_line" ] || fail "$compose_nix: policy-rc.d shim is never removed (would leak into \$out)"
[ -n "$compose_cleanup_line" ] || fail "$compose_nix: could not locate the /.ubx-compose staging cleanup"

if [ -n "$stage_line" ] && [ -n "$unpack_line" ]; then
  [ "$stage_line" -lt "$unpack_line" ] ||
    fail "$compose_nix stages policy-rc.d AFTER dpkg --unpack begins (must be staged first, before ANY maintainer script can run)"
fi
if [ -n "$stage_line" ] && [ -n "$configure_line" ]; then
  [ "$stage_line" -lt "$configure_line" ] ||
    fail "$compose_nix stages policy-rc.d AFTER dpkg --configure -a (too late)"
fi
if [ -n "$configure_line" ] && [ -n "$remove_line" ]; then
  [ "$configure_line" -lt "$remove_line" ] ||
    fail "$compose_nix removes policy-rc.d BEFORE dpkg --configure -a runs (services would fail to be suppressed)"
fi
if [ -n "$remove_line" ] && [ -n "$compose_cleanup_line" ]; then
  [ "$remove_line" -le "$compose_cleanup_line" ] ||
    fail "$compose_nix removes policy-rc.d AFTER the /.ubx-compose staging cleanup, not alongside it"
fi

exit "$fails"
