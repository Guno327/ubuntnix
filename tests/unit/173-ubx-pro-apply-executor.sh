#!/usr/bin/env bash
# tests/unit/173-ubx-pro-apply-executor.sh — bin/ubx-pro-apply's plan->apply
# executor, exercised end to end behind a MOCK `pro` binary (SPEC.md §8.2
# "Ubuntu Pro"; GitHub issue #82, milestone M4 — the issue's own acceptance
# criterion, "attach exercised behind a mock"). Mirrors
# tests/unit/164-ubx-secrets-apply-executor.sh's/
# tests/unit/148-snap-apply-executor.sh's own dry-run/apply/recording-stub
# style. This dev/CI harness has no real Ubuntu Pro subscription at all
# (issue #87, needs-owner, tracks a real attach) -- this test proves the
# plumbing end to end without needing one.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

ubx_pro="$UBX_REPO_ROOT/bin/ubx-pro"
apply="$UBX_REPO_ROOT/bin/ubx-pro-apply"
[ -x "$ubx_pro" ] || { echo "FAIL: $ubx_pro does not exist or is not executable" >&2; exit 1; }
[ -x "$apply" ] || { echo "FAIL: $apply does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# -- a recording mock standing in for the real `pro` client -----------------
mock_log="$work/mock-pro.log"
: > "$mock_log"
mock_pro="$work/mock-pro"
cat > "$mock_pro" <<EOF
#!/bin/sh
echo "\$*" >> "$mock_log"
exit 0
EOF
chmod +x "$mock_pro"

# =====================================================================
# 1) attach + enable esm-apps + enable livepatch, dry-run then --apply.
# =====================================================================
manifest="$work/manifest.json"
cat > "$manifest" <<'EOF'
{"version": 1, "enable": true, "tokenSecretPath": "/run/secrets/proToken", "esmApps": true, "livepatch": true}
EOF
observed="$work/observed.json"
cat > "$observed" <<'EOF'
{"version": 1, "attached": false, "services": {}}
EOF
plan="$work/plan.json"
"$ubx_pro" plan --manifest "$manifest" --observed "$observed" --out "$plan"

run_secrets="$work/run-secrets"
mkdir -p "$run_secrets"
printf 'the-real-pro-token' > "$run_secrets/proToken"

dryrun_out="$("$apply" --plan "$plan" --run-secrets-dir "$run_secrets" --pro-bin "$mock_pro" 2>&1)"
dryrun_rc=$?
[ "$dryrun_rc" -eq 0 ] || fail "dry-run should exit 0, got $dryrun_rc: $dryrun_out"
[ -s "$mock_log" ] && fail "dry-run must never actually invoke the pro binary, but mock log is non-empty: $(cat "$mock_log")"
case "$dryrun_out" in
  *"the-real-pro-token"*) fail "dry-run output must never leak the real token value, got: $dryrun_out" ;;
esac
case "$dryrun_out" in
  *"attach"*"proToken"*) ;;
  *) fail "dry-run output should mention the attach action and its secret name, got: $dryrun_out" ;;
esac

apply_out="$("$apply" --plan "$plan" --run-secrets-dir "$run_secrets" --pro-bin "$mock_pro" --apply 2>&1)"
apply_rc=$?
[ "$apply_rc" -eq 0 ] || fail "--apply should exit 0, got $apply_rc: $apply_out"

mapfile -t log_lines < "$mock_log"
[ "${#log_lines[@]}" -eq 3 ] || fail "expected exactly 3 real pro-cmd calls (attach, enable esm-apps, enable livepatch), got ${#log_lines[@]}: $(cat "$mock_log")"
[ "${log_lines[0]}" = "attach the-real-pro-token" ] || fail "expected first call to be 'attach the-real-pro-token', got: ${log_lines[0]:-<none>}"
[ "${log_lines[1]}" = "enable esm-apps --assume-yes" ] || fail "expected second call to be 'enable esm-apps --assume-yes', got: ${log_lines[1]:-<none>}"
[ "${log_lines[2]}" = "enable livepatch --assume-yes" ] || fail "expected third call to be 'enable livepatch --assume-yes', got: ${log_lines[2]:-<none>}"

# =====================================================================
# 2) a no-op (empty) plan is a real no-op success -- no pro invocation.
# =====================================================================
: > "$mock_log"
empty_plan="$work/empty-plan.json"
echo '{"version": 1, "empty": true, "actions": []}' > "$empty_plan"
empty_rc=0
"$apply" --plan "$empty_plan" --run-secrets-dir "$run_secrets" --pro-bin "$mock_pro" --apply > /dev/null 2>&1 || empty_rc=$?
[ "$empty_rc" -eq 0 ] || fail "an empty plan should exit 0, got $empty_rc"
[ ! -s "$mock_log" ] || fail "an empty plan must never invoke the pro binary, got: $(cat "$mock_log")"

# =====================================================================
# 3) detach, dry-run then --apply.
# =====================================================================
: > "$mock_log"
detach_plan="$work/detach-plan.json"
echo '{"version": 1, "empty": false, "actions": [{"op": "detach"}]}' > "$detach_plan"
"$apply" --plan "$detach_plan" --run-secrets-dir "$run_secrets" --pro-bin "$mock_pro" --apply > /dev/null 2>&1
[ "$(cat "$mock_log")" = "detach --assume-yes" ] || fail "expected a single 'detach --assume-yes' call, got: $(cat "$mock_log")"

# =====================================================================
# 4) attach action, but the token is NOT yet materialized -- skips
#    cleanly (SPEC.md's "Skip real attach cleanly when no token/mock
#    available", GitHub issue #82's own acceptance note).
# =====================================================================
: > "$mock_log"
missing_run_secrets="$work/run-secrets-missing"
mkdir -p "$missing_run_secrets"
attach_only_plan="$work/attach-only-plan.json"
echo '{"version": 1, "empty": false, "actions": [{"op": "attach", "tokenSecretName": "proToken"}]}' > "$attach_only_plan"
skip_out=""
skip_rc=0
skip_out="$("$apply" --plan "$attach_only_plan" --run-secrets-dir "$missing_run_secrets" --pro-bin "$mock_pro" --apply 2>&1)" || skip_rc=$?
[ "$skip_rc" -eq 0 ] || fail "a missing token file should still exit 0 (skip cleanly, never fail), got $skip_rc: $skip_out"
[ ! -s "$mock_log" ] || fail "attach with no materialized token must never invoke the pro binary for real, got: $(cat "$mock_log")"
case "$skip_out" in
  *"SKIP"*"not materialized"*) ;;
  *) fail "expected a clear SKIP message naming the missing token, got: $skip_out" ;;
esac

# =====================================================================
# 5) no real 'pro' client on PATH at all -- the whole plan is skipped
#    cleanly, never failed (this dev/CI harness's own real-world case).
# =====================================================================
: > "$mock_log"
noclient_rc=0
noclient_out="$(env -i PATH=/usr/bin:/bin "$apply" --plan "$plan" --run-secrets-dir "$run_secrets" --pro-bin "definitely-not-a-real-pro-client" --apply 2>&1)" || noclient_rc=$?
[ "$noclient_rc" -eq 0 ] || fail "a missing 'pro' client should still exit 0 (skip cleanly), got $noclient_rc: $noclient_out"
case "$noclient_out" in
  *"SKIP"*"not on PATH"*) ;;
  *) fail "expected a clear SKIP message naming the missing pro client, got: $noclient_out" ;;
esac

exit "$fails"
