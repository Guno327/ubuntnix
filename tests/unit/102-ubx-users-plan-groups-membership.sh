#!/usr/bin/env bash
# tests/unit/102-ubx-users-plan-groups-membership.sh — bin/ubx-users' `plan`
# group creation, supplementary-group membership add/remove, gid-conflict
# detection, and drift-report entries for anomalies strictly within the
# managed domain (SPEC.md §4.3 "Users", §7 "Drift prevention"; GitHub
# issue #28, milestone M2).
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

base_shadow="$work/shadow"
cat > "$base_shadow" << 'EOF'
root:*:19000:0:99999:7:::
gunnar:!:19000:0:99999:7:::
EOF

plan_of() {
  # plan_of NAME MANIFEST_JSON PASSWD_TEXT GROUP_TEXT -- writes
  # $work/$NAME.json; returns ubx-users' own exit code.
  local name="$1" manifest_file="$work/$1-manifest.json" \
    passwd_file="$work/$1-passwd" group_file="$work/$1-group"
  shift
  printf '%s' "$1" > "$manifest_file"
  shift
  printf '%s' "$1" > "$passwd_file"
  shift
  printf '%s' "$1" > "$group_file"
  shift
  "$ubx_users" plan --manifest "$manifest_file" --passwd "$passwd_file" \
    --group "$group_file" --shadow "$base_shadow" --out "$work/$name.json" "$@"
}

assert_py() {
  local desc="$1" name="$2" snippet="$3"
  if ! python3 -c "
import json, sys
plan = json.load(open(sys.argv[1]))
$snippet
" "$work/$name.json"; then
    fail "$desc"
  fi
}

gunnar_passwd='root:x:0:0:root:/root:/bin/bash
gunnar:x:1000:1000:gunnar:/home/gunnar:/usr/bin/bash
'
gunnar_manifest_fn() {
  # gunnar_manifest_fn GROUPS_JSON_ARRAY -> a manifest JSON declaring
  # gunnar with the given supplementary groups.
  printf '{
  "version": 1,
  "users": [ { "name": "gunnar", "uid": 1000, "system": false, "shell": "/usr/bin/bash",
    "home": "/home/gunnar", "createHome": true, "groups": %s, "authorizedKeys": [] } ],
  "groups": []
}' "$1"
}

# -- group creation: a group only IMPLIED by a user's `groups` list (not
# separately declared under manifest "groups") that does not yet exist
# observed gets planned for creation, with an auto-allocated gid.
plan_of implied_group_create "$(gunnar_manifest_fn '["docker"]')" "$gunnar_passwd" 'root:x:0:
'
assert_py "implied group create: 'docker' planned with an auto gid in the normal range" implied_group_create '
c = plan["groups"]["create"]
assert len(c) == 1, c
assert c[0]["name"] == "docker", c
assert 1000 <= c[0]["gid"] <= 59999, c
'

# -- group creation: an already-observed group (even if only referenced,
# never separately declared) needs no create action.
plan_of existing_group_noop "$(gunnar_manifest_fn '["sudo"]')" "$gunnar_passwd" 'root:x:0:
sudo:x:27:gunnar
'
assert_py "existing group: already-present 'sudo' is not re-planned for creation" existing_group_noop '
assert plan["groups"]["create"] == [], plan["groups"]["create"]
assert plan["empty"] is True, plan
'

# -- gid conflict: a standalone-declared group's explicit gid is already
# used by a DIFFERENT, foreign observed group -> a hard error.
manifest_gid_conflict='{
  "version": 1,
  "users": [],
  "groups": [ { "name": "custom", "gid": 27, "system": false } ]
}'
rc=0
plan_of gid_conflict "$manifest_gid_conflict" 'root:x:0:0:root:/root:/bin/bash
' 'root:x:0:
sudo:x:27:
' || rc=$?
[ "$rc" -eq 1 ] || fail "gid_conflict: expected exit 1, got $rc"
assert_py "gid_conflict: reported as an error, not created" gid_conflict '
assert plan["groups"]["create"] == [], plan["groups"]["create"]
assert any("27" in e and "custom" in e for e in plan["errors"]), plan["errors"]
'

# -- membership add: gunnar declared in "sudo" but not observed as a
# member yet.
plan_of membership_add "$(gunnar_manifest_fn '["sudo"]')" "$gunnar_passwd" 'root:x:0:
sudo:x:27:
'
assert_py "membership add: gunnar planned to join 'sudo'" membership_add '
add = plan["membership"]["add"]
assert add == [{"user": "gunnar", "group": "sudo"}], add
assert plan["membership"]["remove"] == []
'

# -- membership remove: gunnar observed as a member of a group not in the
# declared list.
plan_of membership_remove "$(gunnar_manifest_fn '[]')" "$gunnar_passwd" 'root:x:0:
sudo:x:27:gunnar
'
assert_py "membership remove: gunnar planned to leave 'sudo'" membership_remove '
rem = plan["membership"]["remove"]
assert rem == [{"user": "gunnar", "group": "sudo"}], rem
assert plan["membership"]["add"] == []
'

# -- membership add+remove together, sorted deterministically.
plan_of membership_both "$(gunnar_manifest_fn '["docker"]')" "$gunnar_passwd" 'root:x:0:
docker:x:2000:
sudo:x:27:gunnar
'
assert_py "membership add+remove: both directions planned, sorted by (group, user)" membership_both '
assert plan["membership"]["add"] == [{"user": "gunnar", "group": "docker"}], plan["membership"]["add"]
assert plan["membership"]["remove"] == [{"user": "gunnar", "group": "sudo"}], plan["membership"]["remove"]
'

# -- machine-local exceptions: "groups" excepted for a user skips its
# entire membership diff.
plan_of membership_excepted "$(gunnar_manifest_fn '["docker"]')" "$gunnar_passwd" 'root:x:0:
docker:x:2000:
sudo:x:27:gunnar
' --exceptions <(echo '{"gunnar": ["groups"]}')
assert_py "membership excepted: no add/remove planned for gunnar" membership_excepted '
assert plan["membership"]["add"] == [], plan["membership"]["add"]
assert plan["membership"]["remove"] == [], plan["membership"]["remove"]
'

# -- drift: a MANAGED (required) group has a foreign (non-declared)
# member. Never planned for removal -- only reported.
plan_of drift_foreign_member "$(gunnar_manifest_fn '["sudo"]')" "$gunnar_passwd" 'root:x:0:
sudo:x:27:gunnar,someoneelse
'
assert_py "drift: foreign member of a managed group is reported, not removed" drift_foreign_member '
drift = plan["drift"]
assert {"kind": "undeclared_group_member", "group": "sudo", "user": "someoneelse"} in drift, drift
assert plan["membership"]["remove"] == [], plan["membership"]["remove"]
'

# -- drift: a required group already exists with a gid that disagrees with
# an EXPLICIT declared gid. Reported, not auto-modified (gid changes are
# out of scope -- see bin/ubx-users' own header).
manifest_gid_mismatch='{
  "version": 1,
  "users": [],
  "groups": [ { "name": "custom", "gid": 3000, "system": false } ]
}'
plan_of drift_gid_mismatch "$manifest_gid_mismatch" 'root:x:0:0:root:/root:/bin/bash
' 'root:x:0:
custom:x:3001:
'
assert_py "drift: group gid mismatch reported, not silently changed" drift_gid_mismatch '
drift = plan["drift"]
assert {"kind": "group_gid_mismatch", "group": "custom", "declared_gid": 3000, "observed_gid": 3001} in drift, drift
assert plan["groups"]["create"] == [], plan["groups"]["create"]
'

# -- an undeclared (non-required) group with unrelated members is NEVER
# looked at at all -- not drift, not touched. "adm" here is a stand-in for
# an ordinary base-system group nobody declared and no declared user
# references.
plan_of unmanaged_group_ignored "$(gunnar_manifest_fn '[]')" "$gunnar_passwd" 'root:x:0:
adm:x:4:someoneelse,anotherperson
'
assert_py "unmanaged group: not reported, not touched" unmanaged_group_ignored '
assert plan["drift"] == [], plan["drift"]
assert plan["groups"]["create"] == [], plan["groups"]["create"]
assert plan["empty"] is True, plan
'

exit "$fails"
