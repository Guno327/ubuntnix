#!/usr/bin/env bash
# tests/unit/131-ubx-rebuild-dry-run-planning.sh — `ubx rebuild --dry-run`
# and `ubx diff`: given fixture old/new generation domain manifests, the
# orchestrator must report exactly the set of touched domains, with no
# root, no live systemd, and no mutation of the generations root at all
# (SPEC.md §4.3, §7; GitHub issue #29, milestone M2).
set -u

ubx="$UBX_REPO_ROOT/bin/ubx"
[ -x "$ubx" ] || { echo "FAIL: $ubx does not exist or is not executable" >&2; exit 1; }

fails=0
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

root="$work/gens"

etc_a="$work/etc-a.json"
etc_b="$work/etc-b.json"
cat > "$etc_a" <<'EOF'
{"version": 1, "entries": [
  {"path": "hostname", "sha256": "aaaa", "owner": "root", "group": "root", "mode": "0644"}
]}
EOF
cat > "$etc_b" <<'EOF'
{"version": 1, "entries": [
  {"path": "hostname", "sha256": "bbbb", "owner": "root", "group": "root", "mode": "0644"},
  {"path": "motd", "sha256": "cccc", "owner": "root", "group": "root", "mode": "0644"}
]}
EOF

systemd_a="$work/systemd-a.json"
systemd_b="$work/systemd-b.json"
cat > "$systemd_a" <<'EOF'
{"version": 1, "units": []}
EOF
cat > "$systemd_b" <<'EOF'
{"version": 1, "units": [
  {"name": "myapp.service", "class": "service", "refuseRestart": false, "hasContent": true, "sha256": "sha-1", "enable": true, "mask": false}
]}
EOF

# =====================================================================
# rebuild switch --dry-run: reports the correct touched-domain set from
# explicit --etc-ref/--systemd-ref fixtures, no generation ever created.
# =====================================================================
out="$("$ubx" rebuild switch --root "$root" --dry-run --etc-ref "$etc_b" --systemd-ref "$systemd_b" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "dry-run switch should exit 0, got $rc: $out"
[ ! -e "$root" ] || fail "dry-run must never create anything under --root"

contains "$out" "etc: 2 action(s) touched" || fail "dry-run should report 2 etc actions (create hostname is absent old -> create; motd -> create; both new against an empty old), got: $out"
contains "$out" "systemd: 4 action(s) touched" || fail "dry-run should report 4 systemd-domain actions (write-unit-file+daemon-reload+enable+start), got: $out"
contains "$out" "users: nothing declared" || fail "dry-run should report users as not declared (no ref given), got: $out"
contains "$out" "would" || fail "dry-run output should say what it WOULD do, got: $out"

# =====================================================================
# a real generation (gen1) declaring etc_a/systemd_a, then a dry-run
# rebuild against etc_b/systemd_b: touched counts reflect the delta from
# the ACTUAL current generation, not from nothing.
# =====================================================================
"$ubx" rebuild switch --root "$root" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --etc-ref "$etc_a" --systemd-ref "$systemd_a" > /dev/null \
  || fail "setting up gen1 (real, non-dry-run) failed"

out="$("$ubx" rebuild test --root "$root" --dry-run --etc-ref "$etc_b" --systemd-ref "$systemd_b" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "dry-run test against gen1 should exit 0, got $rc: $out"
contains "$out" "etc: 2 action(s) touched" || fail "dry-run test should show 2 etc actions (update hostname + create motd) against gen1, got: $out"
contains "$out" "systemd: 4 action(s) touched" || fail "dry-run test should show 4 systemd actions against gen1's empty unit set, got: $out"
# only gen1 should exist -- the dry-run above must not have registered
# another one.
gens="$(find "$root" -maxdepth 1 -mindepth 1 -type d -regex '.*/[0-9]+' -printf '%f\n' | sort -n | paste -sd, -)"
[ "$gens" = 1 ] || fail "only generation 1 should exist after a dry-run test, got: $gens"

# a dry-run against IDENTICAL etc/systemd refs is a true no-op (0 touched).
out="$("$ubx" rebuild switch --root "$root" --dry-run --etc-ref "$etc_a" --systemd-ref "$systemd_a" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "dry-run no-op switch should exit 0"
contains "$out" "etc: 0 action(s) touched" || fail "dry-run against an unchanged etc ref should report 0 touched, got: $out"
contains "$out" "systemd: 0 action(s) touched" || fail "dry-run against an unchanged systemd ref should report 0 touched, got: $out"

# =====================================================================
# `ubx diff` between two explicit generations: same domain-plan machinery,
# always read-only.
# =====================================================================
"$ubx" rebuild boot --root "$root" \
  --rootfs-image /store/r2 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --etc-ref "$etc_b" --systemd-ref "$systemd_b" > /dev/null \
  || fail "setting up gen2 (boot) failed"

out="$("$ubx" diff 1 2 --root "$root" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'diff 1 2' should exit 0, got $rc: $out"
contains "$out" "hostname" || fail "'diff 1 2' should mention the changed hostname path, got: $out"
contains "$out" "motd" || fail "'diff 1 2' should mention the newly-created motd path, got: $out"
contains "$out" "myapp.service" || fail "'diff 1 2' should mention the newly-declared systemd unit, got: $out"

# diff with no args defaults to previous -> current (gen1 -> gen2 here).
out_default="$("$ubx" diff --root "$root" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'diff' with no args should exit 0"
contains "$out_default" "generation 1 -> 2" || fail "'diff' with no args should default to previous->current (1 -> 2), got: $out_default"

exit "$fails"
