#!/usr/bin/env bash
# tests/unit/054-ubx-resolve-suites.sh — bin/ubx-resolve must resolve
# against THREE suites (noble, noble-updates, noble-security), not just
# the plain release pocket (GitHub issue #39, SPEC.md §4.4).
#
# BACKGROUND: the isolated apt rootdir's sources.list used to carry exactly
# one `deb ... noble <components>` line, so every pin resolved to the
# plain-release pocket -- the OLDEST content a snapshot carries for that
# series. The compose bootstrap's `ubuntu-base` tarball, by contrast,
# already contains whatever -updates content was current when that tarball
# was built, so resolving against `noble` alone pinned package versions
# OLDER than what the base image already had installed: apt/dpkg
# "downgraded" packages mid-compose (issue #39's example: libpam-modules
# 1.5.3-5ubuntu5.5 -> 1.5.3-5ubuntu5), a composed system that ends up
# security-wise behind its own base. SPEC.md §4.4 already scopes the
# public tier as "archive.ubuntu.com + security.ubuntu.com" -- i.e. the
# updates/security pockets are in-spec already -- so the fix is to resolve
# against all three suites of the SAME pinned snapshot, not to add any new
# network source.
#
# This exercises `bin/ubx-resolve --print-sources-list`, a pure (no
# network, no apt) testing hook that runs the exact same
# `write_sources_list` function real resolution uses (see
# bin/ubx-resolve's "Which suites get resolved" header section) -- the
# apt-solver half that actually resolves against these suites is exercised
# end-to-end only in CI's "resolve" job (tests/README.md's "unit tests must
# not require root, network, or KVM" rule).
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

resolve="$UBX_REPO_ROOT/bin/ubx-resolve"
[ -x "$resolve" ] || {
  echo "FAIL: $resolve does not exist or is not executable" >&2
  exit 1
}

snapshot="20260715T000000Z"
keyring="/usr/share/keyrings/ubuntu-archive-keyring.gpg"

# A small, self-contained declaration fixture so this test doesn't depend
# on the committed archive.packages.json's current component set.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
decl="$work/declaration.json"
cat > "$decl" <<'EOF'
{
  "series": "noble",
  "components": ["main", "universe"],
  "packages": ["hello"]
}
EOF

out="$("$resolve" --print-sources-list --declaration "$decl" \
  --snapshot "$snapshot" --keyring "$keyring" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "--print-sources-list should exit 0 (rc=$rc, output: $out)"

expected="deb [signed-by=$keyring] https://snapshot.ubuntu.com/ubuntu/$snapshot noble main universe
deb [signed-by=$keyring] https://snapshot.ubuntu.com/ubuntu/$snapshot noble-updates main universe
deb [signed-by=$keyring] https://snapshot.ubuntu.com/ubuntu/$snapshot noble-security main universe"

[ "$out" = "$expected" ] || fail "sources.list content mismatch.
--- expected ---
$expected
--- got ---
$out"

# Line count: exactly three, no more, no fewer -- issue #39 is specifically
# about a single-line sources.list being insufficient; a regression back to
# one line (or an unbounded growth beyond three) must fail this test.
line_count="$(printf '%s\n' "$out" | grep -c '^deb ')"
[ "$line_count" -eq 3 ] || fail "expected exactly 3 'deb' lines, got $line_count: $out"

# Order is fixed (noble, noble-updates, noble-security) -- apt's own
# tie-breaking among equally-versioned candidates depends on sources.list
# order, so the solver's output must stay deterministic run over run.
first_suite="$(printf '%s\n' "$out" | sed -n '1p' | awk '{print $4}')"
second_suite="$(printf '%s\n' "$out" | sed -n '2p' | awk '{print $4}')"
third_suite="$(printf '%s\n' "$out" | sed -n '3p' | awk '{print $4}')"
[ "$first_suite" = "noble" ] || fail "line 1 suite should be 'noble', got '$first_suite'"
[ "$second_suite" = "noble-updates" ] || fail "line 2 suite should be 'noble-updates', got '$second_suite'"
[ "$third_suite" = "noble-security" ] || fail "line 3 suite should be 'noble-security', got '$third_suite'"

# Same snapshot timestamp and same signed-by keyring on every line --
# widening which pockets apt solves against must never widen the trust
# root or pin a second, different snapshot.
snapshot_count="$(printf '%s\n' "$out" | grep -c "ubuntu/$snapshot ")"
[ "$snapshot_count" -eq 3 ] || fail "expected all 3 lines to carry snapshot '$snapshot', got $snapshot_count"
keyring_count="$(printf '%s\n' "$out" | grep -c "signed-by=$keyring")"
[ "$keyring_count" -eq 3 ] || fail "expected all 3 lines to carry keyring '$keyring', got $keyring_count"

# Component set identical across all three lines.
components_1="$(printf '%s\n' "$out" | sed -n '1p' | cut -d' ' -f5-)"
components_2="$(printf '%s\n' "$out" | sed -n '2p' | cut -d' ' -f5-)"
components_3="$(printf '%s\n' "$out" | sed -n '3p' | cut -d' ' -f5-)"
[ "$components_1" = "main universe" ] || fail "line 1 components should be 'main universe', got '$components_1'"
[ "$components_1" = "$components_2" ] || fail "components differ between line 1 and line 2 ('$components_1' vs '$components_2')"
[ "$components_1" = "$components_3" ] || fail "components differ between line 1 and line 3 ('$components_1' vs '$components_3')"

# --print-sources-list requires --snapshot, mirroring --emit-lockfile's
# contract (tests/unit/052-ubx-resolve-cli.sh) -- resolution is inherently
# impure, so a caller must always pin the snapshot explicitly.
out2="$("$resolve" --print-sources-list --declaration "$decl" --keyring "$keyring" 2>&1)"
rc2=$?
[ "$rc2" -ne 0 ] || fail "'--print-sources-list' without '--snapshot' should fail"
case "$out2" in
  *"--snapshot"*) ;;
  *) fail "missing-snapshot error should mention --snapshot, got: $out2" ;;
esac

# --help documents the new flag.
help_out="$("$resolve" --help 2>&1)"
case "$help_out" in
  *"--print-sources-list"*) ;;
  *) fail "--help output missing '--print-sources-list'" ;;
esac

exit "$fails"
