#!/usr/bin/env bash
# tests/unit/066-scan-deb-ownership-strict-mode.sh — bin/ubx-scan-deb-
# ownership: the THIRD, independent scan trigger (GitHub issue #45: Nix
# store-path canonicalization silently LOOSENING a root:root file's real
# mode).
#
# -- The gap this closes -------------------------------------------------
#
# nix/compose.nix's composeRootfs produces a Nix store path. Nix
# canonicalizes every file/dir inside a registered store path to a FIXED
# mode -- 0444 for a regular file, 0555 for a directory -- regardless of
# what mode dpkg originally installed it with (and strips any setuid/
# setgid/sticky bit, which bin/ubx-scan-deb-ownership's existing "MODE
# follow-up" trigger, tests/unit/065's own coverage, already handles).
# Until this change, a root:root, NON-set*id file whose real mode is
# STRICTER than canonical -- e.g. /etc/shadow-like 0600, or 0640, or a
# 0700 directory -- sailed straight through dpkg's own unpack (no EINVAL,
# no EPERM: plain chown-to-root and plain chmod both succeed fine inside
# the sandbox for an ordinary permission-only mode) and was never
# selected by this script at all. bootRootfs's copy and squashfsImage's
# pack then only ever saw the CANONICAL mode -- so the final image
# quietly WORLD-READABLE (0444) a file the real package shipped
# world-UNREADABLE (0600/0640/0400/0440): a genuine hardening regression,
# not merely a cosmetic metadata loss.
#
# -- The rule this script must now also apply -----------------------------
#
# Canonical is 0444 for a regular file (also applied to symlinks/
# hardlinks, which this script's existing type-folding treats identically
# to a plain file) and 0555 for a directory. A root:root, non-set*id path
# is now ALSO selected if canonical would GRANT some read/write/execute
# bit that the real recorded mode WITHHOLDS -- i.e. per permission
# triad (owner/group/other), (canonical_bits & ~real_bits) != 0 for that
# triad. This is deliberately asymmetric: a path that only LOSES bits
# under canonicalization (0755 file -> 0444: canonical is a STRICTER
# subset, nothing is gained) must stay UNSELECTED -- the existing "no
# behavior change for ordinary files" guarantee (tests/unit/063/065's own
# plain-file fixtures) must keep holding for the common 0644/0755 case.
#
# This file is a sibling to 063 (ownership trigger) and 065 (set*id
# trigger) -- same fixture-deb approach (tests/lib/make-fixture-deb.py),
# disjoint concern, run against the same script.
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
  # list read on stdin. Identical helper to tests/unit/063/065's own.
  local name="$1" entries="$work/$1.json" deb="$work/$1.deb"
  cat > "$entries"
  python3 "$mkfixture" "$deb" "$entries" || {
    echo "FAIL: make-fixture-deb.py failed for fixture '$name'" >&2
    exit 1
  }
  echo "$deb"
}

# -- the concrete GitHub issue #45 case: a root:root, mode-0640 file
#    (group/other read withheld vs canonical 0444's world-read grant)
#    alongside an ordinary root:root 0644 sibling that must NOT be
#    selected -- proves the strict-mode trigger fires independent of
#    ownership/set*id, and doesn't over-fire on an ordinary file. --------
strict640_deb="$(build_deb strict640 <<'EOF'
[
  {"name": "./etc/secretish", "data": "s3cr3t", "mode": 416, "uid": 0, "gid": 0},
  {"name": "./etc/plain", "data": "plain", "mode": 420, "uid": 0, "gid": 0}
]
EOF
)"
out="$("$scan" "$strict640_deb" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "the 0640 fixture should exit 0, got $rc: $out"
expected="/etc/secretish	f	0640	0	0"
[ "$out" = "$expected" ] || fail "0640 fixture: expected exactly one record ('$expected'), got: $out"

# -- a root:root, mode-0600 file (owner-only, the /etc/shadow-shaped
#    case): both group AND other read withheld vs canonical. -------------
strict600_deb="$(build_deb strict600 <<'EOF'
[
  {"name": "./etc/shadow-like", "data": "root:!:19000:0:99999:7:::", "mode": 384, "uid": 0, "gid": 0}
]
EOF
)"
out="$("$scan" "$strict600_deb" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "the 0600 fixture should exit 0, got $rc: $out"
expected="/etc/shadow-like	f	0600	0	0"
[ "$out" = "$expected" ] || fail "0600 fixture: expected exactly one record ('$expected'), got: $out"

# -- a root:root, mode-0400 file (owner-read-only, no write at all): the
#    withheld bits are group/other read again, same as 0600 -- proves
#    the rule looks at GRANTED-but-withheld bits, not merely "does the
#    file have a write bit somewhere". ------------------------------------
strict400_deb="$(build_deb strict400 <<'EOF'
[
  {"name": "./etc/readonly-secret", "data": "x", "mode": 256, "uid": 0, "gid": 0}
]
EOF
)"
out="$("$scan" "$strict400_deb" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "the 0400 fixture should exit 0, got $rc: $out"
expected="/etc/readonly-secret	f	0400	0	0"
[ "$out" = "$expected" ] || fail "0400 fixture: expected exactly one record ('$expected'), got: $out"

# -- a root:root, mode-0440 file (owner+group read, other withheld). -----
strict440_deb="$(build_deb strict440 <<'EOF'
[
  {"name": "./etc/group-readable-secret", "data": "x", "mode": 288, "uid": 0, "gid": 0}
]
EOF
)"
out="$("$scan" "$strict440_deb" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "the 0440 fixture should exit 0, got $rc: $out"
expected="/etc/group-readable-secret	f	0440	0	0"
[ "$out" = "$expected" ] || fail "0440 fixture: expected exactly one record ('$expected'), got: $out"

# -- a root:root, mode-0700 DIRECTORY (canonical for a dir is 0555 --
#    group/other read+execute both withheld). ----------------------------
strict700dir_deb="$(build_deb strict700dir <<'EOF'
[
  {"name": "./root/.ssh/", "type": "dir", "mode": 448, "uid": 0, "gid": 0}
]
EOF
)"
out="$("$scan" "$strict700dir_deb" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "the 0700-dir fixture should exit 0, got $rc: $out"
expected="/root/.ssh	d	0700	0	0"
[ "$out" = "$expected" ] || fail "0700-dir fixture: expected exactly one record ('$expected'), got: $out"

# -- a root:root, mode-0750 DIRECTORY (other read+execute withheld). -----
strict750dir_deb="$(build_deb strict750dir <<'EOF'
[
  {"name": "./etc/restricted/", "type": "dir", "mode": 488, "uid": 0, "gid": 0}
]
EOF
)"
out="$("$scan" "$strict750dir_deb" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "the 0750-dir fixture should exit 0, got $rc: $out"
expected="/etc/restricted	d	0750	0	0"
[ "$out" = "$expected" ] || fail "0750-dir fixture: expected exactly one record ('$expected'), got: $out"

# -- ordinary root:root 0755/0644 must NOT be selected: canonicalization
#    only ever STRIPS bits from these (0755 file -> 0444, 0644 -> 0444;
#    0755 dir -> 0555), never GRANTS one they don't already have -- the
#    "no manifest bloat for the common case" guarantee. Asserted both
#    alone (this fixture) and implicitly above (the 0640/0644 sibling
#    fixture already proved the plain file isn't swept in alongside a
#    selected one). ------------------------------------------------------
ordinary_deb="$(build_deb ordinary <<'EOF'
[
  {"name": "./usr/bin/plain-exec", "data": "x", "mode": 493, "uid": 0, "gid": 0},
  {"name": "./usr/share/plain-doc", "data": "x", "mode": 420, "uid": 0, "gid": 0},
  {"name": "./usr/share/plaindir/", "type": "dir", "mode": 493, "uid": 0, "gid": 0}
]
EOF
)"
out="$("$scan" "$ordinary_deb" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "an all-ordinary fixture should exit 0, got $rc: $out"
[ -z "$out" ] || fail "an all-ordinary (0755/0644 root:root) fixture should produce no output, got: $out"

# -- existing triggers (063's non-root owner, 065's set*id) must still be
#    unaffected by this new third trigger -- a quick regression re-check
#    right here, not just relying on 063/065 running separately, so a
#    change that accidentally folds the checks together in a way that
#    breaks one is caught by EITHER file. ---------------------------------
pam_deb="$(build_deb pam <<'EOF'
[
  {"name": "./usr/sbin/pam_extrausers_chkpwd", "data": "fake-elf",
   "mode": 1517, "uid": 0, "gid": 42, "uname": "root", "gname": "shadow"}
]
EOF
)"
out="$("$scan" "$pam_deb" 2>&1)"
expected="/usr/sbin/pam_extrausers_chkpwd	f	2755	0	42"
[ "$out" = "$expected" ] || fail "pam (non-root-owner) regression: expected '$expected', got: $out"

setuid_deb="$(build_deb setuid <<'EOF'
[
  {"name": "./usr/bin/mount", "data": "fake-elf", "mode": 2541, "uid": 0, "gid": 0}
]
EOF
)"
out="$("$scan" "$setuid_deb" 2>&1)"
expected="/usr/bin/mount	f	4755	0	0"
[ "$out" = "$expected" ] || fail "mount (setuid) regression: expected '$expected', got: $out"

exit "$fails"
