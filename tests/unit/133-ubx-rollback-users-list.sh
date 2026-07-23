#!/usr/bin/env bash
# tests/unit/133-ubx-rollback-users-list.sh — `ubx rollback`'s domain
# re-convergence (using generation N's retained manifests, resolved via
# `ubx-generations rollback-target`), `ubx list-generations`'s pass-through,
# and the users domain end-to-end through the orchestrator (SPEC.md §4.3;
# GitHub issue #29, milestone M2). No root, no network, no live systemd.
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

# =====================================================================
# list-generations: wraps 'ubx-generations list' faithfully, including
# --porcelain.
# =====================================================================
"$ubx" rebuild switch --root "$root" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --title "first" > /dev/null || fail "setup: switch (gen1) failed"
"$ubx" rebuild switch --root "$root" \
  --rootfs-image /store/r2 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --title "second" > /dev/null || fail "setup: switch (gen2) failed"

out="$("$ubx" list-generations --root "$root")"
contains "$out" "first" || fail "list-generations should show generation 1's title, got: $out"
contains "$out" "second" || fail "list-generations should show generation 2's title, got: $out"
contains "$out" "(current)" || fail "list-generations human table should mark the current generation, got: $out"

porcelain="$("$ubx" list-generations --root "$root" --porcelain)"
line1="$(printf '%s\n' "$porcelain" | awk -F'\t' '$1==1')"
[ -n "$line1" ] || fail "list-generations --porcelain should include a line for generation 1"
case "$line1" in
  *$'\t'first$'\t'*) ;;
  *) fail "list-generations --porcelain gen1 line should carry the title 'first', got: $line1" ;;
esac

# =====================================================================
# users domain end-to-end: plan + a generated (never-run) activation
# script, exactly matching bin/ubx-users' own "execute only ever emits"
# scope.
# =====================================================================
passwd="$work/passwd"
group="$work/group"
shadow="$work/shadow"
printf 'root:x:0:0:root:/root:/bin/bash\n' > "$passwd"
printf 'root:x:0:\n' > "$group"
printf 'root:!:19000:0:99999:7:::\n' > "$shadow"

users_manifest="$work/users.json"
cat > "$users_manifest" <<'EOF'
{"version": 1, "users": [
  {"name": "alice", "uid": null, "system": false, "shell": "/bin/bash", "home": null,
   "createHome": true, "groups": [], "authorizedKeys": []}
], "groups": []}
EOF

users_root="$work/gens-users"
users_script="$work/users-activate.sh"
out="$("$ubx" rebuild switch --root "$users_root" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --users-manifest "$users_manifest" --passwd "$passwd" --group "$group" --shadow "$shadow" \
  --users-out "$users_script" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "switch with a users manifest should succeed, got rc=$rc: $out"
contains "$out" "users: 1 action(s) touched" || fail "switch should report 1 users action (create alice), got: $out"
[ -f "$users_script" ] || fail "the users activation script should have been written to $users_script"
contains "$(cat "$users_script")" "useradd" || fail "the generated users script should contain a useradd command"
# passwd/group/shadow fixtures must be untouched -- ubx-users execute only
# ever emits a script, per its own header; this orchestrator must not run it.
grep -q alice "$passwd" && fail "the real passwd fixture must NOT have been modified (execute never runs anything)"

# =====================================================================
# rollback re-converges using the TARGET generation's retained
# manifests, not the booted one's.
# =====================================================================
etc_v1="$work/etc-v1.json"
etc_v2="$work/etc-v2.json"
cat > "$etc_v1" <<'EOF'
{"version": 1, "entries": [{"path": "hostname", "sha256": "v1hash", "owner": "root", "group": "root", "mode": "0644"}]}
EOF
cat > "$etc_v2" <<'EOF'
{"version": 1, "entries": [{"path": "hostname", "sha256": "v2hash", "owner": "root", "group": "root", "mode": "0644"}]}
EOF

rb_root="$work/gens-rb2"
"$ubx" rebuild switch --root "$rb_root" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --etc-ref "$etc_v1" > /dev/null || fail "rollback setup: switch (gen1, etc v1) failed"
"$ubx" rebuild switch --root "$rb_root" \
  --rootfs-image /store/r2 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --etc-ref "$etc_v2" > /dev/null || fail "rollback setup: switch (gen2, etc v2) failed"

out="$("$ubx" rollback --root "$rb_root" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "rollback to previous (gen1) should succeed, got rc=$rc: $out"
contains "$out" "generation 2 -> 1" || fail "rollback report should say '2 -> 1', got: $out"
contains "$out" "etc: 1 action(s) touched" || fail "rolling back from etc v2 to v1 (differing hostname content) should report 1 etc action touched, got: $out"

# an explicit numeric target also works.
out2="$("$ubx" rollback 1 --root "$rb_root" 2>&1)"
rc2=$?
[ "$rc2" -eq 0 ] || fail "'rollback 1' (explicit target) should succeed, got: $out2"

# rolling back to a nonexistent generation is refused, propagating
# ubx-generations rollback-target's own error.
out3="$("$ubx" rollback 999 --root "$rb_root" 2>&1)"
rc3=$?
[ "$rc3" -ne 0 ] || fail "'rollback 999' (nonexistent generation) should fail, got: $out3"

exit "$fails"
