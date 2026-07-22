#!/usr/bin/env bash
# tests/unit/100-ubx-users-fixtures.sh — bin/ubx-users' passwd/group/shadow
# fixture parsing (SPEC.md §4.3 "Users"; GitHub issue #28, milestone M2).
#
# There is no separate "parse" subcommand to call directly: parsing is
# exercised indirectly through `plan`, whose observable output (what gets
# planned, and what shows up as `drift`) is exactly what proves the parser
# read the fixture correctly -- a well-formed passwd/group/shadow entry
# that matches the declared manifest produces an empty plan; a malformed
# line produces a `malformed_*_line` drift entry and is excluded from
# further processing, never guessed at (see bin/ubx-users' own header,
# "What counts as managed").
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
      "home": null, "createHome": true, "groups": [], "authorizedKeys": [] }
  ],
  "groups": []
}
EOF

# -- a well-formed, already-converged fixture parses cleanly: empty plan,
# exit 0.
passwd_ok="$work/passwd_ok"
cat > "$passwd_ok" << 'EOF'
root:x:0:0:root:/root:/bin/bash
gunnar:x:1000:1000:gunnar:/home/gunnar:/usr/bin/bash
EOF
group_ok="$work/group_ok"
cat > "$group_ok" << 'EOF'
root:x:0:
EOF
shadow_ok="$work/shadow_ok"
cat > "$shadow_ok" << 'EOF'
root:*:19000:0:99999:7:::
gunnar:!:19000:0:99999:7:::
EOF

plan_ok="$work/plan_ok.json"
if ! "$ubx_users" plan --manifest "$manifest" --passwd "$passwd_ok" --group "$group_ok" \
  --shadow "$shadow_ok" --out "$plan_ok"; then
  fail "well-formed, already-converged fixture should plan cleanly (exit 0)"
fi
python3 -c "
import json, sys
plan = json.load(open(sys.argv[1]))
assert plan['empty'] is True, f\"expected an empty plan, got: {plan}\"
assert plan['drift'] == [], f\"expected no drift, got: {plan['drift']}\"
" "$plan_ok" || fail "well-formed fixture: plan was not empty/driftless"

# -- a malformed passwd line: too few fields. Reported as drift, excluded
# from further processing (gunnar's own well-formed line two lines later
# is still parsed normally).
passwd_bad="$work/passwd_bad"
cat > "$passwd_bad" << 'EOF'
root:x:0:0:root:/root:/bin/bash
this:line:has:too:few:fields
gunnar:x:1000:1000:gunnar:/home/gunnar:/usr/bin/bash
EOF

plan_bad="$work/plan_bad.json"
"$ubx_users" plan --manifest "$manifest" --passwd "$passwd_bad" --group "$group_ok" \
  --shadow "$shadow_ok" --out "$plan_bad"
python3 -c "
import json, sys
plan = json.load(open(sys.argv[1]))
kinds = [d['kind'] for d in plan['drift']]
assert 'malformed_passwd_line' in kinds, f\"expected a malformed_passwd_line drift entry, got: {plan['drift']}\"
entry = next(d for d in plan['drift'] if d['kind'] == 'malformed_passwd_line')
assert entry['line'] == 2, f\"expected the malformed line to be reported as line 2, got: {entry}\"
# gunnar's own well-formed line is unaffected -- no create/modify planned.
assert plan['users']['create'] == [], plan['users']['create']
assert plan['users']['modify'] == [], plan['users']['modify']
" "$plan_bad" || fail "malformed passwd line: not reported as drift, or good lines mis-parsed"

# -- a malformed group line (non-numeric gid): same treatment.
group_bad="$work/group_bad"
cat > "$group_bad" << 'EOF'
root:x:0:
sudo:x:notanumber:someone
EOF
manifest_sudo="$work/manifest_sudo.json"
cat > "$manifest_sudo" << 'EOF'
{
  "version": 1,
  "users": [
    { "name": "gunnar", "uid": 1000, "system": false, "shell": "/usr/bin/bash",
      "home": null, "createHome": true, "groups": ["sudo"], "authorizedKeys": [] }
  ],
  "groups": []
}
EOF
plan_group_bad="$work/plan_group_bad.json"
"$ubx_users" plan --manifest "$manifest_sudo" --passwd "$passwd_ok" --group "$group_bad" \
  --shadow "$shadow_ok" --out "$plan_group_bad"
python3 -c "
import json, sys
plan = json.load(open(sys.argv[1]))
kinds = [d['kind'] for d in plan['drift']]
assert 'malformed_group_line' in kinds, f\"expected a malformed_group_line drift entry, got: {plan['drift']}\"
# 'sudo' could not be read as a real group (its line was malformed), so the
# planner must plan to CREATE it rather than silently treating it as
# already existing (a malformed observed line is not evidence of anything).
assert any(g['name'] == 'sudo' for g in plan['groups']['create']), plan['groups']['create']
" "$plan_group_bad" || fail "malformed group line: not reported as drift, or sudo group not re-planned for creation"

# -- blank lines in the fixture are simply skipped, not malformed.
passwd_blank="$work/passwd_blank"
printf 'root:x:0:0:root:/root:/bin/bash\n\ngunnar:x:1000:1000:gunnar:/home/gunnar:/usr/bin/bash\n' > "$passwd_blank"
plan_blank="$work/plan_blank.json"
"$ubx_users" plan --manifest "$manifest" --passwd "$passwd_blank" --group "$group_ok" \
  --shadow "$shadow_ok" --out "$plan_blank"
python3 -c "
import json, sys
plan = json.load(open(sys.argv[1]))
assert plan['drift'] == [], f\"a blank line must not be reported as malformed: {plan['drift']}\"
assert plan['empty'] is True, plan
" "$plan_blank" || fail "blank passwd line was mishandled"

exit "$fails"
