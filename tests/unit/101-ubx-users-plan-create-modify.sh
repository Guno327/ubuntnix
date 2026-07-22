#!/usr/bin/env bash
# tests/unit/101-ubx-users-plan-create-modify.sh — bin/ubx-users' `plan`
# convergence decisions for the user create/modify matrix, uid allocation,
# uid-conflict detection, and machine-local exceptions (SPEC.md §4.3
# "Users", §4.2 "machine-local mutable exceptions"; GitHub issue #28,
# milestone M2).
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

base_group="$work/group"
cat > "$base_group" << 'EOF'
root:x:0:
EOF
base_shadow="$work/shadow"
cat > "$base_shadow" << 'EOF'
root:*:19000:0:99999:7:::
EOF

plan_of() {
  # plan_of NAME MANIFEST_JSON PASSWD_JSON [extra ubx-users args...] --
  # writes $work/$NAME.json, returns ubx-users' own exit code.
  local name="$1" manifest_file="$work/$1-manifest.json" passwd_file="$work/$1-passwd"
  shift
  printf '%s' "$1" > "$manifest_file"
  shift
  printf '%s' "$1" > "$passwd_file"
  shift
  "$ubx_users" plan --manifest "$manifest_file" --passwd "$passwd_file" \
    --group "$base_group" --shadow "$base_shadow" --out "$work/$name.json" "$@"
}

assert_py() {
  # assert_py DESC PLAN_NAME PYTHON_SNIPPET (reads plan into `plan`)
  local desc="$1" name="$2" snippet="$3"
  if ! python3 -c "
import json, sys
plan = json.load(open(sys.argv[1]))
$snippet
" "$work/$name.json"; then
    fail "$desc"
  fi
}

# -- create: normal user, uid auto-allocated from the normal range
# (1000-59999), home/shell defaulted.
rc=0
plan_of create_default '{
  "version": 1,
  "users": [ { "name": "alice", "uid": null, "system": false, "shell": "/usr/bin/bash",
    "home": null, "createHome": true, "groups": [], "authorizedKeys": [] } ],
  "groups": []
}' 'root:x:0:0:root:/root:/bin/bash
' || rc=$?
[ "$rc" -eq 0 ] || fail "create_default: expected exit 0, got $rc"
assert_py "create_default: uid auto-allocated in the normal range, home defaulted" create_default '
c = plan["users"]["create"]
assert len(c) == 1, c
u = c[0]
assert u["name"] == "alice"
assert 1000 <= u["uid"] <= 59999, u
assert u["home"] == "/home/alice", u
assert u["createHome"] is True
'

# -- create: system user, uid auto-allocated from the system range
# (100-999).
plan_of create_system '{
  "version": 1,
  "users": [ { "name": "svcacct", "uid": null, "system": true, "shell": "/usr/sbin/nologin",
    "home": "/var/lib/svcacct", "createHome": false, "groups": [], "authorizedKeys": [] } ],
  "groups": []
}' 'root:x:0:0:root:/root:/bin/bash
'
assert_py "create_system: uid auto-allocated in the system range" create_system '
c = plan["users"]["create"]
assert len(c) == 1, c
u = c[0]
assert 100 <= u["uid"] <= 999, u
assert u["createHome"] is False
assert u["home"] == "/var/lib/svcacct"
'

# -- create: explicit uid honored verbatim, no conflict.
plan_of create_explicit '{
  "version": 1,
  "users": [ { "name": "bob", "uid": 5555, "system": false, "shell": "/usr/bin/bash",
    "home": null, "createHome": true, "groups": [], "authorizedKeys": [] } ],
  "groups": []
}' 'root:x:0:0:root:/root:/bin/bash
'
assert_py "create_explicit: declared uid honored verbatim" create_explicit '
u = plan["users"]["create"][0]
assert u["uid"] == 5555, u
'

# -- uid conflict on CREATE: declared uid already taken by a foreign
# (undeclared) observed user -> a hard error, not silent adoption.
rc=0
plan_of create_conflict '{
  "version": 1,
  "users": [ { "name": "carol", "uid": 42, "system": false, "shell": "/usr/bin/bash",
    "home": null, "createHome": true, "groups": [], "authorizedKeys": [] } ],
  "groups": []
}' 'root:x:0:0:root:/root:/bin/bash
someoneelse:x:42:42::/nonexistent:/usr/sbin/nologin
' || rc=$?
[ "$rc" -eq 1 ] || fail "create_conflict: expected exit 1 on a foreign uid conflict, got $rc"
assert_py "create_conflict: reported as an error, not adopted, and not created" create_conflict '
assert plan["users"]["create"] == [], plan["users"]["create"]
assert any("42" in e and "someoneelse" in e for e in plan["errors"]), plan["errors"]
'

# -- modify: an existing declared user whose observed shell/home differ
# from declared gets a modify entry naming exactly the changed fields.
plan_of modify_fields '{
  "version": 1,
  "users": [ { "name": "dave", "uid": null, "system": false, "shell": "/usr/bin/zsh",
    "home": "/home/dave", "createHome": true, "groups": [], "authorizedKeys": [] } ],
  "groups": []
}' 'root:x:0:0:root:/root:/bin/bash
dave:x:2000:2000:dave:/home/dave-old:/bin/bash
'
assert_py "modify_fields: shell and home changes reported, uid untouched (no explicit uid declared)" modify_fields '
m = plan["users"]["modify"]
assert len(m) == 1, m
changes = m[0]["changes"]
assert changes["shell"] == {"from": "/bin/bash", "to": "/usr/bin/zsh"}, changes
assert changes["home"] == {"from": "/home/dave-old", "to": "/home/dave"}, changes
assert "uid" not in changes, changes
assert plan["users"]["create"] == []
'

# -- uid conflict on MODIFY: an existing declared user's explicit target
# uid collides with a different, foreign observed user -> error, no change
# planned.
rc=0
plan_of modify_conflict '{
  "version": 1,
  "users": [ { "name": "erin", "uid": 43, "system": false, "shell": "/usr/bin/bash",
    "home": null, "createHome": true, "groups": [], "authorizedKeys": [] } ],
  "groups": []
}' 'root:x:0:0:root:/root:/bin/bash
erin:x:2001:2001:erin:/home/erin:/usr/bin/bash
foreignholder:x:43:43::/nonexistent:/usr/sbin/nologin
' || rc=$?
[ "$rc" -eq 1 ] || fail "modify_conflict: expected exit 1, got $rc"
assert_py "modify_conflict: reported as an error, uid change not planned" modify_conflict '
assert plan["users"]["modify"] == [], plan["users"]["modify"]
assert any("43" in e and "foreignholder" in e for e in plan["errors"]), plan["errors"]
'

# -- an already-converged user (no differences at all) yields no plan
# entries for it.
plan_of noop_user '{
  "version": 1,
  "users": [ { "name": "frank", "uid": 3000, "system": false, "shell": "/usr/bin/bash",
    "home": "/home/frank", "createHome": true, "groups": [], "authorizedKeys": [] } ],
  "groups": []
}' 'root:x:0:0:root:/root:/bin/bash
frank:x:3000:3000:frank:/home/frank:/usr/bin/bash
'
assert_py "noop_user: fully converged user produces no plan entries" noop_user '
assert plan["users"]["create"] == []
assert plan["users"]["modify"] == []
assert plan["empty"] is True, plan
'

# -- machine-local exceptions: a listed field is left alone even though it
# disagrees with the declared value.
plan_of exceptions_shell '{
  "version": 1,
  "users": [ { "name": "gina", "uid": null, "system": false, "shell": "/usr/bin/zsh",
    "home": null, "createHome": true, "groups": [], "authorizedKeys": [] } ],
  "groups": []
}' 'root:x:0:0:root:/root:/bin/bash
gina:x:4000:4000:gina:/home/gina:/bin/fish
' --exceptions <(echo '{"gina": ["shell"]}')
assert_py "exceptions: excepted field is not planned for modification" exceptions_shell '
assert plan["users"]["modify"] == [], plan["users"]["modify"]
assert plan["empty"] is True, plan
'

exit "$fails"
