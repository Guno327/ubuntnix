#!/usr/bin/env bash
# tests/unit/107-ubx-users-password-secret-plan.sh — bin/ubx-users' `plan`:
# hashedPasswordSecret cross-validation against a real secrets manifest,
# and the resulting `password_set` plan action (SPEC.md §6, §8.1; GitHub
# issue #80, milestone M4, "password login from a secret-sourced hash").
# Mirrors tests/unit/101-ubx-users-plan-create-modify.sh's own style.
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

passwd="$work/passwd"
printf 'root:x:0:0:root:/root:/bin/bash\nalice:x:1000:1000:alice:/home/alice:/usr/bin/bash\n' > "$passwd"
group="$work/group"
printf 'root:x:0:\nalice:x:1000:\n' > "$group"
shadow="$work/shadow"
printf 'root:*:19000:0:99999:7:::\nalice:!:19000:0:99999:7:::\n' > "$shadow"

manifest="$work/manifest.json"
cat > "$manifest" << 'EOF'
{
  "version": 1,
  "users": [
    { "name": "alice", "uid": 1000, "system": false, "shell": "/usr/bin/bash",
      "home": null, "createHome": true, "groups": [], "authorizedKeys": [],
      "hashedPasswordSecret": "alicePw" }
  ],
  "groups": []
}
EOF

secrets_manifest="$work/secrets-manifest.json"
cat > "$secrets_manifest" << 'EOF'
{"version": 1, "secrets": [
  {"name": "alicePw", "owner": "root", "group": "root", "mode": "0400", "dst": "/run/secrets/alicePw", "environmentVariable": null}
]}
EOF

# =====================================================================
# 1) a valid reference: plan succeeds, emits exactly one password_set
#    entry naming the user and the secret -- never a hash, never a path.
# =====================================================================
plan1="$work/plan1.json"
"$ubx_users" plan --manifest "$manifest" --passwd "$passwd" --group "$group" --shadow "$shadow" \
  --secrets-manifest "$secrets_manifest" --out "$plan1"
rc=$?
[ "$rc" -eq 0 ] || fail "plan with a valid hashedPasswordSecret reference should exit 0, got $rc"

python3 -c "
import json, sys
p = json.load(open(sys.argv[1]))
assert p['password_set'] == [{'user': 'alice', 'secret': 'alicePw'}], p['password_set']
assert p['errors'] == [], p['errors']
" "$plan1" || fail "plan1: password_set entry missing/incorrect"

# The rendered plan must never carry a 'hash' key, or anything shaped like
# a real crypt(3) hash value, anywhere -- only the secret's own NAME.
grep -qi '"hash"' "$plan1" && fail "plan1: manifest/plan must never carry a 'hash' key"

# =====================================================================
# 2) hashedPasswordSecret declared, but --secrets-manifest omitted
#    entirely: a hard, clear error (never a silent skip).
# =====================================================================
plan2="$work/plan2.json"
out2="$("$ubx_users" plan --manifest "$manifest" --passwd "$passwd" --group "$group" --shadow "$shadow" --out "$plan2" 2>&1)"
rc2=$?
[ "$rc2" -eq 1 ] || fail "plan with hashedPasswordSecret but no --secrets-manifest should exit 1, got $rc2"
python3 -c "
import json, sys
p = json.load(open(sys.argv[1]))
assert p['password_set'] == [], p['password_set']
assert any('alice' in e and 'secrets-manifest' in e for e in p['errors']), p['errors']
" "$plan2" || fail "plan2: missing --secrets-manifest should produce a clear error naming the user, got: $out2"

# =====================================================================
# 3) hashedPasswordSecret references a name NOT in --secrets-manifest:
#    a hard, clear error naming the offending secret.
# =====================================================================
empty_secrets="$work/empty-secrets.json"
printf '{"version": 1, "secrets": []}' > "$empty_secrets"
plan3="$work/plan3.json"
"$ubx_users" plan --manifest "$manifest" --passwd "$passwd" --group "$group" --shadow "$shadow" \
  --secrets-manifest "$empty_secrets" --out "$plan3"
rc3=$?
[ "$rc3" -eq 1 ] || fail "plan with an unreferenced secret should exit 1, got $rc3"
python3 -c "
import json, sys
p = json.load(open(sys.argv[1]))
assert p['password_set'] == [], p['password_set']
assert any('alicePw' in e for e in p['errors']), p['errors']
" "$plan3" || fail "plan3: unreferenced secret should produce a clear error naming it"

# =====================================================================
# 4) machine-local exception "hashedPasswordSecret" suppresses the
#    password_set action for an otherwise-VALID reference (but a bad
#    reference is still an error regardless -- exceptions cover
#    convergence intent, not manifest correctness; see case 3 above,
#    unaffected by this).
# =====================================================================
exceptions="$work/exceptions.json"
printf '{"alice": ["hashedPasswordSecret"]}' > "$exceptions"
plan4="$work/plan4.json"
"$ubx_users" plan --manifest "$manifest" --passwd "$passwd" --group "$group" --shadow "$shadow" \
  --secrets-manifest "$secrets_manifest" --exceptions "$exceptions" --out "$plan4"
rc4=$?
[ "$rc4" -eq 0 ] || fail "plan with an exception-suppressed hashedPasswordSecret should exit 0, got $rc4"
python3 -c "
import json, sys
p = json.load(open(sys.argv[1]))
assert p['password_set'] == [], p['password_set']
assert p['errors'] == [], p['errors']
" "$plan4" || fail "plan4: exception should suppress the password_set action with no error"

# =====================================================================
# 5) no hashedPasswordSecret declared at all: password_set is empty,
#    --secrets-manifest is not even required.
# =====================================================================
no_secret_manifest="$work/no-secret-manifest.json"
cat > "$no_secret_manifest" << 'EOF'
{
  "version": 1,
  "users": [
    { "name": "alice", "uid": 1000, "system": false, "shell": "/usr/bin/bash",
      "home": null, "createHome": true, "groups": [], "authorizedKeys": [] }
  ],
  "groups": []
}
EOF
plan5="$work/plan5.json"
"$ubx_users" plan --manifest "$no_secret_manifest" --passwd "$passwd" --group "$group" --shadow "$shadow" --out "$plan5"
rc5=$?
[ "$rc5" -eq 0 ] || fail "plan with no hashedPasswordSecret declared should exit 0 without --secrets-manifest, got $rc5"
python3 -c "
import json, sys
p = json.load(open(sys.argv[1]))
assert p['password_set'] == [], p['password_set']
" "$plan5" || fail "plan5: password_set should be empty when nothing declares hashedPasswordSecret"

exit "$fails"
