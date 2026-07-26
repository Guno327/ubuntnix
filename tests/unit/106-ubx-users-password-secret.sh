#!/usr/bin/env bash
# tests/unit/106-ubx-users-password-secret.sh — bin/ubx-users' M4
# `hashedPasswordSecret` support (SPEC.md §4.3 "Users", §8.1; GitHub issue
# #80, milestone M4, "password login from a secret-sourced hash"). Mirrors
# 101-ubx-users-plan-create-modify.sh's `plan_of` fixture-writing style and
# 162-ubx-secrets-plan-materialize.sh's own secrets-manifest fixture shape.
#
# Covers this issue's own acceptance criteria:
#   - the manifest/plan carry the secret NAME only, never a hash;
#   - the (real) apply-passwords executor sets /etc/shadow from a fixture
#     /run/secrets/<name> file;
#   - a missing/unreferenced secret is a clear, explicit error, both when
#     --secrets-manifest is omitted entirely and when it is given but does
#     not declare the referenced name;
#   - already-converged input (matching hash already in shadow) is a real,
#     idempotent no-op;
#   - the `hashedPasswordSecret` machine-local exception skips planning.
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

base_passwd="$work/passwd"
cat > "$base_passwd" << 'EOF'
root:x:0:0:root:/root:/bin/bash
gunnar:x:1000:1000:gunnar:/home/gunnar:/usr/bin/bash
EOF
base_group="$work/group"
cat > "$base_group" << 'EOF'
root:x:0:
EOF
base_shadow="$work/shadow"
cat > "$base_shadow" << 'EOF'
root:*:19000:0:99999:7:::
gunnar:!:19000:0:99999:7:::
EOF

manifest_with_secret="$work/manifest.json"
cat > "$manifest_with_secret" << 'EOF'
{
  "version": 1,
  "users": [
    { "name": "gunnar", "uid": 1000, "system": false, "shell": "/usr/bin/bash",
      "home": null, "createHome": true, "groups": [], "authorizedKeys": [],
      "hashedPasswordSecret": "gunnarPassword" }
  ],
  "groups": []
}
EOF

secrets_manifest="$work/secrets-manifest.json"
cat > "$secrets_manifest" << 'EOF'
{"version": 1, "secrets": [
  {"name": "gunnarPassword", "owner": "root", "group": "root", "mode": "0400",
   "dst": "/run/secrets/gunnarPassword", "environmentVariable": null}
]}
EOF

# =====================================================================
# 1) manifest/plan purity: the secret NAME appears, the hash never does.
# =====================================================================
plan1="$work/plan1.json"
rc=0
"$ubx_users" plan --manifest "$manifest_with_secret" --passwd "$base_passwd" --group "$base_group" \
  --shadow "$base_shadow" --secrets-manifest "$secrets_manifest" --out "$plan1" || rc=$?
[ "$rc" -eq 0 ] || fail "plan with a validated hashedPasswordSecret should exit 0, got $rc"

python3 -c "
import json, sys
plan = json.load(open(sys.argv[1]))
ps = plan['password_set']
assert ps == [{'user': 'gunnar', 'secret': 'gunnarPassword'}], ps
assert plan['errors'] == [], plan['errors']
assert plan['empty'] is False, plan
" "$plan1" || fail "plan1: password_set entry missing/incorrect, or errors non-empty"

# The plan JSON must never contain anything that looks like a real crypt(3)
# hash (a '$id$salt$hash' shape) -- only the secret's own NAME.
if grep -qE '\$[0-9a-z]+\$[^"]*\$' "$plan1"; then
  fail "plan1.json appears to contain a crypt(3)-shaped hash -- must carry only the secret NAME"
fi
grep -q 'gunnarPassword' "$plan1" || fail "plan1.json should reference the secret name 'gunnarPassword'"

# =====================================================================
# 2) apply-passwords: real shadow update from a fixture /run/secrets/<name>
#    file (this issue's own "sets shadow from a fixture" acceptance case).
# =====================================================================
run_secrets="$work/run-secrets"
mkdir -p "$run_secrets"
printf '%s\n' '$6$roundsSaltHashHashHashHashHashHashHashHashHashHashHashHash01' > "$run_secrets/gunnarPassword"

shadow_target="$work/shadow-target"
cp "$base_shadow" "$shadow_target"

apply_out="$work/apply1.json"
rc=0
"$ubx_users" apply-passwords --plan "$plan1" --shadow "$shadow_target" \
  --run-secrets-dir "$run_secrets" --apply --out "$apply_out" || rc=$?
[ "$rc" -eq 0 ] || fail "apply-passwords --apply should exit 0 on a well-formed request, got $rc"

python3 -c "
import json, sys
summary = json.load(open(sys.argv[1]))
assert summary['applied'] is True, summary
assert summary['changed'] == ['gunnar'], summary
assert summary['errors'] == [], summary
" "$apply_out" || fail "apply1.json summary did not report gunnar as changed"

grep -qxF 'gunnar:$6$roundsSaltHashHashHashHashHashHashHashHashHashHashHashHash01:19000:0:99999:7:::' "$shadow_target" \
  || fail "shadow_target does not contain gunnar's new hash after apply-passwords --apply: $(cat "$shadow_target")"
grep -qxF 'root:*:19000:0:99999:7:::' "$shadow_target" \
  || fail "apply-passwords must leave root's own shadow line untouched"

# =====================================================================
# 3) idempotency: re-running apply-passwords against an already-converged
#    shadow file is a real no-op (no 'changed' entries, file untouched).
# =====================================================================
shadow_before="$work/shadow-before-2nd.snapshot"
cp "$shadow_target" "$shadow_before"

apply_out2="$work/apply2.json"
"$ubx_users" apply-passwords --plan "$plan1" --shadow "$shadow_target" \
  --run-secrets-dir "$run_secrets" --apply --out "$apply_out2"
python3 -c "
import json, sys
summary = json.load(open(sys.argv[1]))
assert summary['changed'] == [], summary
assert summary['errors'] == [], summary
" "$apply_out2" || fail "apply2.json: already-converged shadow should report no changes"
diff -u "$shadow_before" "$shadow_target" > "$work/idempotent.diff" 2>&1 \
  || fail "apply-passwords rewrote an already-converged shadow file:
$(cat "$work/idempotent.diff")"

# =====================================================================
# 4) --dry-run never writes --shadow, even when a real change is pending.
# =====================================================================
shadow_dry="$work/shadow-dry"
cat > "$shadow_dry" << 'EOF'
gunnar:!:19000:0:99999:7:::
EOF
dry_out="$work/apply-dry.json"
rc=0
"$ubx_users" apply-passwords --plan "$plan1" --shadow "$shadow_dry" \
  --run-secrets-dir "$run_secrets" --dry-run --out "$dry_out" || rc=$?
[ "$rc" -eq 0 ] || fail "apply-passwords --dry-run should exit 0, got $rc"
grep -qxF 'gunnar:!:19000:0:99999:7:::' "$shadow_dry" \
  || fail "apply-passwords --dry-run must never write --shadow"
python3 -c "
import json, sys
summary = json.load(open(sys.argv[1]))
assert summary['applied'] is False, summary
assert summary['changed'] == ['gunnar'], summary
" "$dry_out" || fail "apply-dry.json should report gunnar as a would-be change, applied=False"

# =====================================================================
# 5) missing/unreferenced secret -- a clear, explicit error, two ways.
# =====================================================================

# 5a) hashedPasswordSecret declared, but --secrets-manifest never given at
# all: refused, not silently trusted.
plan_no_manifest="$work/plan-no-manifest.json"
rc=0
"$ubx_users" plan --manifest "$manifest_with_secret" --passwd "$base_passwd" --group "$base_group" \
  --shadow "$base_shadow" --out "$plan_no_manifest" || rc=$?
[ "$rc" -eq 1 ] || fail "plan with hashedPasswordSecret and no --secrets-manifest should exit 1, got $rc"
python3 -c "
import json, sys
plan = json.load(open(sys.argv[1]))
assert any('gunnarPassword' in e and 'no --secrets-manifest' in e for e in plan['errors']), plan['errors']
assert plan['password_set'] == [], plan['password_set']
" "$plan_no_manifest" || fail "plan-no-manifest.json: missing/incorrect clear error for an unvalidated hashedPasswordSecret"

# 5b) --secrets-manifest given, but it does not declare the referenced name.
empty_secrets_manifest="$work/empty-secrets-manifest.json"
echo '{"version": 1, "secrets": []}' > "$empty_secrets_manifest"
plan_unreferenced="$work/plan-unreferenced.json"
rc=0
"$ubx_users" plan --manifest "$manifest_with_secret" --passwd "$base_passwd" --group "$base_group" \
  --shadow "$base_shadow" --secrets-manifest "$empty_secrets_manifest" --out "$plan_unreferenced" || rc=$?
[ "$rc" -eq 1 ] || fail "plan referencing an undeclared secret should exit 1, got $rc"
python3 -c "
import json, sys
plan = json.load(open(sys.argv[1]))
assert any('gunnarPassword' in e and 'not declared' in e for e in plan['errors']), plan['errors']
assert plan['password_set'] == [], plan['password_set']
" "$plan_unreferenced" || fail "plan-unreferenced.json: missing/incorrect clear error for an unreferenced secret"

# 5c) apply-passwords itself: the plan validated fine, but the secret was
# never actually materialized under --run-secrets-dir (e.g. secrets domain
# not applied yet) -- also a clear, explicit error, not a silent skip.
empty_run_secrets="$work/empty-run-secrets"
mkdir -p "$empty_run_secrets"
apply_missing_out="$work/apply-missing.json"
rc=0
"$ubx_users" apply-passwords --plan "$plan1" --shadow "$work/shadow-for-missing" \
  --run-secrets-dir "$empty_run_secrets" --apply --out "$apply_missing_out" || rc=$?
[ "$rc" -eq 1 ] || fail "apply-passwords against a non-materialized secret should exit 1, got $rc"
python3 -c "
import json, sys
summary = json.load(open(sys.argv[1]))
assert any('gunnarPassword' in e and 'materialized' in e for e in summary['errors']), summary['errors']
assert summary['changed'] == [], summary
" "$apply_missing_out" || fail "apply-missing.json: missing/incorrect clear error for a non-materialized secret"

# =====================================================================
# 6) machine-local exception: 'hashedPasswordSecret' in --exceptions skips
#    planning a password_set entry (the reference is still validated).
# =====================================================================
plan_excepted="$work/plan-excepted.json"
rc=0
"$ubx_users" plan --manifest "$manifest_with_secret" --passwd "$base_passwd" --group "$base_group" \
  --shadow "$base_shadow" --secrets-manifest "$secrets_manifest" --out "$plan_excepted" \
  --exceptions <(echo '{"gunnar": ["hashedPasswordSecret"]}') || rc=$?
[ "$rc" -eq 0 ] || fail "plan with hashedPasswordSecret excepted should still exit 0, got $rc"
python3 -c "
import json, sys
plan = json.load(open(sys.argv[1]))
assert plan['password_set'] == [], plan['password_set']
assert plan['empty'] is True, plan
" "$plan_excepted" || fail "plan-excepted.json: excepted hashedPasswordSecret should not be planned"

# =====================================================================
# 7) manifest validation: a syntactically invalid hashedPasswordSecret is
#    rejected with a clear message.
# =====================================================================
bad_secret_manifest="$work/bad-secret-manifest.json"
cat > "$bad_secret_manifest" << 'EOF'
{
  "version": 1,
  "users": [
    { "name": "gunnar", "uid": 1000, "system": false, "shell": "/usr/bin/bash",
      "home": null, "createHome": true, "groups": [], "authorizedKeys": [],
      "hashedPasswordSecret": "not a valid secret name!" }
  ],
  "groups": []
}
EOF
out=""
rc=0
out="$("$ubx_users" plan --manifest "$bad_secret_manifest" --passwd "$base_passwd" --group "$base_group" \
  --shadow "$base_shadow" --secrets-manifest "$secrets_manifest" 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "an invalid hashedPasswordSecret name should exit 1, got $rc"
case "$out" in
  *"hashedPasswordSecret"*) ;;
  *) fail "invalid hashedPasswordSecret error should mention the field, got: $out" ;;
esac

exit "$fails"
