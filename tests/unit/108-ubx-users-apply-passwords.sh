#!/usr/bin/env bash
# tests/unit/108-ubx-users-apply-passwords.sh — bin/ubx-users'
# `apply-passwords`: the REAL password-hash executor (SPEC.md §8.1; GitHub
# issue #80, milestone M4). Reads a secret's materialized bytes from a
# fixture `--run-secrets-dir/<secret>` file and rewrites the matching
# user's hash field in a fixture `--shadow` file, in place -- exactly the
# acceptance criterion "planner sets shadow from a fixture
# /run/secrets/<name> file", exercised here with zero root (every path is
# a plain, caller-owned temp file). Mirrors tests/unit/164-ubx-secrets-
# apply-executor.sh's own --apply/--dry-run testing style.
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

mkplan() {
  cat > "$1" << EOF
{
  "version": 1, "empty": false,
  "users": {"create": [], "modify": []},
  "groups": {"create": []},
  "membership": {"add": [], "remove": []},
  "authorized_keys": [],
  "password_set": [{"user": "alice", "secret": "alicePw"}],
  "drift": [], "errors": []
}
EOF
}

new_shadow() {
  printf 'root:*:19000:0:99999:7:::\nalice:!:19000:0:99999:7:::\nbob:!:19000:0:99999:7:::\n' > "$1"
}

# =====================================================================
# 1) --dry-run (default): reports the would-be change, never writes.
# =====================================================================
plan="$work/plan.json"
mkplan "$plan"
shadow1="$work/shadow1"
new_shadow "$shadow1"
run_secrets1="$work/run-secrets1"
mkdir -p "$run_secrets1"
printf '$6$fakesalt$therealhashvalue\n' > "$run_secrets1/alicePw"

out="$("$ubx_users" apply-passwords --plan "$plan" --shadow "$shadow1" --run-secrets-dir "$run_secrets1" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "dry-run apply-passwords should exit 0, got $rc: $out"
grep -q '^alice:!:' "$shadow1" || fail "dry-run must not have modified $shadow1"
echo "$out" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['applied'] is False, d
assert d['changed'] == ['alice'], d
assert d['errors'] == [], d
" || fail "dry-run JSON output should report changed=['alice'], applied=false, got: $out"

# The real hash value must never appear anywhere in this tool's own
# stdout/stderr (this file's own invariant) -- only names/paths do.
echo "$out" | grep -qF 'therealhashvalue' && fail "dry-run output leaked the real hash value"

# =====================================================================
# 2) --apply: really rewrites, preserving every other shadow field.
# =====================================================================
shadow2="$work/shadow2"
new_shadow "$shadow2"
run_secrets2="$work/run-secrets2"
mkdir -p "$run_secrets2"
printf '$6$fakesalt$therealhashvalue\n' > "$run_secrets2/alicePw"

out2="$("$ubx_users" apply-passwords --plan "$plan" --shadow "$shadow2" --run-secrets-dir "$run_secrets2" --apply 2>&1)"
rc2=$?
[ "$rc2" -eq 0 ] || fail "--apply should exit 0, got $rc2: $out2"
grep -qxF 'alice:$6$fakesalt$therealhashvalue:19000:0:99999:7:::' "$shadow2" \
  || fail "--apply should have rewritten alice's hash field, preserving every other field: $(grep alice "$shadow2")"
grep -qxF 'root:*:19000:0:99999:7:::' "$shadow2" || fail "--apply must leave unrelated lines (root) untouched"
grep -qxF 'bob:!:19000:0:99999:7:::' "$shadow2" || fail "--apply must leave unrelated lines (bob) untouched"
echo "$out2" | grep -qF 'therealhashvalue' && fail "--apply's own JSON summary leaked the real hash value"

# =====================================================================
# 3) idempotent: re-applying the SAME hash is a real no-op (changed: []).
# =====================================================================
out3="$("$ubx_users" apply-passwords --plan "$plan" --shadow "$shadow2" --run-secrets-dir "$run_secrets2" --apply 2>&1)"
rc3=$?
[ "$rc3" -eq 0 ] || fail "re-applying an already-converged hash should exit 0, got $rc3"
echo "$out3" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['changed'] == [], d
" || fail "re-applying an already-converged hash should report changed=[], got: $out3"

# =====================================================================
# 4) missing materialized secret: a clear error, exit 1, no mutation.
# =====================================================================
shadow4="$work/shadow4"
new_shadow "$shadow4"
run_secrets4="$work/run-secrets4-empty"
mkdir -p "$run_secrets4"
out4="$("$ubx_users" apply-passwords --plan "$plan" --shadow "$shadow4" --run-secrets-dir "$run_secrets4" --apply 2>&1)"
rc4=$?
[ "$rc4" -eq 1 ] || fail "missing materialized secret should exit 1, got $rc4"
grep -qxF 'alice:!:19000:0:99999:7:::' "$shadow4" || fail "a failed apply must not have mutated $shadow4"
echo "$out4" | grep -q "alicePw" || fail "missing-secret error should name the secret, got: $out4"

# =====================================================================
# 5) user absent from --shadow entirely: a clear error, never a silent
#    skip or auto-create.
# =====================================================================
shadow5="$work/shadow5"
printf 'root:*:19000:0:99999:7:::\n' > "$shadow5"
run_secrets5="$work/run-secrets5"
mkdir -p "$run_secrets5"
printf 'somehash\n' > "$run_secrets5/alicePw"
out5="$("$ubx_users" apply-passwords --plan "$plan" --shadow "$shadow5" --run-secrets-dir "$run_secrets5" --apply 2>&1)"
rc5=$?
[ "$rc5" -eq 1 ] || fail "a user absent from --shadow should exit 1, got $rc5"
grep -qxF 'root:*:19000:0:99999:7:::' "$shadow5" || fail "a failed apply must not have mutated $shadow5"
echo "$out5" | grep -q "alice" || fail "missing-user error should name the user, got: $out5"

# =====================================================================
# 6) an empty plan (no password_set actions): a real, quiet no-op.
# =====================================================================
empty_plan="$work/empty-plan.json"
cat > "$empty_plan" << 'EOF'
{
  "version": 1, "empty": true,
  "users": {"create": [], "modify": []},
  "groups": {"create": []},
  "membership": {"add": [], "remove": []},
  "authorized_keys": [],
  "password_set": [],
  "drift": [], "errors": []
}
EOF
shadow6="$work/shadow6"
new_shadow "$shadow6"
out6="$("$ubx_users" apply-passwords --plan "$empty_plan" --shadow "$shadow6" --apply 2>&1)"
rc6=$?
[ "$rc6" -eq 0 ] || fail "an empty plan should exit 0, got $rc6"
echo "$out6" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['changed'] == [] and d['errors'] == [], d
" || fail "an empty plan should report changed=[] errors=[], got: $out6"

exit "$fails"
