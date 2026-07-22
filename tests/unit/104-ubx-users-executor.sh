#!/usr/bin/env bash
# tests/unit/104-ubx-users-executor.sh — bin/ubx-users' `execute`: plan ->
# exact command sequence translation, kept separable from (and tested
# independently of) the planner (SPEC.md §4.3 "Users"; GitHub issue #28,
# milestone M2). Emission only -- see bin/ubx-users' own header for why
# `execute` never runs anything itself.
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

plan="$work/plan.json"
cat > "$plan" << 'EOF'
{
  "version": 1,
  "empty": false,
  "users": {
    "create": [
      { "name": "alice", "uid": 1000, "system": false, "shell": "/usr/bin/bash",
        "home": "/home/alice", "createHome": true, "groups": ["docker", "sudo"] }
    ],
    "modify": [
      { "name": "bob", "changes": {
          "shell": {"from": "/bin/sh", "to": "/usr/bin/bash"},
          "home": {"from": "/home/b", "to": "/home/bob"}
      } }
    ]
  },
  "groups": {
    "create": [ { "name": "docker", "gid": 2000, "system": false } ]
  },
  "membership": {
    "add": [ { "user": "carol", "group": "docker" } ],
    "remove": [ { "user": "carol", "group": "sudo" } ]
  },
  "authorized_keys": [
    { "user": "alice", "dir": "/home/alice/.ssh", "path": "/home/alice/.ssh/authorized_keys",
      "dir_mode": "0700", "file_mode": "0600",
      "keys": ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICLoremIpsum alice@laptop"] }
  ],
  "drift": [],
  "errors": []
}
EOF

# -- shell format: exact command sequence, in the documented order
# (groups.create, users.create, users.modify, membership.remove,
# membership.add, authorized_keys), each properly formed.
shell_out="$work/shell_out.sh"
"$ubx_users" execute --plan "$plan" --format shell --out "$shell_out"
[ -s "$shell_out" ] || fail "shell format: no output produced"

grep -qxF 'groupadd -g 2000 docker' "$shell_out" || fail "shell format: missing groupadd for docker"
grep -qxF 'useradd -u 1000 -m -d /home/alice -s /usr/bin/bash -G docker,sudo alice' "$shell_out" \
  || fail "shell format: missing/incorrect useradd for alice"
grep -qxF 'usermod -d /home/bob -s /usr/bin/bash bob' "$shell_out" \
  || fail "shell format: missing/incorrect usermod for bob"
grep -qxF 'gpasswd -d carol sudo' "$shell_out" || fail "shell format: missing membership removal"
grep -qxF 'gpasswd -a carol docker' "$shell_out" || fail "shell format: missing membership addition"
grep -qxF 'mkdir -p /home/alice/.ssh' "$shell_out" || fail "shell format: missing authorized_keys mkdir"
grep -qxF 'chmod 0700 /home/alice/.ssh' "$shell_out" || fail "shell format: missing .ssh chmod"
grep -qxF "chown alice:alice /home/alice/.ssh" "$shell_out" || fail "shell format: missing .ssh chown"
grep -q "^cat > /home/alice/.ssh/authorized_keys <<'" "$shell_out" \
  || fail "shell format: missing authorized_keys heredoc write (single-quoted delimiter)"
grep -qxF 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICLoremIpsum alice@laptop' "$shell_out" \
  || fail "shell format: authorized_keys content missing from heredoc body"
grep -qxF 'chmod 0600 /home/alice/.ssh/authorized_keys' "$shell_out" \
  || fail "shell format: missing authorized_keys file chmod"

# groupadd must precede useradd (a brand-new group a new user references
# has to exist before `useradd -G` can add them to it).
group_line=$(grep -n '^groupadd' "$shell_out" | head -1 | cut -d: -f1)
user_line=$(grep -n '^useradd' "$shell_out" | head -1 | cut -d: -f1)
[ -n "$group_line" ] && [ -n "$user_line" ] && [ "$group_line" -lt "$user_line" ] \
  || fail "shell format: groupadd must be emitted before useradd"

# -- ordering: membership removals precede additions (deterministic,
# always in this relative order).
remove_line=$(grep -n '^gpasswd -d' "$shell_out" | head -1 | cut -d: -f1)
add_line=$(grep -n '^gpasswd -a' "$shell_out" | head -1 | cut -d: -f1)
[ -n "$remove_line" ] && [ -n "$add_line" ] && [ "$remove_line" -lt "$add_line" ] \
  || fail "shell format: membership removals must precede additions"

# -- json format: structured steps, same content, machine-parseable.
json_out="$work/json_out.json"
"$ubx_users" execute --plan "$plan" --format json --out "$json_out"
python3 -c "
import json, sys
steps = json.load(open(sys.argv[1]))
assert isinstance(steps, list) and steps, steps
run_argvs = [s['argv'] for s in steps if s['op'] == 'run']
assert ['groupadd', '-g', '2000', 'docker'] in run_argvs, run_argvs
assert ['useradd', '-u', '1000', '-m', '-d', '/home/alice', '-s', '/usr/bin/bash', '-G', 'docker,sudo', 'alice'] in run_argvs, run_argvs
assert ['usermod', '-d', '/home/bob', '-s', '/usr/bin/bash', 'bob'] in run_argvs, run_argvs
assert ['gpasswd', '-a', 'carol', 'docker'] in run_argvs, run_argvs
assert ['gpasswd', '-d', 'carol', 'sudo'] in run_argvs, run_argvs
write_steps = [s for s in steps if s['op'] == 'write_file']
assert len(write_steps) == 1, write_steps
assert write_steps[0]['path'] == '/home/alice/.ssh/authorized_keys', write_steps[0]
assert write_steps[0]['content'] == 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICLoremIpsum alice@laptop\n', write_steps[0]
assert write_steps[0]['mode'] == '0600', write_steps[0]
" "$json_out" || fail "json format: structured steps missing/incorrect"

# -- determinism: two independent runs against the same plan produce
# byte-identical output, in both formats.
shell_out2="$work/shell_out2.sh"
"$ubx_users" execute --plan "$plan" --format shell --out "$shell_out2"
diff -u "$shell_out" "$shell_out2" > "$work/shell.diff" 2>&1 \
  || fail "shell format is not deterministic across repeated runs:
$(cat "$work/shell.diff")"

json_out2="$work/json_out2.json"
"$ubx_users" execute --plan "$plan" --format json --out "$json_out2"
diff -u "$json_out" "$json_out2" > "$work/json.diff" 2>&1 \
  || fail "json format is not deterministic across repeated runs:
$(cat "$work/json.diff")"

# -- an empty plan produces an empty (no-op) command sequence: nothing but
# the shell preamble in shell format, an empty list in json format.
empty_plan="$work/empty_plan.json"
cat > "$empty_plan" << 'EOF'
{
  "version": 1, "empty": true,
  "users": {"create": [], "modify": []},
  "groups": {"create": []},
  "membership": {"add": [], "remove": []},
  "authorized_keys": [],
  "drift": [], "errors": []
}
EOF
empty_shell="$work/empty_shell.sh"
"$ubx_users" execute --plan "$empty_plan" --format shell --out "$empty_shell"
grep -qE '^(groupadd|useradd|usermod|gpasswd|mkdir|chmod|chown|cat)' "$empty_shell" \
  && fail "empty plan: shell format unexpectedly emitted a mutating command"

empty_json="$work/empty_json.json"
"$ubx_users" execute --plan "$empty_plan" --format json --out "$empty_json"
python3 -c "
import json, sys
steps = json.load(open(sys.argv[1]))
assert steps == [], steps
" "$empty_json" || fail "empty plan: json format did not emit an empty step list"

exit "$fails"
