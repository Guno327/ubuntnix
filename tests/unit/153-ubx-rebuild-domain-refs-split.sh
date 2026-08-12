#!/usr/bin/env bash
# tests/unit/153-ubx-rebuild-domain-refs-split.sh — regression test for a
# real production bug the M3 snap-convergence QEMU e2e (GitHub issue #64,
# tests/e2e/030-qemu-snap-e2e.sh) caught: a generation that declares ONLY a
# snap manifest (no etc/systemd/users -- the M3 e2e's own first generation
# is the first place in this repo that ever does this) silently lost its
# snap domain, and misfed the snap manifest to the etc domain instead, on
# every SUBSEQUENT `ubx rebuild switch` against that same root.
#
# -- Root cause --------------------------------------------------------
#
# `ubx_rebuild_domain_refs` (bin/ubx-rebuild-lib) prints one tab-separated
# line, at the time of the M3 bug "ETC<TAB>SYSTEMD<TAB>USERS<TAB>SNAP\n"
# (today it is eight fields —
# "ETC<TAB>SYSTEMD<TAB>USERS<TAB>SNAP<TAB>SECRETS<TAB>PRO<TAB>HOME<TAB>CRYPTTAB\n",
# secrets/pro/home/crypttab each simply APPENDED at the end as they landed
# — but the same positional-preservation requirement applies identically
# to every field, old or new). For a generation declaring only a snap
# manifest, that line was "\t\t\t<snapref>\n" -- three EMPTY leading
# fields. bin/ubx used to read this with a plain
# `IFS=$'\t' read -r A B C D`; bash's `read` treats a tab as a
# WHITESPACE-CLASS IFS character and TRIMS/COLLAPSES adjacent empty
# fields instead of preserving them positionally, so `<snapref>` was
# misassigned into the FIRST variable (the etc ref) and the real fourth
# variable (the snap ref) came out empty. Fixed by
# `ubx_domain_refs_split` (bin/ubx), which uses `readarray -td $'\t'`
# instead -- see that function's own header comment for the full
# explanation and a worked example.
#
# This test is the pure-shell, offline analogue of the M3 e2e's own
# scenario 3 ("reconverge with no manifest change re-sideloads nothing"):
# it drives two REAL, consecutive `ubx rebuild switch --apply` calls
# against the SAME root, both declaring the SAME (unchanged) snap-only
# manifest, with the snapd-mutation/query seams stubbed (no root, no
# network, no real snapd -- tests/README.md's unit-test rule) and asserts:
#   1. both calls exit 0 (a misfed etc ref makes `ubx-etc plan` choke on a
#      snap manifest's JSON shape -- a hard failure, not just a wrong
#      answer -- so this alone would have caught the bug on this axis);
#   2. the SECOND call issues NO new ack/install/refresh snap-cmd calls
#      (the bug re-emitted ack+install every time, because the synthesized
#      "observed" state was built from a spuriously-empty old manifest);
#   3. the etc domain is reported as skipped on both calls (proving the
#      snap manifest was never misfed to it as an etc ref).
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

ubx="$UBX_REPO_ROOT/bin/ubx"
[ -x "$ubx" ] || { echo "FAIL: $ubx does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# -- recording stub standing in for the real `snap` client (UBX_SNAP_CMD) --
snap_cmd_log="$work/snap-cmd.log"
: > "$snap_cmd_log"
snap_cmd_stub="$work/stub-snap-cmd"
cat > "$snap_cmd_stub" <<EOF
#!/bin/sh
echo "\$*" >> "$snap_cmd_log"
exit 0
EOF
chmod +x "$snap_cmd_stub"

# -- UBX_SNAP_BIN: reports exactly the declared snap as installed (no
#    undeclared drift), so the purge sweep never tries to shell out beyond
#    this stub either. --------------------------------------------------
snap_bin_stub="$work/stub-snap-bin"
cat > "$snap_bin_stub" <<'STUBEOF'
#!/usr/bin/env bash
set -u
if [ "$1" = "list" ]; then
  printf 'Name      Version   Rev   Tracking       Publisher     Notes\n'
  printf 'hello-world 29        29  latest/stable  Canonical**   -\n'
  exit 0
fi
echo "stub-snap-bin: unexpected invocation: $*" >&2
exit 99
STUBEOF
chmod +x "$snap_bin_stub"

# -- a snap-only manifest, matching the M3 e2e's own declared set shape --
manifest="$work/snap-manifest.json"
cat > "$manifest" <<'EOF'
{"version": 1, "snaps": [
  {"name": "hello-world", "channel": "stable", "revision": 29, "classic": false, "connections": [], "config": {}}
]}
EOF

export UBX_SNAP_CMD="$snap_cmd_stub"
export UBX_SNAP_BIN="$snap_bin_stub"
export UBX_SOFT_REBOOT_CMD=true
export UBX_NEXTROOT_STAGE_CMD=true

root="$work/gens"
common_flags=(--rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --snap-manifest "$manifest")

# ===== first switch: a fresh install (ack + install) -- baseline =========
out1="$("$ubx" rebuild switch --root "$root" "${common_flags[@]}" --apply 2>&1)"
rc1=$?
[ "$rc1" -eq 0 ] || fail "first 'rebuild switch --apply' (snap-only generation) should exit 0, got $rc1: $out1"
contains "$out1" "etc: nothing declared" || fail "first switch: etc domain should be reported as skipped (no etc ref declared), got: $out1"

calls_after_first="$(wc -l < "$snap_cmd_log")"
[ "$calls_after_first" -ge 2 ] || fail "first switch should have issued at least 2 real snap-cmd calls (ack, install), got $calls_after_first: $(cat "$snap_cmd_log")"

# ===== second switch: SAME root, SAME (unchanged) manifest ================
#
# This is exactly where the bug lived: `old_current` now points at a REAL
# prior generation whose OWN manifest declares a snap ref but no etc/
# systemd/users refs -- ubx_rebuild_domain_refs' "\t\t\t<snapref>" shape.
out2="$("$ubx" rebuild switch --root "$root" "${common_flags[@]}" --apply 2>&1)"
rc2=$?
[ "$rc2" -eq 0 ] || fail "second 'rebuild switch --apply' (unchanged snap-only manifest) should exit 0, got $rc2: $out2 -- BUG: the old snap ref was misassigned into the etc ref, so 'ubx-etc plan' chokes on a snap manifest's JSON shape"

contains "$out2" "etc: nothing declared" ||
  fail "second switch: etc domain should STILL be reported as skipped -- got: $out2 -- BUG: the old snap ref was misfed to the etc domain as its old ref instead of vanishing into DOM_OLD_ETC_REF's rightful emptiness"

contains "$out2" "snap: 0 action(s) touched" ||
  fail "second switch: an unchanged declared snap set must plan ZERO actions, got: $out2 -- BUG: the old snap manifest ref came out empty (collapsed into the etc ref instead), so the planner saw hello-world as never-installed and re-planned ack+install"

calls_after_second="$(wc -l < "$snap_cmd_log")"
new_calls="$((calls_after_second - calls_after_first))"
if [ "$new_calls" -ne 0 ]; then
  fail "second switch (no manifest change) issued $new_calls NEW snap-cmd call(s) -- a snap was re-sideloaded on a no-op reconverge (see snap-cmd.log): $(tail -n "$new_calls" "$snap_cmd_log")"
fi

exit "$fails"
