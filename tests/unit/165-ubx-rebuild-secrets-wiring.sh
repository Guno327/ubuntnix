#!/usr/bin/env bash
# tests/unit/165-ubx-rebuild-secrets-wiring.sh — `ubx rebuild switch|test|
# boot`, `ubx rollback`, and `ubx diff` wiring the secrets domain into
# bin/ubx's own convergence orchestration (SPEC.md §4.3 "none" downtime;
# GitHub issue #78, milestone M4). Mirrors tests/unit/139-ubx-etc-apply.sh's
# own end-to-end section and tests/unit/150-ubx-rebuild-snap-apply-wiring.sh's
# overall shape, adapted to the secrets domain's plain --apply/--dry-run
# gating (no snap-purge-style "test never applies" carve-out here -- see
# bin/ubx's own execute_domains header for exactly why).
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

ubx="$UBX_REPO_ROOT/bin/ubx"
[ -x "$ubx" ] || { echo "FAIL: $ubx does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

export UBX_SOFT_REBOOT_CMD=true
export UBX_NEXTROOT_STAGE_CMD=true

secrets_src="$work/secretsrc"
mkdir -p "$secrets_src"
printf 'pro-material' > "$secrets_src/proToken"

secrets_manifest="$work/secrets-manifest.json"
cat > "$secrets_manifest" <<'EOF'
{"version": 1, "secrets": [
  {"name": "proToken", "owner": "root", "group": "root", "mode": "0400", "dst": "/run/secrets/proToken", "environmentVariable": null}
]}
EOF

common_flags=(--rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --secrets-manifest "$secrets_manifest" --secrets-dir "$secrets_src" \
  --users-out "$work/users-out.sh" --passwd /dev/null --group /dev/null --shadow /dev/null)

# =====================================================================
# 1) `rebuild switch` (no --apply): dry-run mode, nothing materialized.
# =====================================================================
root1="$work/gens1"
run_secrets1="$work/run-secrets1"
out="$("$ubx" rebuild switch --root "$root1" --run-secrets-dir "$run_secrets1" "${common_flags[@]}" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild switch' (no --apply) should exit 0, got $rc: $out"
contains "$out" "secrets: 1 action(s) touched" || fail "'rebuild switch' should report the secrets domain touch count, got: $out"
[ ! -e "$run_secrets1/proToken" ] || fail "'rebuild switch' without --apply must not materialize anything"

# =====================================================================
# 2) `rebuild switch --apply`: real materialization.
# =====================================================================
root2="$work/gens2"
run_secrets2="$work/run-secrets2"
out="$("$ubx" rebuild switch --root "$root2" --run-secrets-dir "$run_secrets2" --apply "${common_flags[@]}" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild switch --apply' should exit 0, got $rc: $out"
[ -f "$run_secrets2/proToken" ] || fail "'rebuild switch --apply' should have materialized $run_secrets2/proToken"
[ "$(cat "$run_secrets2/proToken" 2> /dev/null)" = "pro-material" ] || fail "materialized proToken content mismatch"

# =====================================================================
# 3) `rebuild test --apply`: secrets DOES apply for real under `test`
#    too (unlike the snap-purge sweep) -- materializing a secret is safe
#    to retry/roll back from (bin/ubx's execute_domains header).
# =====================================================================
root3="$work/gens3"
run_secrets3="$work/run-secrets3"
out="$("$ubx" rebuild test --root "$root3" --run-secrets-dir "$run_secrets3" --apply "${common_flags[@]}" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild test --apply' should exit 0, got $rc: $out"
[ -f "$run_secrets3/proToken" ] || fail "'rebuild test --apply' should also have materialized $run_secrets3/proToken"

# =====================================================================
# 4) `rebuild boot`: never activates anything live (boot never calls
#    execute_domains at all).
# =====================================================================
root4="$work/gens4"
run_secrets4="$work/run-secrets4"
out="$("$ubx" rebuild boot --root "$root4" --run-secrets-dir "$run_secrets4" --apply "${common_flags[@]}" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild boot --apply' should exit 0, got $rc: $out"
[ ! -e "$run_secrets4/proToken" ] || fail "'rebuild boot' must never materialize anything"

# =====================================================================
# 5) omitting --secrets-manifest entirely: the domain is skipped, exactly
#    like every other omitted domain ref.
# =====================================================================
root5="$work/gens5"
run_secrets5="$work/run-secrets5"
out="$("$ubx" rebuild switch --root "$root5" --run-secrets-dir "$run_secrets5" --apply \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --users-out "$work/users-out5.sh" --passwd /dev/null --group /dev/null --shadow /dev/null 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild switch --apply' with no --secrets-manifest should exit 0, got $rc: $out"
contains "$out" "secrets: nothing declared" || fail "'rebuild switch' with no --secrets-manifest declared should report 'nothing declared', got: $out"
[ ! -d "$run_secrets5" ] || fail "'rebuild switch' with no --secrets-manifest declared must not create $run_secrets5 at all"

# =====================================================================
# 6) `ubx rollback` re-converges the secrets domain too, reading the
#    generation's own secrets-manifest reference back off the sidecar
#    file (bin/ubx-rebuild-lib's ubx_rebuild_write_sidecar/domain_refs).
# =====================================================================
root6="$work/gens6"
run_secrets6="$work/run-secrets6"
out="$("$ubx" rebuild switch --root "$root6" --run-secrets-dir "$run_secrets6" --apply "${common_flags[@]}" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "seeding generation 1 for rollback should exit 0, got $rc: $out"
[ -f "$run_secrets6/proToken" ] || fail "seeded generation should have materialized proToken"

# `rollback previous` (the default target) needs at least two registered
# generations to have a "previous" pointer at all -- register a second one
# (still declaring the same secrets manifest) before removing the
# materialized copy and rolling back to prove it gets re-materialized.
out2="$("$ubx" rebuild switch --root "$root6" --run-secrets-dir "$run_secrets6" --apply "${common_flags[@]}" 2>&1)"
rc2=$?
[ "$rc2" -eq 0 ] || fail "seeding generation 2 for rollback should exit 0, got $rc2: $out2"

rm -f "$run_secrets6/proToken"

# Absent an explicit --secrets-observed, plan_domains' own default
# SYNTHESIZES the observed state from the OLD generation's own declared
# manifest (assuming it is already fully converged -- see
# secrets_synthesize_observed's own comment in bin/ubx) -- which would
# never notice the file this test just deleted by hand (a real machine
# never needs this override: /run/secrets is tmpfs and starts genuinely
# empty every real boot). A real, live observe of the (now-empty)
# run_secrets6 directory is what makes this scenario re-plan a real
# `materialize.create` for proToken, exactly the observed-override seam
# --etc-observed/--systemd-observed/--snap-observed already establish for
# their own domains.
secrets_observed6="$work/secrets-observed6.json"
"$UBX_REPO_ROOT/bin/ubx-secrets" observe --run-secrets-dir "$run_secrets6" --out "$secrets_observed6"

rollback_out="$("$ubx" rollback --root "$root6" --run-secrets-dir "$run_secrets6" --secrets-dir "$secrets_src" --apply \
  --secrets-observed "$secrets_observed6" \
  --users-out "$work/rollback-users.sh" --passwd /dev/null --group /dev/null --shadow /dev/null 2>&1)"
rollback_rc=$?
[ "$rollback_rc" -eq 0 ] || fail "'ubx rollback --apply' should exit 0, got $rollback_rc: $rollback_out"
[ -f "$run_secrets6/proToken" ] || fail "'ubx rollback --apply' should have re-materialized proToken"

# =====================================================================
# 7) `ubx diff` reports the secrets domain in its verbose output.
# =====================================================================
diff_out="$("$ubx" diff --root "$root6" 2>&1)"
diff_rc=$?
[ "$diff_rc" -eq 0 ] || fail "'ubx diff' should exit 0, got $diff_rc: $diff_out"
contains "$diff_out" "secrets:" || fail "'ubx diff' should mention the secrets domain, got: $diff_out"

exit "$fails"
