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

# -- squashfsImage packs with no -pf/pseudo-file mechanism, and loads a
# fakeroot database back via -i --------------------------------------------
#
# Issue #22 R1 determinism: the persisted /.ubx-fakeroot-state is no longer
# a raw (dev,inode)-keyed fakeroot save-file (those inode keys are allocated
# non-deterministically per build, so the raw file fails the strict
# `--rebuild` reproducibility check). composeRootfs now normalizes it into a
# deterministic, inode-INDEPENDENT path-keyed manifest, and pack.sh
# RECONSTRUCTS a real (dev,inode)-keyed save-file from that manifest against
# /mnt/rootfs's own actual inodes before the -i load. Assert pack loads the
# reconstructed db, not the raw state file directly.
grep -qE -- '-i /mnt/out/\.ubx-fakeroot-realdb' "$compose_nix" ||
  fail "$compose_nix's squashfsImage does not load the reconstructed /mnt/out/.ubx-fakeroot-realdb via fakeroot's -i (issue #22 determinism reconstruction)"

grep -qF 'printf "dev=%x,ino=%s,%s\n"' "$compose_nix" ||
  fail "$compose_nix's pack.sh does not reconstruct real (dev,inode) fakeroot keys from the normalized manifest"

if grep -qE -- '-pf ' "$compose_nix"; then
  fail "$compose_nix still passes mksquashfs a -pf pseudo-file manifest -- GitHub issue #48 retires that mechanism entirely once fakeroot is wired in"
fi

# -- composeRootfs normalizes the raw save-file into a deterministic,
# inode-independent manifest (issue #22 R1) ------------------------------
grep -qF 'UBX_NORMALIZE_AWK' "$compose_nix" ||
  fail "$compose_nix no longer defines the fakeroot save-file normalization step (UBX_NORMALIZE_AWK) -- issue #22 R1 determinism"

# The normalization must happen from OUTSIDE the chroot AFTER the fakeroot
# session wrote its raw save-file and BEFORE the epoch mtime-touch that
# stamps it -- otherwise the file it rewrites would still be the raw one, or
# the rewrite would clobber the epoch mtime. Both anchors are the literal
# `.ubx-fakeroot-state` sort-into and the `touch -h -d @0` of that same file.
# The single-quoted patterns intentionally match the LITERAL `$out` text as
# it appears in compose.nix (not a shell expansion), so SC2016 is expected.
# shellcheck disable=SC2016
norm_line=$(grep -n 'sort" ubx-fakeroot-manifest > "$out/\.ubx-fakeroot-state"' "$compose_nix" | head -1 | cut -d: -f1)
# shellcheck disable=SC2016
touch_line=$(grep -n 'touch" -h -d @0 "$out/\.ubx-fakeroot-state"' "$compose_nix" | head -1 | cut -d: -f1)
if [ -n "$norm_line" ] && [ -n "$touch_line" ]; then
  [ "$norm_line" -lt "$touch_line" ] ||
    fail "the fakeroot save-file normalization (line $norm_line) does not come BEFORE its epoch mtime-touch (line $touch_line)"
else
  fail "could not locate the normalization sort and/or the epoch mtime-touch of .ubx-fakeroot-state in $compose_nix"
fi

# -- DETERMINISM PROPERTY of the normalization logic ----------------------
#
# This dev harness has no fakeroot to produce a real save-file, but the
# normalization is a plain awk join we CAN exercise directly. Extract the
# actual awk program from compose.nix (same heredoc-extraction idiom this
# file already uses for UBX_INNER_EOF) and run it over two synthetic raw
# save-files that describe the SAME tree with DIFFERENT (dev,inode) key
# values -- exactly what two independent builds produce. The normalized,
# LC_ALL=C-sorted manifests MUST come out byte-identical (inode-independent)
# and path-keyed. If they don't, the fix does not actually fix R1.
if command -v awk >/dev/null 2>&1; then
  norm_awk="$(mktemp)"
  trap 'rm -f "$configure_sh" "$norm_awk"' EXIT
  sed -n "/<<'UBX_NORMALIZE_AWK'\$/,/UBX_NORMALIZE_AWK\$/p" "$compose_nix" | sed '1d;$d' > "$norm_awk"
  [ -s "$norm_awk" ] || fail "could not extract the UBX_NORMALIZE_AWK program from $compose_nix"

  if [ -s "$norm_awk" ]; then
    run_norm() { # <raw-db-file> <inos-file>
      awk -f "$norm_awk" "$1" "$2" | LC_ALL=C sort
    }
    # Build 1: some plausible inode/dev allocation.
    raw1="$(mktemp)"; ino1="$(mktemp)"
    printf 'dev=801,ino=100,mode=104755,uid=0,gid=0,nlink=1,rdev=0\n' >  "$raw1"
    printf 'dev=801,ino=200,mode=100640,uid=101,gid=102,nlink=1,rdev=0\n' >> "$raw1"
    printf '100\tusr/bin/setuidtool\n' >  "$ino1"
    printf '200\tetc/gshadow\n'        >> "$ino1"
    # Build 2: SAME two paths, DIFFERENT dev and inode key values.
    raw2="$(mktemp)"; ino2="$(mktemp)"
    printf 'dev=fe02,ino=987654,mode=104755,uid=0,gid=0,nlink=1,rdev=0\n' >  "$raw2"
    printf 'dev=fe02,ino=123,mode=100640,uid=101,gid=102,nlink=1,rdev=0\n' >> "$raw2"
    printf '987654\tusr/bin/setuidtool\n' >  "$ino2"
    printf '123\tetc/gshadow\n'           >> "$ino2"

    m1="$(run_norm "$raw1" "$ino1")"
    m2="$(run_norm "$raw2" "$ino2")"

    [ "$m1" = "$m2" ] ||
      fail "normalized fakeroot manifest is NOT inode-independent: differing (dev,inode) key values produced differing manifests (R1 would still fail)"

    # The manifest must be path-keyed with the (dev,inode) key stripped and
    # the owner/mode tail preserved verbatim, sorted by path.
    expected="$(printf 'etc/gshadow\tmode=100640,uid=101,gid=102,nlink=1,rdev=0\nusr/bin/setuidtool\tmode=104755,uid=0,gid=0,nlink=1,rdev=0')"
    [ "$m1" = "$expected" ] ||
      fail "normalized manifest is not the expected path-keyed, (dev,inode)-stripped, sorted form; got: $m1"

    rm -f "$raw1" "$ino1" "$raw2" "$ino2"
  fi
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
