#!/usr/bin/env bash
# tests/unit/183-home-plan.sh — `ubx-home plan`'s diff/activation algorithm
# across files AND per-user systemd --user services (SPEC.md §9, §4.3;
# GitHub issue #98, milestone M5).
#
# Every fixture manifest here is hand-crafted directly in bin/ubx-home's
# own manifest schema (see that script's header) -- no `nix` binary or
# real filesystem access is needed to exercise `plan` itself.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

home="$UBX_REPO_ROOT/bin/ubx-home"
[ -x "$home" ] || { echo "FAIL: $home does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

sha_a="$(printf 'content-a' | sha256sum | cut -d' ' -f1)"
sha_b1="$(printf 'content-b1' | sha256sum | cut -d' ' -f1)"
sha_b2="$(printf 'content-b2' | sha256sum | cut -d' ' -f1)"
sha_c="$(printf 'content-c' | sha256sum | cut -d' ' -f1)"
sha_d="$(printf 'content-d' | sha256sum | cut -d' ' -f1)"
sha_f="$(printf 'content-f' | sha256sum | cut -d' ' -f1)"
sha_svc1="$(printf 'unit-v1' | sha256sum | cut -d' ' -f1)"
sha_svc2="$(printf 'unit-v2' | sha256sum | cut -d' ' -f1)"

# =====================================================================
# Test 1: files -- create/update-content/update-metadata/remove/no-op/drift,
# scoped to user "gunnar" -- mirrors tests/unit/113-etc-plan.sh's own shape.
# =====================================================================
old="$work/old1.json"
cat > "$old" <<EOF
{"version": 1, "users": [
  {"name": "gunnar", "files": [
    {"path": "a", "sha256": "$sha_a", "mode": "0644"},
    {"path": "b", "sha256": "$sha_b1", "mode": "0644"},
    {"path": "c", "sha256": "$sha_c", "mode": "0644"}
  ], "services": []}
]}
EOF

new="$work/new1.json"
cat > "$new" <<EOF
{"version": 1, "users": [
  {"name": "gunnar", "files": [
    {"path": "a", "sha256": "$sha_a", "mode": "0644"},
    {"path": "b", "sha256": "$sha_b2", "mode": "0644"},
    {"path": "d", "sha256": "$sha_d", "mode": "0640"}
  ], "services": []}
]}
EOF

observed="$work/observed1.json"
cat > "$observed" <<EOF
{"version": 1, "users": [
  {"name": "gunnar", "files": [
    {"path": "a", "sha256": "$sha_a", "mode": "0644"},
    {"path": "b", "sha256": "$sha_b1", "mode": "0644"},
    {"path": "c", "sha256": "$sha_c", "mode": "0644"},
    {"path": "f", "sha256": "$sha_f", "mode": "0644"}
  ], "services": []}
]}
EOF

plan1="$work/plan1.json"
"$home" plan --old-manifest "$old" --new-manifest "$new" --observed-manifest "$observed" --out "$plan1" \
  || fail "test 1: plan should succeed"

ops="$(python3 -c "
import json
p = json.load(open('$plan1'))
for a in p['actions']:
    print(a['op'], a.get('path', a.get('service', '')), a.get('action', ''))
")"

echo "$ops" | grep -qE '^install-file a create$' && fail "test 1: 'a' is converged, should not appear"
echo "$ops" | grep -qE '^install-file b update-content$' || fail "test 1: expected install-file b update-content, got: $ops"
echo "$ops" | grep -qE '^install-file d create$' || fail "test 1: expected install-file d create, got: $ops"
echo "$ops" | grep -qE '^remove-file c $' || fail "test 1: expected remove-file c, got: $ops"
echo "$ops" | grep -qE '^drift-file f $' || fail "test 1: expected drift-file f, got: $ops"

# =====================================================================
# Test 2: services -- create (start), update-content (restart), remove,
# enable/disable, mask -- mirrors tests/unit/120-systemd-plan-basic.sh's
# shape, scoped per user, with no refuse-restart branch at all (home
# only ever declares restart-safe classes).
# =====================================================================
old2="$work/old2.json"
cat > "$old2" <<EOF
{"version": 1, "users": [
  {"name": "gunnar", "files": [], "services": [
    {"name": "keep.service", "class": "service", "sha256": "$sha_svc1", "enable": true, "mask": false},
    {"name": "drop.service", "class": "service", "sha256": "$sha_svc1", "enable": true, "mask": false}
  ]}
]}
EOF

new2="$work/new2.json"
cat > "$new2" <<EOF
{"version": 1, "users": [
  {"name": "gunnar", "files": [], "services": [
    {"name": "keep.service", "class": "service", "sha256": "$sha_svc2", "enable": true, "mask": false},
    {"name": "fresh.timer", "class": "timer", "sha256": "$sha_svc1", "enable": true, "mask": false}
  ]}
]}
EOF

observed2="$work/observed2.json"
cat > "$observed2" <<EOF
{"version": 1, "users": [
  {"name": "gunnar", "files": [], "services": [
    {"name": "keep.service", "sha256": "$sha_svc1", "enabled": true, "masked": false, "active": true},
    {"name": "drop.service", "sha256": "$sha_svc1", "enabled": true, "masked": false, "active": true}
  ]}
]}
EOF

plan2="$work/plan2.json"
"$home" plan --old-manifest "$old2" --new-manifest "$new2" --observed-manifest "$observed2" --out "$plan2" \
  || fail "test 2: plan should succeed"

svc_ops="$(python3 -c "
import json
p = json.load(open('$plan2'))
for a in p['actions']:
    print(a['op'], a.get('service', ''), a.get('action', ''))
")"

echo "$svc_ops" | grep -qE '^write-service-file keep.service update-content$' || fail "test 2: expected write-service-file keep.service update-content, got: $svc_ops"
echo "$svc_ops" | grep -qE '^write-service-file fresh.timer create$' || fail "test 2: expected write-service-file fresh.timer create, got: $svc_ops"
echo "$svc_ops" | grep -qE '^remove-service-file drop.service $' || fail "test 2: expected remove-service-file drop.service, got: $svc_ops"
echo "$svc_ops" | grep -qE '^daemon-reload  $' || fail "test 2: expected exactly one daemon-reload, got: $svc_ops"
echo "$svc_ops" | grep -qE '^stop drop.service $' || fail "test 2: expected stop drop.service, got: $svc_ops"
echo "$svc_ops" | grep -qE '^disable drop.service $' || fail "test 2: expected disable drop.service, got: $svc_ops"
echo "$svc_ops" | grep -qE '^restart keep.service $' || fail "test 2: expected restart keep.service (pre-existing content change, active), got: $svc_ops"
echo "$svc_ops" | grep -qE '^start fresh.timer $' || fail "test 2: expected start fresh.timer (newly created, enabled), got: $svc_ops"

daemon_reload_count="$(echo "$svc_ops" | grep -cE '^daemon-reload')"
[ "$daemon_reload_count" -eq 1 ] || fail "test 2: expected exactly 1 daemon-reload action, got $daemon_reload_count"

# =====================================================================
# Test 3: multi-user -- actions for two users must both appear, each
# correctly scoped by "user" field, sorted by username.
# =====================================================================
old3="$work/old3.json"
cat > "$old3" <<'EOF'
{"version": 1, "users": []}
EOF

new3="$work/new3.json"
cat > "$new3" <<EOF
{"version": 1, "users": [
  {"name": "zed", "files": [{"path": "x", "sha256": "$sha_a", "mode": "0644"}], "services": []},
  {"name": "alice", "files": [{"path": "y", "sha256": "$sha_a", "mode": "0644"}], "services": []}
]}
EOF

observed3="$work/observed3.json"
cat > "$observed3" <<'EOF'
{"version": 1, "users": []}
EOF

plan3="$work/plan3.json"
"$home" plan --old-manifest "$old3" --new-manifest "$new3" --observed-manifest "$observed3" --out "$plan3" \
  || fail "test 3: plan should succeed"

users_order="$(python3 -c "
import json
p = json.load(open('$plan3'))
print(' '.join(a['user'] for a in p['actions']))
")"
[ "$users_order" = "alice zed" ] || fail "test 3: expected users in sorted order (alice zed), got: $users_order"

# =====================================================================
# Test 4: fully converged input produces zero actions, exit 0.
# =====================================================================
conv="$work/converged.json"
cat > "$conv" <<EOF
{"version": 1, "users": [
  {"name": "gunnar", "files": [{"path": "a", "sha256": "$sha_a", "mode": "0644"}],
   "services": [{"name": "keep.service", "class": "service", "sha256": "$sha_svc1", "enable": true, "mask": false}]}
]}
EOF
conv_obs="$work/converged-observed.json"
cat > "$conv_obs" <<EOF
{"version": 1, "users": [
  {"name": "gunnar", "files": [{"path": "a", "sha256": "$sha_a", "mode": "0644"}],
   "services": [{"name": "keep.service", "sha256": "$sha_svc1", "enabled": true, "masked": false, "active": true}]}
]}
EOF
plan4="$work/plan4.json"
"$home" plan --old-manifest "$conv" --new-manifest "$conv" --observed-manifest "$conv_obs" --out "$plan4" \
  || fail "test 4: plan should succeed"
action_count="$(python3 -c "import json; print(len(json.load(open('$plan4'))['actions']))")"
[ "$action_count" -eq 0 ] || fail "test 4: fully converged input should produce zero actions, got $action_count"

exit "$fails"
