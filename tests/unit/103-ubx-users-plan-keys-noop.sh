#!/usr/bin/env bash
# tests/unit/103-ubx-users-plan-keys-noop.sh — bin/ubx-users' `plan`
# authorizedKeys materialization plan, and the full no-op acceptance case
# (an already-converged fixture across users, groups, membership, AND
# authorizedKeys produces an empty plan, exit 0) (SPEC.md §4.3 "Users";
# GitHub issue #28, milestone M2).
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

ubx_users="$UBX_REPO_ROOT/bin/ubx-users"
[ -x "$ubx_users" ] || {
  echo "FAIL: $ubx_users does not exist or is not executable" >&2
  exit 1
}

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

manifest="$work/manifest.json"
cat > "$manifest" << 'EOF'
{
  "version": 1,
  "users": [
    { "name": "gunnar", "uid": 1000, "system": false, "shell": "/usr/bin/bash",
      "home": "/home/gunnar", "createHome": true, "groups": ["sudo"],
      "authorizedKeys": [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICLoremIpsumExampleKeyOnly gunnar@laptop"
      ] }
  ],
  "groups": []
}
EOF
passwd="$work/passwd"
cat > "$passwd" << 'EOF'
root:x:0:0:root:/root:/bin/bash
gunnar:x:1000:1000:gunnar:/home/gunnar:/usr/bin/bash
EOF
group="$work/group"
cat > "$group" << 'EOF'
root:x:0:
sudo:x:27:gunnar
EOF
shadow="$work/shadow"
cat > "$shadow" << 'EOF'
root:*:19000:0:99999:7:::
gunnar:!:19000:0:99999:7:::
EOF

# -- with no --home-state given (nothing observed), the declared key must
# be planned for materialization.
plan_no_home_state="$work/plan_no_home_state.json"
"$ubx_users" plan --manifest "$manifest" --passwd "$passwd" --group "$group" \
  --shadow "$shadow" --out "$plan_no_home_state"
python3 -c "
import json, sys
plan = json.load(open(sys.argv[1]))
ak = plan['authorized_keys']
assert len(ak) == 1, ak
entry = ak[0]
assert entry['user'] == 'gunnar', entry
assert entry['dir'] == '/home/gunnar/.ssh', entry
assert entry['path'] == '/home/gunnar/.ssh/authorized_keys', entry
assert entry['dir_mode'] == '0700', entry
assert entry['file_mode'] == '0600', entry
assert entry['keys'] == [
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICLoremIpsumExampleKeyOnly gunnar@laptop'
], entry
assert plan['empty'] is False, plan
" "$plan_no_home_state" || fail "authorizedKeys plan entry missing/incorrect when nothing observed"

# -- with --home-state reporting the SAME content already in place, no
# authorized_keys plan entry is emitted (idempotent).
home_state_match="$work/home_state_match.json"
cat > "$home_state_match" << 'EOF'
{
  "gunnar": [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICLoremIpsumExampleKeyOnly gunnar@laptop"
  ]
}
EOF
plan_match="$work/plan_match.json"
"$ubx_users" plan --manifest "$manifest" --passwd "$passwd" --group "$group" \
  --shadow "$shadow" --home-state "$home_state_match" --out "$plan_match"
python3 -c "
import json, sys
plan = json.load(open(sys.argv[1]))
assert plan['authorized_keys'] == [], plan['authorized_keys']
# This fixture is fully converged in every other respect too (users,
# groups, membership) -- the acceptance case: an already-converged
# fixture produces a wholly empty plan and exit 0 (checked below via the
# process's own exit code).
assert plan['empty'] is True, plan
assert plan['users']['create'] == [] and plan['users']['modify'] == [], plan
assert plan['groups']['create'] == [], plan
assert plan['membership']['add'] == [] and plan['membership']['remove'] == [], plan
assert plan['drift'] == [], plan
assert plan['errors'] == [], plan
" "$plan_match"
rc=$?
[ "$rc" -eq 0 ] || fail "already-converged fixture (including authorizedKeys): python assertions failed, rc=$rc"

rc=0
"$ubx_users" plan --manifest "$manifest" --passwd "$passwd" --group "$group" \
  --shadow "$shadow" --home-state "$home_state_match" > /dev/null || rc=$?
[ "$rc" -eq 0 ] || fail "already-converged fixture must exit 0, got $rc"

# -- with --home-state reporting DIFFERENT content, a materialization
# entry is still planned (content, not just presence, is compared).
home_state_stale="$work/home_state_stale.json"
cat > "$home_state_stale" << 'EOF'
{ "gunnar": ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC0lddifferentkeyvalue old@machine"] }
EOF
plan_stale="$work/plan_stale.json"
"$ubx_users" plan --manifest "$manifest" --passwd "$passwd" --group "$group" \
  --shadow "$shadow" --home-state "$home_state_stale" --out "$plan_stale"
python3 -c "
import json, sys
plan = json.load(open(sys.argv[1]))
assert len(plan['authorized_keys']) == 1, plan['authorized_keys']
" "$plan_stale" || fail "stale observed authorizedKeys content did not trigger a re-materialization plan"

# -- a user with no declared authorizedKeys at all never gets a plan
# entry, regardless of home-state.
manifest_no_keys="$work/manifest_no_keys.json"
cat > "$manifest_no_keys" << 'EOF'
{
  "version": 1,
  "users": [
    { "name": "nokeys", "uid": 1001, "system": false, "shell": "/usr/bin/bash",
      "home": "/home/nokeys", "createHome": true, "groups": [], "authorizedKeys": [] }
  ],
  "groups": []
}
EOF
passwd_no_keys="$work/passwd_no_keys"
cat > "$passwd_no_keys" << 'EOF'
root:x:0:0:root:/root:/bin/bash
nokeys:x:1001:1001:nokeys:/home/nokeys:/usr/bin/bash
EOF
plan_no_keys="$work/plan_no_keys.json"
"$ubx_users" plan --manifest "$manifest_no_keys" --passwd "$passwd_no_keys" \
  --group "$group" --shadow "$shadow" --out "$plan_no_keys"
python3 -c "
import json, sys
plan = json.load(open(sys.argv[1]))
assert plan['authorized_keys'] == [], plan['authorized_keys']
assert plan['empty'] is True, plan
" "$plan_no_keys" || fail "a user with no declared authorizedKeys must never get a plan entry"

exit "$fails"
