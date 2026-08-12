#!/usr/bin/env bash
# tests/unit/230-ubx-secrets-apply-idempotent.sh — bin/ubx-secrets-apply's
# own idempotency + empty-plan posture (SPEC.md §4.3 "Switching and
# convergence" -- activation "touches only what changed"; GitHub issue
# #157, "test coverage for destructive executors"). Mirrors
# tests/unit/138-ubx-systemd-apply-idempotent-teardown.sh's own shape for
# bin/ubx-systemd-apply, adapted to bin/ubx-secrets-apply's materialize/
# env/symlink action set.
#
# -- Why owner/group are set to the INVOKING user, not "root" --------------
#
# This harness runs unprivileged (tests/README.md's "no root" rule), and
# bin/ubx-secrets-apply's own header ("Privilege") documents that owner/
# group are only ever applied via chown when euid is 0 -- so a manifest
# declaring owner/group "root" would leave every materialized file
# owned by the invoking test user forever, and a re-`observe` would report
# a permanent (unfixable-without-root) owner/group MISMATCH against the
# declared "root" on every single re-plan, even once content and mode have
# genuinely converged. That is not a real non-convergence bug -- it is an
# artifact of running unprivileged -- so the manifest below declares
# owner/group as the REAL invoking user (`id -un`/`id -gn`), exactly the
# account plan 1's materialize already produces content under even without
# a chown. tests/unit/164's own section 4 comment documents this same
# constraint and defers the full round-trip to this file instead.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

planner="$UBX_REPO_ROOT/bin/ubx-secrets"
apply="$UBX_REPO_ROOT/bin/ubx-secrets-apply"
[ -x "$planner" ] || { echo "FAIL: $planner does not exist or is not executable" >&2; exit 1; }
[ -x "$apply" ] || { echo "FAIL: $apply does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

me_owner="$(id -un)"
me_group="$(id -gn)"

secrets_src="$work/secretsrc"
mkdir -p "$secrets_src"
printf 'idempotent-material' > "$secrets_src/tok"

manifest="$work/manifest.json"
cat > "$manifest" <<EOF
{"version": 1, "secrets": [
  {"name": "tok", "owner": "$me_owner", "group": "$me_group", "mode": "0400", "dst": "/run/secrets/tok", "environmentVariable": null}
]}
EOF

plan="$work/plan.json"
"$planner" plan --manifest "$manifest" --out "$plan" || fail "seeding the plan should succeed"

run_secrets="$work/run-secrets"

# =====================================================================
# 1) first --apply materializes the secret.
# =====================================================================
"$apply" --plan "$plan" --secrets-dir "$secrets_src" --run-secrets-dir "$run_secrets" --apply
rc=$?
[ "$rc" -eq 0 ] || fail "first --apply should exit 0, got $rc"
[ -f "$run_secrets/tok" ] || fail "first --apply should have materialized $run_secrets/tok"
[ "$(cat "$run_secrets/tok" 2> /dev/null)" = "idempotent-material" ] || fail "tok content mismatch after first apply"

# =====================================================================
# 2) re-observing + re-planning against the just-converged real state is a
#    genuine no-op -- the planner-level proof that activation "touches
#    only what changed" (SPEC.md §4.3), not merely that the executor
#    happens not to crash on a second run.
# =====================================================================
observed="$work/observed.json"
"$planner" observe --run-secrets-dir "$run_secrets" --manifest "$manifest" --out "$observed" \
  || fail "observe (post-apply) should succeed"
replan="$work/replan.json"
"$planner" plan --manifest "$manifest" --observed "$observed" --out "$replan" \
  || fail "plan (post-apply) should succeed"
if ! python3 - "$replan" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["empty"] is True, p
PYEOF
then
  fail "re-planning against the just-applied real state should be a no-op -- got: $(cat "$replan")"
fi

# =====================================================================
# 3) applying the EXACT SAME (non-empty) plan a second time back to back
#    must still succeed and leave the material exactly as it was
#    (executor-level idempotency: safe to re-run, not just plan-level
#    convergence).
# =====================================================================
"$apply" --plan "$plan" --secrets-dir "$secrets_src" --run-secrets-dir "$run_secrets" --apply
rc=$?
[ "$rc" -eq 0 ] || fail "second --apply of the SAME plan should exit 0, got $rc"
[ "$(cat "$run_secrets/tok" 2> /dev/null)" = "idempotent-material" ] || fail "tok content changed after re-applying the same plan"
[ "$(stat -c '%a' "$run_secrets/tok" 2> /dev/null)" = "400" ] || fail "tok mode changed after re-applying the same plan"

# =====================================================================
# 4) an empty plan is a real no-op: exit 0, and the already-converged
#    tree is byte-for-byte untouched (snapshot before/after, not just
#    "the one file we know about still exists").
# =====================================================================
before_snapshot="$(cd "$run_secrets" && find . -type f -exec sha256sum {} + | sort)"
# mtime has only whole-second resolution via `stat -c '%Y'`; sleep past a
# second boundary first so a regression that spuriously re-touches (but
# does not otherwise corrupt) the file is still caught below.
sleep 1
before_mtime="$(stat -c '%Y' "$run_secrets/tok")"

empty_plan="$work/empty-plan.json"
echo '{"version": 1, "empty": true, "materialize": {"create": [], "update": [], "remove": []}, "env": {"create": [], "update": [], "remove": []}, "symlink": {"create": []}}' > "$empty_plan"
empty_rc=0
"$apply" --plan "$empty_plan" --secrets-dir "$secrets_src" --run-secrets-dir "$run_secrets" --apply > /dev/null 2>&1 || empty_rc=$?
[ "$empty_rc" -eq 0 ] || fail "an empty plan should exit 0, got $empty_rc"

after_snapshot="$(cd "$run_secrets" && find . -type f -exec sha256sum {} + | sort)"
after_mtime="$(stat -c '%Y' "$run_secrets/tok")"
[ "$before_snapshot" = "$after_snapshot" ] || fail "an empty plan must not change any file's contents -- before: $before_snapshot / after: $after_snapshot"
[ "$before_mtime" = "$after_mtime" ] || fail "an empty plan must not even re-touch tok's mtime (nothing should have been executed at all)"

exit "$fails"
