#!/usr/bin/env bash
# tests/unit/080-compose-ownership-scan.sh — bin/ubx-scan-deb-ownership:
# real functional tests against fixture .deb archives (GitHub issue #10
# PR #36: the full-168-package-closure `rootfs-boot-proof` compose failing
# on libpam-modules-bin's setgid-shadow pam_extrausers_chkpwd -- see that
# script's own header for the full root-cause writeup).
#
# Mirrors tests/unit/070-boot-grub-cfg-gen.sh's own approach: bin/ubx-scan-
# deb-ownership is a plain dpkg-deb/tar-only script, so this test runs it
# for real against fixture .deb archives (built by tests/lib/make-fixture-
# deb.py, entirely in Python's `tarfile` -- no root/fakeroot needed to
# embed non-root ownership metadata in a tar member; see that script's own
# header) and asserts on its actual stdout/exit code.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

scan="$UBX_REPO_ROOT/bin/ubx-scan-deb-ownership"
mkfixture="$UBX_REPO_ROOT/tests/lib/make-fixture-deb.py"
for f in "$scan" "$mkfixture"; do
  [ -e "$f" ] || {
    echo "FAIL: $f does not exist" >&2
    exit 1
  }
done
[ -x "$scan" ] || {
  echo "FAIL: $scan is not executable" >&2
  exit 1
}
command -v dpkg-deb > /dev/null 2>&1 || {
  echo "SKIP: no dpkg-deb on this host -- cannot build/read fixture .deb archives" >&2
  exit 77
}
command -v python3 > /dev/null 2>&1 || {
  echo "SKIP: no python3 on this host -- cannot build fixture .deb archives" >&2
  exit 77
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

build_deb() {
  # build_deb NAME <<<'[...]' — writes $work/NAME.deb from a JSON entries
  # list read on stdin.
  local name="$1" entries="$work/$1.json" deb="$work/$1.deb"
  cat > "$entries"
  python3 "$mkfixture" "$deb" "$entries" || {
    echo "FAIL: make-fixture-deb.py failed for fixture '$name'" >&2
    exit 1
  }
  echo "$deb"
}

# -- --help / -h --------------------------------------------------------
for flag in --help -h; do
  out="$("$scan" "$flag" 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] || fail "'$flag' should exit 0, got $rc"
  case "$out" in
    *DEBFILE*) ;;
    *) fail "'$flag' output missing 'DEBFILE'" ;;
  esac
done

# -- wrong argument count -------------------------------------------------
out="$("$scan" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "no arguments should fail, got exit 0"
out="$("$scan" a b 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "two arguments should fail, got exit 0"

# -- missing file -----------------------------------------------------------
out="$("$scan" "$work/does-not-exist.deb" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "a nonexistent DEBFILE should fail, got exit 0"

# -- an all-root-owned package (the common case: htop/hello/tzdata/... in
#    this project's existing compose-proof/compose-preseed-proof) produces
#    NO output and exits 0 -- this is the "no behavior change for packages
#    that don't need this mechanism" guarantee nix/compose.nix's own
#    comment at the call site relies on. -----------------------------------
all_root="$(build_deb all-root <<'EOF'
[
  {"name": "./usr/bin/htop", "data": "binary", "mode": 493, "uid": 0, "gid": 0}
]
EOF
)"
out="$("$scan" "$all_root" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "an all-root-owned fixture should exit 0, got $rc: $out"
[ -z "$out" ] || fail "an all-root-owned fixture should produce no output, got: $out"

# -- the real-world case this whole mechanism exists for: a setgid-shadow
#    helper binary (libpam-modules-bin's pam_extrausers_chkpwd) plus a
#    plain root:root sibling file, which must NOT show up in the output. -
pam_deb="$(build_deb pam <<'EOF'
[
  {"name": "./usr/sbin/pam_extrausers_chkpwd", "data": "fake-elf",
   "mode": 1517, "uid": 0, "gid": 42, "uname": "root", "gname": "shadow"},
  {"name": "./usr/bin/plain", "data": "plain", "mode": 493, "uid": 0, "gid": 0}
]
EOF
)"
out="$("$scan" "$pam_deb" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "the pam fixture should exit 0, got $rc: $out"
expected="/usr/sbin/pam_extrausers_chkpwd	f	2755	0	42"
[ "$out" = "$expected" ] || fail "pam fixture: expected exactly one record ('$expected'), got: $out"

# -- a non-root-owned DIRECTORY is reported with type 'd', and a trailing
#    "/" (as tar itself always lists directory entries) is stripped. ------
dir_deb="$(build_deb dir <<'EOF'
[
  {"name": "./var/lib/extrausers/", "type": "dir", "mode": 1533, "uid": 0,
   "gid": 42, "uname": "root", "gname": "shadow"}
]
EOF
)"
out="$("$scan" "$dir_deb" 2>&1)"
expected="/var/lib/extrausers	d	2775	0	42"
[ "$out" = "$expected" ] || fail "dir fixture: expected '$expected', got: $out"

# -- symlinks and hardlinks: the "-> target" / "link to target" listing
#    annotations tar -tv appends must be stripped from the reported path,
#    and both are reported with type 'f' (restored via a targeted `tar
#    -x`, same as a plain file -- see bin/ubx-scan-deb-ownership's header).
link_deb="$(build_deb links <<'EOF'
[
  {"name": "./etc/thing", "data": "x", "mode": 416, "uid": 0, "gid": 42, "gname": "shadow"},
  {"name": "./etc/symlink-thing", "type": "symlink", "linkname": "thing",
   "mode": 511, "uid": 0, "gid": 42, "gname": "shadow"},
  {"name": "./etc/hardlink-thing", "type": "hardlink", "linkname": "./etc/thing",
   "mode": 416, "uid": 0, "gid": 42, "gname": "shadow"}
]
EOF
)"
out="$("$scan" "$link_deb" 2>&1)"
case "$out" in
  *'->'*) fail "symlink target annotation ('-> thing') leaked into scan output: $out" ;;
esac
case "$out" in
  *'link to'*) fail "hardlink target annotation ('link to ...') leaked into scan output: $out" ;;
esac
echo "$out" | grep -qE '^/etc/symlink-thing	f	0777	0	42$' ||
  fail "symlink record missing/wrong, got: $out"
echo "$out" | grep -qE '^/etc/hardlink-thing	f	0640	0	42$' ||
  fail "hardlink record missing/wrong, got: $out"

# -- a non-root-owned device node has no safe restoration path (mknod is
#    refused inside the compose sandbox regardless of ownership) -- this
#    must fail loudly, not silently emit a record the caller can't act on.
dev_deb="$(build_deb dev <<'EOF'
[
  {"name": "./dev/madeup", "type": "chardev", "mode": 438, "uid": 0, "gid": 42, "gname": "shadow"}
]
EOF
)"
out="$("$scan" "$dev_deb" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "a non-root-owned device-node fixture should fail, got exit 0: $out"
case "$out" in
  *"/dev/madeup"*) ;;
  *) fail "device-node failure should name the offending path, got: $out" ;;
esac

# -- a ROOT-OWNED device node is outside this script's remit (an
#    orthogonal, pre-existing sandbox limitation -- see nix/compose.nix)
#    and must NOT be flagged: only non-root ownership is this script's
#    concern. --------------------------------------------------------------
root_dev_deb="$(build_deb root-dev <<'EOF'
[
  {"name": "./dev/null", "type": "chardev", "mode": 438, "uid": 0, "gid": 0}
]
EOF
)"
out="$("$scan" "$root_dev_deb" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "a root-owned device-node fixture should exit 0 (out of scope for this script), got $rc: $out"
[ -z "$out" ] || fail "a root-owned device-node fixture should produce no output, got: $out"

# -- a path containing a dpkg path-exclude glob metacharacter must fail
#    loudly rather than risk building a pattern that matches more (or
#    less) than the single path it was derived from. -----------------------
glob_deb="$(build_deb glob <<'EOF'
[
  {"name": "./etc/weird[name]", "data": "x", "uid": 0, "gid": 42, "gname": "shadow"}
]
EOF
)"
out="$("$scan" "$glob_deb" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "a glob-metacharacter path should fail, got exit 0: $out"
case "$out" in
  *"glob metacharacter"*) ;;
  *) fail "glob-metacharacter failure should say so, got: $out" ;;
esac

# -- a path containing whitespace must fail loudly too (it would corrupt
#    the space/tab-separated dpkg.cfg.d / mksquashfs pseudo-file records
#    the caller builds from this script's output). --------------------------
space_deb="$(build_deb space <<'EOF'
[
  {"name": "./etc/weird name", "data": "x", "uid": 0, "gid": 42, "gname": "shadow"}
]
EOF
)"
out="$("$scan" "$space_deb" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "a whitespace-containing path should fail, got exit 0: $out"
case "$out" in
  *"whitespace"*) ;;
  *) fail "whitespace-path failure should say so, got: $out" ;;
esac

exit "$fails"
