#!/usr/bin/env bash
# tests/unit/063-compose-fakeroot-integration.sh — GitHub issue #48:
# fakeroot replaces the scan/restore/path-exclude interim + hand-rolled
# mksquashfs pseudo-file manifest bin/ubx-scan-deb-ownership (DELETED by
# this issue) and tests/unit/063-066 (the four files this file's number
# and its siblings replace) used to implement/guard.
#
# This dev harness has no `nix`, no `fakeroot`, and no `dpkg` binary (see
# nix/compose.nix's own "CI VERIFICATION NOTE" for this issue), so unlike
# the retired scan-script tests (which ran real dpkg-deb/tar against
# fixture .debs), the actual runtime guarantee this issue cares about --
# "a non-root-owned file, a setuid/setgid/sticky-bit file, and a
# 0600/0640-tight root:root file all survive composeRootfs+squashfsImage
# with their TRUE owner/mode intact" -- can only be proven by CI's real
# build (compose-image-proof and friends). What CAN be checked here,
# statically, straight from this issue's own design:
#
#   - the retired interim is actually GONE (script + its own dedicated
#     tests deleted, no stray reference left in nix/compose.nix or
#     archive.packages.json);
#   - dpkg now unpacks/configures with NO --path-exclude mechanism at all
#     -- every path extracts through dpkg's own normal code path, which
#     is the entire point of adopting fakeroot (letting dpkg "extract
#     normally" is what actually re-establishes owner/mode fidelity for
#     the non-root-owner and set*id cases the old scan script's first two
#     triggers existed for, and letting mksquashfs read back fakeroot's
#     own faked stat(2) data at pack time is what re-establishes it for
#     the too-tight-mode/canonicalization case its third trigger existed
#     for -- see nix/compose.nix's header for the full writeup);
#   - composeRootfs's dpkg --unpack/--configure sequence runs inside ONE
#     continuous fakeroot session (re-exec'd once, guarded by a
#     FAKEROOTKEY check, BEFORE any package is unpacked), and that
#     session's state is saved to a well-known path outside
#     /.ubx-compose (so it survives that directory's own cleanup);
#   - squashfsImage loads that EXACT SAME state-file path back via `-i`
#     and runs mksquashfs itself under fakeroot too -- with no `-pf`/`-e
#     ...pseudo...` manifest mechanism left at all.
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

# -- the retired interim is actually gone --------------------------------
[ ! -e "bin/ubx-scan-deb-ownership" ] ||
  fail "bin/ubx-scan-deb-ownership still exists -- GitHub issue #48 retires it once fakeroot fidelity is wired in"

for f in tests/unit/063-compose-ownership-scan.sh \
  tests/unit/064-scan-deb-ownership-no-devfd.sh \
  tests/unit/065-scan-deb-ownership-setid.sh \
  tests/unit/066-scan-deb-ownership-strict-mode.sh; do
  [ ! -e "$f" ] || fail "$f still exists -- should have been replaced by this file (GitHub issue #48)"
done

# Strip full-line comments first (mirrors the retired 064 test's own
# approach) -- this file's own header and nix/compose.nix's header both
# legitimately DISCUSS the retired mechanism in prose (see this file's own
# header above), so a naive grep over the whole file would false-positive
# on the documentation, not just live code. A comment beginning mid-line
# (Nix has no such syntax outside a `#`-led line) is not a concern here.
compose_code="$(grep -vE '^[[:space:]]*#' "$compose_nix")"
if printf '%s\n' "$compose_code" | grep -qE 'ubx-scan-deb-ownership|ubx-ownership-pseudo|path-exclude|ubx-ownership-excludes'; then
  fail "$compose_nix still references the retired scan/path-exclude/pseudo-file mechanism in live code (a historical mention in prose/comments is fine)"
fi

# -- fakeroot is fetched as a build tool, not composed into any rootfs ---
grep -qE 'toolsFHS[[:space:]]*\{' "$compose_nix" ||
  fail "$compose_nix no longer defines toolsFHS -- fakerootTools depends on it"

grep -qE 'fakerootTools = toolsFHS' "$compose_nix" ||
  fail "$compose_nix does not define fakerootTools via toolsFHS"

# Both the `fakeroot` frontend deb AND the separate `libfakeroot` deb (the
# LD_PRELOAD payload) must be requested: toolsFHS extracts each named
# package's data with no dependency resolution, so libfakeroot would
# otherwise be absent (regression guard for CI run 30199370520).
grep -qE 'packages = \[ "fakeroot" "libfakeroot" \]' "$compose_nix" ||
  fail "$compose_nix's fakerootTools does not request the 'fakeroot' and 'libfakeroot' packages"

# -- composeRootfs re-execs itself under fakeroot exactly once, guarded --
grep -qE 'FAKEROOTKEY' "$compose_nix" ||
  fail "$compose_nix does not guard its fakeroot re-exec with a FAKEROOTKEY check"

# -- tool discovery targets the CONCRETE -sysv binaries, not the bare
# alternatives-symlink names (regression guard for CI run 30199370520,
# where `-name fakeroot`/`-name 'faked-*'` found a dangling symlink and a
# manpage). Both discovery blocks (configure.sh + pack.sh) must use them.
[ "$(grep -cE "\-name 'fakeroot-sysv'" "$compose_nix")" -ge 2 ] ||
  fail "$compose_nix does not discover the concrete 'fakeroot-sysv' binary in both the compose and pack blocks"
[ "$(grep -cE "\-name 'faked-sysv'" "$compose_nix")" -ge 2 ] ||
  fail "$compose_nix does not discover the concrete 'faked-sysv' binary in both the compose and pack blocks"
if grep -qE -- "-type f -name fakeroot( |$)" "$compose_nix"; then
  fail "$compose_nix still discovers fakeroot by the bare 'fakeroot' name -- that is the update-alternatives symlink, dangling in a data-only extraction (CI run 30199370520)"
fi

# shellcheck disable=SC2016 # single-quoted on purpose: matching literal shell text in the source, not an expansion here
grep -qF 'exec "$ubx_fakeroot_bin"' "$compose_nix" ||
  fail "$compose_nix does not exec into fakeroot from inside configure.sh"

grep -qE -- '-s /\.ubx-fakeroot-state' "$compose_nix" ||
  fail "$compose_nix's composeRootfs does not save fakeroot state to /.ubx-fakeroot-state"

# The re-exec must happen BEFORE dpkg touches anything (unpack via
# unpackLines, configure via 'dpkg --configure -a') -- otherwise dpkg's
# own chown/chmod calls would run OUTSIDE the faked session and hit the
# same EINVAL/EPERM this issue exists to fix.
configure_sh="$(mktemp)"
trap 'rm -f "$configure_sh"' EXIT
sed -n "/<<'UBX_INNER_EOF'\$/,/UBX_INNER_EOF\$/p" "$compose_nix" | sed '1d;$d' > "$configure_sh"
[ -s "$configure_sh" ] ||
  fail "could not statically extract the UBX_INNER_EOF heredoc body from $compose_nix — its shape may have changed"

# shellcheck disable=SC2016 # single-quoted on purpose: matching literal shell text in the source, not an expansion here
reexec_line=$(grep -n 'exec "\$ubx_fakeroot_bin"' "$configure_sh" | head -1 | cut -d: -f1)
# shellcheck disable=SC2016 # single-quoted on purpose: matching literal Nix ${...} interpolation syntax
unpack_line=$(grep -n '\${unpackLines}' "$configure_sh" | head -1 | cut -d: -f1)
configure_a_line=$(grep -n 'dpkg --configure -a$' "$configure_sh" | head -1 | cut -d: -f1)

for pair_name in "reexec_line:fakeroot re-exec" "unpack_line:unpackLines splice" "configure_a_line:dpkg --configure -a"; do
  var="${pair_name%%:*}"
  desc="${pair_name#*:}"
  eval "val=\$$var"
  [ -n "$val" ] || fail "$configure_sh is missing the expected '$desc' line"
done

if [ -n "$reexec_line" ] && [ -n "$unpack_line" ]; then
  [ "$reexec_line" -lt "$unpack_line" ] ||
    fail "the fakeroot re-exec (line $reexec_line) does not come BEFORE unpacking packages (line $unpack_line) -- dpkg's own chown/chmod would run outside the faked session"
fi
if [ -n "$unpack_line" ] && [ -n "$configure_a_line" ]; then
  [ "$unpack_line" -lt "$configure_a_line" ] ||
    fail "unpackLines (line $unpack_line) does not come BEFORE dpkg --configure -a (line $configure_a_line)"
fi

# -- squashfsImage loads the SAME state-file path back, and packs with no
# manifest/pseudo-file mechanism left at all -----------------------------
grep -qE -- '-i /mnt/rootfs/\.ubx-fakeroot-state' "$compose_nix" ||
  fail "$compose_nix's squashfsImage does not load /mnt/rootfs/.ubx-fakeroot-state back via fakeroot's -i"

if grep -qE -- '-pf ' "$compose_nix"; then
  fail "$compose_nix still passes mksquashfs a -pf pseudo-file manifest -- GitHub issue #48 retires that mechanism entirely once fakeroot is wired in"
fi

grep -qE 'packages = \[ "squashfs-tools" "liblzo2-2" "fakeroot" "libfakeroot" \]' "$compose_nix" ||
  fail "$compose_nix's squashfsImage does not request fakeroot + libfakeroot alongside squashfs-tools/liblzo2-2"

# -- archive.packages.json: fakeroot declared (lockfile regeneration is a
# separate, PM-owned step -- see that file's own comment / the PM handoff
# notes for this issue) --------------------------------------------------
pkgs_json="archive.packages.json"
[ -f "$pkgs_json" ] || {
  echo "FAIL: $pkgs_json does not exist" >&2
  exit 1
}
python3 -c "
import json, sys
d = json.load(open('$pkgs_json'))
sys.exit(0 if 'fakeroot' in d.get('packages', []) else 1)
" || fail "$pkgs_json does not declare 'fakeroot' in its packages list"

exit "$fails"
