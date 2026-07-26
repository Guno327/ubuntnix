#!/usr/bin/env bash
# tests/unit/164-ubx-secrets-apply-executor.sh — bin/ubx-secrets-apply's
# plan->apply executor, plus bin/ubx-secrets' own `observe` subcommand
# (SPEC.md §8.1, §4.3 "none" downtime; GitHub issue #78, milestone M4).
# Mirrors tests/unit/139-ubx-etc-apply.sh's own dry-run/apply style,
# adapted to the materialize/env/symlink action set.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

apply="$UBX_REPO_ROOT/bin/ubx-secrets-apply"
planner="$UBX_REPO_ROOT/bin/ubx-secrets"
ubx="$UBX_REPO_ROOT/bin/ubx"
[ -x "$apply" ] || { echo "FAIL: $apply does not exist or is not executable" >&2; exit 1; }
[ -x "$planner" ] || { echo "FAIL: $planner does not exist or is not executable" >&2; exit 1; }
[ -x "$ubx" ] || { echo "FAIL: $ubx does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# =====================================================================
# 1) materialize create + env create + custom-dst symlink, dry-run then
#    apply, plus the persistent-filesystem warning (mounts fixture).
# =====================================================================
secrets_src="$work/secretsrc"
mkdir -p "$secrets_src"
printf 'pro-material' > "$secrets_src/proToken"
printf 'api-material' > "$secrets_src/apiToken"
printf 'wg-material' > "$secrets_src/wgKey"

custom_dst_dir="$work/run-secrets-custom-dst"
manifest="$work/manifest.json"
cat > "$manifest" <<EOF
{"version": 1, "secrets": [
  {"name": "proToken", "owner": "root", "group": "root", "mode": "0400", "dst": "/run/secrets/proToken", "environmentVariable": null},
  {"name": "apiToken", "owner": "root", "group": "root", "mode": "0400", "dst": "/run/secrets/apiToken", "environmentVariable": "API_TOKEN"},
  {"name": "wgKey", "owner": "root", "group": "root", "mode": "0400", "dst": "$custom_dst_dir/wg0.key", "environmentVariable": null}
]}
EOF

plan="$work/plan.json"
"$planner" plan --manifest "$manifest" --out "$plan"

run_secrets="$work/run-secrets"
mounts_file="$work/mounts"
# A fixture mount table where the symlink's own directory
# (run-secrets-custom-dst) resolves to a non-tmpfs (ext4) mount -- this
# must trigger the loud persistent-filesystem warning (SPEC.md §8.1).
cat > "$mounts_file" <<EOF
proc / proc rw 0 0
tmpfs $run_secrets tmpfs rw 0 0
/dev/sda1 $work ext4 rw 0 0
EOF

dryrun_out="$("$apply" --plan "$plan" --secrets-dir "$secrets_src" --run-secrets-dir "$run_secrets" --mounts-file "$mounts_file" 2>&1)"
dryrun_rc=$?
[ "$dryrun_rc" -eq 0 ] || fail "dry-run should exit 0, got $dryrun_rc: $dryrun_out"
[ ! -e "$run_secrets/proToken" ] || fail "dry-run must not materialize anything"
case "$dryrun_out" in
  *"WARNING"*"wgKey"*"not tmpfs"*) ;;
  *) fail "dry-run output should include the persistent-filesystem WARNING for wgKey, got: $dryrun_out" ;;
esac
case "$dryrun_out" in
  *"install"*"-D"*"-m"*"0400"*"proToken"*) ;;
  *) fail "dry-run output should print an install command for proToken, got: $dryrun_out" ;;
esac
# The secret VALUE must never appear in the printed (dry-run) command text.
case "$dryrun_out" in
  *"pro-material"* | *"api-material"* | *"wg-material"*)
    fail "dry-run output must never leak actual secret material, got: $dryrun_out"
    ;;
esac

apply_out="$("$apply" --plan "$plan" --secrets-dir "$secrets_src" --run-secrets-dir "$run_secrets" --mounts-file "$mounts_file" --apply 2>&1)"
apply_rc=$?
[ "$apply_rc" -eq 0 ] || fail "--apply should exit 0, got $apply_rc: $apply_out"

[ -f "$run_secrets/proToken" ] || fail "--apply should have materialized $run_secrets/proToken"
[ "$(cat "$run_secrets/proToken" 2> /dev/null)" = "pro-material" ] || fail "proToken content mismatch"
[ "$(stat -c '%a' "$run_secrets/proToken" 2> /dev/null)" = "400" ] || fail "proToken mode mismatch: $(stat -c '%a' "$run_secrets/proToken" 2> /dev/null)"

[ -f "$run_secrets/apiToken.env" ] || fail "--apply should have rendered $run_secrets/apiToken.env"
[ "$(cat "$run_secrets/apiToken.env" 2> /dev/null)" = "API_TOKEN=api-material" ] || fail "apiToken.env content mismatch: $(cat "$run_secrets/apiToken.env" 2> /dev/null)"
[ "$(stat -c '%a' "$run_secrets/apiToken.env" 2> /dev/null)" = "400" ] || fail "apiToken.env mode mismatch"

[ -L "$work/run-secrets-custom-dst/wg0.key" ] || fail "--apply should have created the wgKey custom-dst symlink"
[ "$(readlink "$work/run-secrets-custom-dst/wg0.key")" = "$run_secrets/wgKey" ] || fail "wgKey symlink does not point at the canonical copy"
[ -f "$run_secrets/wgKey" ] || fail "wgKey's canonical copy should also exist"

# =====================================================================
# 2) a no-op (empty) plan is a real no-op success.
# =====================================================================
empty_plan="$work/empty-plan.json"
echo '{"version": 1, "empty": true, "materialize": {"create": [], "update": [], "remove": []}, "env": {"create": [], "update": [], "remove": []}, "symlink": {"create": []}}' > "$empty_plan"
empty_rc=0
"$apply" --plan "$empty_plan" --run-secrets-dir "$run_secrets" --apply > /dev/null 2>&1 || empty_rc=$?
[ "$empty_rc" -eq 0 ] || fail "an empty plan should exit 0, got $empty_rc"

# =====================================================================
# 3) removal: materialize.remove + env.remove actually delete real files,
#    idempotently (an already-absent target is not an error).
# =====================================================================
remove_plan="$work/remove-plan.json"
cat > "$remove_plan" <<EOF
{"version": 1, "empty": false,
 "materialize": {"create": [], "update": [], "remove": [{"name": "proToken", "dst": "/run/secrets/proToken"}]},
 "env": {"create": [], "update": [], "remove": [{"name": "apiToken", "path": "/run/secrets/apiToken.env"}]},
 "symlink": {"create": []}}
EOF
remove_rc=0
"$apply" --plan "$remove_plan" --run-secrets-dir "$run_secrets" --apply > /dev/null 2>&1 || remove_rc=$?
[ "$remove_rc" -eq 0 ] || fail "materialize/env removal should exit 0, got $remove_rc"
[ ! -e "$run_secrets/proToken" ] || fail "proToken should have been removed"
[ ! -e "$run_secrets/apiToken.env" ] || fail "apiToken.env should have been removed"

# Idempotent: removing again (already gone) must still exit 0.
remove_rc2=0
"$apply" --plan "$remove_plan" --run-secrets-dir "$run_secrets" --apply > /dev/null 2>&1 || remove_rc2=$?
[ "$remove_rc2" -eq 0 ] || fail "removing an already-absent secret must exit 0 (idempotent), got $remove_rc2"

# =====================================================================
# 4) bin/ubx-secrets observe: round-trips a real, materialized /run/secrets
#    tree (including its .env sibling and a custom-dst symlink) back into
#    the observed schema `plan` consumes.
# =====================================================================
custom_dst_dir2="$work/run-secrets-custom-dst-2"
observe_manifest="$work/observe-manifest.json"
cat > "$observe_manifest" <<EOF
{"version": 1, "secrets": [
  {"name": "wgKey", "owner": "root", "group": "root", "mode": "0400", "dst": "$custom_dst_dir2/wg0.key", "environmentVariable": null}
]}
EOF
observe_run="$work/observe-run-secrets"
mkdir -p "$observe_run" "$custom_dst_dir2"
printf 'wg-material-2' > "$observe_run/wgKey"
chmod 0400 "$observe_run/wgKey"
ln -sfn "$observe_run/wgKey" "$custom_dst_dir2/wg0.key"

observed_out="$work/observed-round-trip.json"
"$planner" observe --run-secrets-dir "$observe_run" --manifest "$observe_manifest" --out "$observed_out"
if ! python3 - "$observed_out" "$observe_run" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
run = sys.argv[2]
entries = {e["name"]: e for e in p["entries"]}
assert "wgKey" in entries, f"observe should have found wgKey, got {entries}"
e = entries["wgKey"]
assert e["mode"] == "0400", f"unexpected observed mode: {e}"
assert e["symlinkTarget"] == f"{run}/wgKey", f"unexpected observed symlinkTarget: {e}"
PYEOF
then
  fail "observe did not round-trip the materialized wgKey secret correctly"
fi

# A re-plan where the observed symlinkTarget already matches the
# declared secret's own canonical path (bin/ubx-secrets' `plan` always
# computes canonical as /run/secrets/<name>, independent of any
# --run-secrets-dir test override an executor-level observe call used) is
# a real no-op -- exercised precisely at tests/unit/163's own planner
# level (case 2, "an already-correct symlink"); this section only needs
# to confirm `observe` itself reports the real, resolved target
# faithfully (checked above), which is the half `plan`'s own no-op logic
# depends on.

# =====================================================================
# 5) real ownership: root-gated (skip 77 if not root) -- verifies a
#    non-root-owned target file is actually chown'd to a DIFFERENT real
#    unix user, mirroring this project's other privilege-gated executor
#    checks. Uses 'daemon' (uid 1, always present on a stock Ubuntu/Debian
#    system) as a real, harmless non-root target account.
# =====================================================================
if [ "$(id -u)" != 0 ]; then
  echo "SKIP: real chown-to-different-owner check requires root (uid $(id -u)) -- exiting 77"
  exit 77
fi

owner_src="$work/owner-secretsrc"
mkdir -p "$owner_src"
printf 'daemon-owned-material' > "$owner_src/daemonSecret"
owner_manifest="$work/owner-manifest.json"
cat > "$owner_manifest" <<'EOF'
{"version": 1, "secrets": [
  {"name": "daemonSecret", "owner": "daemon", "group": "daemon", "mode": "0400", "dst": "/run/secrets/daemonSecret", "environmentVariable": null}
]}
EOF
owner_plan="$work/owner-plan.json"
"$planner" plan --manifest "$owner_manifest" --out "$owner_plan"
owner_run="$work/owner-run-secrets"
"$apply" --plan "$owner_plan" --secrets-dir "$owner_src" --run-secrets-dir "$owner_run" --apply
owner_actual="$(stat -c '%U' "$owner_run/daemonSecret")"
[ "$owner_actual" = "daemon" ] || fail "expected $owner_run/daemonSecret owned by 'daemon' (real root chown), got '$owner_actual'"

exit "$fails"
