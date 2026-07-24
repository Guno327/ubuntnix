#!/usr/bin/env bash
# tests/unit/065-scan-deb-ownership-setid.sh — bin/ubx-scan-deb-ownership:
# the setuid/setgid/sticky-bit scan trigger (GitHub issue #10 PR #36
# follow-up; CI run 29955725327: the full-168-package-closure
# `rootfs-boot-proof` compose failing on dpkg's own unpack of
# /usr/bin/mount --
#
#   rootfs-boot-proof> dpkg: error processing archive
#   /.ubx-compose/debs/142.deb (--unpack):
#   rootfs-boot-proof>  error setting permissions of './usr/bin/mount':
#   Operation not permitted
#
# -- see bin/ubx-scan-deb-ownership's own "The MODE follow-up" header
# section for the full root-cause writeup: this is a SECOND, independent
# trigger for that script's existing exclude+restore+pseudo-file
# machinery, alongside non-root ownership (tests/unit/063's own
# coverage), and this file is its sibling rather than an extension of 063
# -- same fixture-deb approach, disjoint concern).
#
# Mirrors tests/unit/063-compose-ownership-scan.sh's own approach exactly:
# bin/ubx-scan-deb-ownership is a plain dpkg-deb/tar-only script, so this
# test runs it for real against fixture .deb archives (built by
# tests/lib/make-fixture-deb.py) and asserts on its actual stdout/exit
# code -- specifically here, that mode_to_octal correctly recognizes every
# set*id/sticky indicator tar's symbolic mode string can carry (verified
# against REAL dpkg-deb/tar output, not a hand-typed assumption of what
# that output looks like), and that a root:root member carrying one of
# those bits is selected (and a root:root member that does NOT is still
# excluded, exactly as before).
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
  # list read on stdin. Identical helper to tests/unit/063's own.
  local name="$1" entries="$work/$1.json" deb="$work/$1.deb"
  cat > "$entries"
  python3 "$mkfixture" "$deb" "$entries" || {
    echo "FAIL: make-fixture-deb.py failed for fixture '$name'" >&2
    exit 1
  }
  echo "$deb"
}

# -- the concrete CI case: a root:root, mode-4755 (setuid) file, sitting
#    right alongside a root:root, mode-0644 (plain) file that must NOT be
#    selected -- proves the mode trigger fires independent of ownership,
#    and doesn't over-fire on an ordinary file. `mode: 2541` is decimal
#    0o4755 -- tests/lib/make-fixture-deb.py's `mode` field is a plain
#    Python int passed straight to tarfile.TarInfo.mode, so it must be
#    written in decimal here (the "1517" pam_extrausers_chkpwd literal in
#    tests/unit/063 is the same convention: decimal 1517 == octal 2755).
setuid_deb="$(build_deb setuid <<'EOF'
[
  {"name": "./usr/bin/mount", "data": "fake-elf", "mode": 2541, "uid": 0, "gid": 0},
  {"name": "./usr/bin/plain", "data": "plain", "mode": 420, "uid": 0, "gid": 0}
]
EOF
)"
out="$("$scan" "$setuid_deb" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "the setuid fixture should exit 0, got $rc: $out"
expected="/usr/bin/mount	f	4755	0	0"
[ "$out" = "$expected" ] || fail "setuid fixture: expected exactly one record ('$expected'), got: $out"

# -- a root:root, mode-2755 (setgid) file -- the OTHER special bit,
#    distinct from setuid, on a member that (unlike tests/unit/063's
#    pam_extrausers_chkpwd) has NO non-root ownership of its own, so a
#    match here can only come from the mode trigger. --------------------
setgid_deb="$(build_deb setgid <<'EOF'
[
  {"name": "./usr/bin/newgrp", "data": "fake-elf", "mode": 1517, "uid": 0, "gid": 0}
]
EOF
)"
out="$("$scan" "$setgid_deb" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "the setgid fixture should exit 0, got $rc: $out"
expected="/usr/bin/newgrp	f	2755	0	0"
[ "$out" = "$expected" ] || fail "setgid fixture: expected exactly one record ('$expected'), got: $out"

# -- a root:root, mode-1777 (sticky) DIRECTORY -- the third special bit,
#    and the directory ('d' type) path through the same trigger. --------
sticky_deb="$(build_deb sticky <<'EOF'
[
  {"name": "./var/tmp2/", "type": "dir", "mode": 1023, "uid": 0, "gid": 0}
]
EOF
)"
out="$("$scan" "$sticky_deb" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "the sticky-dir fixture should exit 0, got $rc: $out"
expected="/var/tmp2	d	1777	0	0"
[ "$out" = "$expected" ] || fail "sticky-dir fixture: expected exactly one record ('$expected'), got: $out"

# -- a root:root, mode-0644 (plain) file, alone: still produces NO output
#    -- the "no behavior change for ordinary files" guarantee, restated
#    here (not just alongside the setuid fixture above) so a future
#    change to the mode trigger's threshold logic can't accidentally pass
#    by only ever checking it in combination with a selected sibling. ----
plain_deb="$(build_deb plain-only <<'EOF'
[
  {"name": "./usr/bin/plain", "data": "plain", "mode": 420, "uid": 0, "gid": 0}
]
EOF
)"
out="$("$scan" "$plain_deb" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "an all-plain fixture should exit 0, got $rc: $out"
[ -z "$out" ] || fail "an all-plain fixture should produce no output, got: $out"

# -- setuid WITHOUT the executable bit ("-rwSr--r--", mode 04644 decimal
#    2596) -- tar renders the owner-exec position as capital 'S' (bit set,
#    NOT executable) rather than lowercase 's' here; mode_to_octal must
#    still fold it into the special digit without adding the execute bit
#    it doesn't carry. This is the one combination tests/unit/063's own
#    pam_extrausers_chkpwd/symlink/hardlink fixtures never exercised (they
#    are all executable), so it's the one genuinely NEW parsing path this
#    file's fixtures need to prove against real tar output rather than
#    assume. ------------------------------------------------------------
nox_deb="$(build_deb setuid-noexec <<'EOF'
[
  {"name": "./usr/bin/oddball", "data": "fake-elf", "mode": 2468, "uid": 0, "gid": 0}
]
EOF
)"
out="$("$scan" "$nox_deb" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "the setuid-noexec fixture should exit 0, got $rc: $out"
expected="/usr/bin/oddball	f	4644	0	0"
[ "$out" = "$expected" ] || fail "setuid-noexec fixture: expected exactly one record ('$expected'), got: $out"

exit "$fails"
