#!/usr/bin/env bash
# tests/unit/174-ubx-rebuild-pro-wiring.sh — `ubx rebuild switch|test|boot`,
# `ubx rollback`, and `ubx diff` wiring the pro domain into bin/ubx's own
# convergence orchestration, AFTER the secrets domain (SPEC.md §8.2 "Ubuntu
# Pro", §4.3; GitHub issue #82, milestone M4). Mirrors
# tests/unit/165-ubx-rebuild-secrets-wiring.sh's own overall shape, adapted
# to the pro domain's plain --apply/--dry-run gating (no snap-purge-style
# "test never applies" carve-out here -- see bin/ubx's own execute_domains
# header) and its mock-`pro`-client seam (this dev/CI harness has no real
# Ubuntu Pro client or subscription at all -- issue #87, needs-owner).
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
printf 'pro-token-material' > "$secrets_src/proToken"

secrets_manifest="$work/secrets-manifest.json"
cat > "$secrets_manifest" <<'EOF'
{"version": 1, "secrets": [
  {"name": "proToken", "owner": "root", "group": "root", "mode": "0400", "dst": "/run/secrets/proToken", "environmentVariable": null}
]}
EOF

pro_manifest="$work/pro-manifest.json"
cat > "$pro_manifest" <<'EOF'
{"version": 1, "enable": true, "tokenSecretPath": "/run/secrets/proToken", "esmApps": true, "livepatch": true}
EOF

mock_log="$work/mock-pro.log"
: > "$mock_log"
mock_pro="$work/mock-pro"
cat > "$mock_pro" <<EOF
#!/bin/sh
echo "\$*" >> "$mock_log"
exit 0
EOF
chmod +x "$mock_pro"

common_flags=(--rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --secrets-manifest "$secrets_manifest" --secrets-dir "$secrets_src" --pro-manifest "$pro_manifest" --pro-bin "$mock_pro" \
  --users-out "$work/users-out.sh" --passwd /dev/null --group /dev/null --shadow /dev/null)

# =====================================================================
# 1) `rebuild switch` (no --apply): dry-run mode, nothing invoked; the
#    pro domain's touch count is reported.
# =====================================================================
root1="$work/gens1"
run_secrets1="$work/run-secrets1"
out="$("$ubx" rebuild switch --root "$root1" --run-secrets-dir "$run_secrets1" "${common_flags[@]}" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild switch' (no --apply) should exit 0, got $rc: $out"
contains "$out" "pro: 3 action(s) touched" || fail "'rebuild switch' should report the pro domain's 3 touched actions (attach, enable esm-apps, enable livepatch), got: $out"
[ ! -s "$mock_log" ] || fail "'rebuild switch' without --apply must never invoke the pro binary, got: $(cat "$mock_log")"

# =====================================================================
# 2) `rebuild switch --apply`: real convergence, AFTER secrets (proven by
#    the attach call actually seeing the real materialized token).
# =====================================================================
root2="$work/gens2"
run_secrets2="$work/run-secrets2"
out="$("$ubx" rebuild switch --root "$root2" --run-secrets-dir "$run_secrets2" --apply "${common_flags[@]}" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild switch --apply' should exit 0, got $rc: $out"
[ -f "$run_secrets2/proToken" ] || fail "'rebuild switch --apply' should have materialized $run_secrets2/proToken (secrets block must run before pro)"

mapfile -t log_lines < "$mock_log"
[ "${#log_lines[@]}" -ge 1 ] || fail "'rebuild switch --apply' should have invoked the mock pro client at least once"
[ "${log_lines[0]:-}" = "attach pro-token-material" ] || fail "expected the pro client's first call to be a real attach reading the JUST-materialized token, got: ${log_lines[0]:-<none>}"

# =====================================================================
# 3) `rebuild test --apply`: pro DOES apply for real under `test` too
#    (unlike the snap-purge sweep) -- see bin/ubx's execute_domains header.
# =====================================================================
: > "$mock_log"
root3="$work/gens3"
run_secrets3="$work/run-secrets3"
out="$("$ubx" rebuild test --root "$root3" --run-secrets-dir "$run_secrets3" --apply "${common_flags[@]}" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild test --apply' should exit 0, got $rc: $out"
[ -s "$mock_log" ] || fail "'rebuild test --apply' should also have invoked the mock pro client for real"

# =====================================================================
# 4) `rebuild boot`: never activates anything live (boot never calls
#    execute_domains at all).
# =====================================================================
: > "$mock_log"
root4="$work/gens4"
run_secrets4="$work/run-secrets4"
out="$("$ubx" rebuild boot --root "$root4" --run-secrets-dir "$run_secrets4" --apply "${common_flags[@]}" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild boot --apply' should exit 0, got $rc: $out"
[ ! -s "$mock_log" ] || fail "'rebuild boot' must never invoke the pro binary"

# =====================================================================
# 5) omitting --pro-manifest entirely: the domain is skipped, exactly
#    like every other omitted domain ref.
# =====================================================================
root5="$work/gens5"
run_secrets5="$work/run-secrets5"
out="$("$ubx" rebuild switch --root "$root5" --run-secrets-dir "$run_secrets5" --apply \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --users-out "$work/users-out5.sh" --passwd /dev/null --group /dev/null --shadow /dev/null 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild switch --apply' with no --pro-manifest should exit 0, got $rc: $out"
contains "$out" "pro: nothing declared" || fail "'rebuild switch' with no --pro-manifest declared should report 'nothing declared', got: $out"

# =====================================================================
# 6) `ubx rollback` re-converges the pro domain too, reading the
#    generation's own pro-manifest reference back off the sidecar file.
# =====================================================================
: > "$mock_log"
root6="$work/gens6"
run_secrets6="$work/run-secrets6"
out="$("$ubx" rebuild switch --root "$root6" --run-secrets-dir "$run_secrets6" --apply "${common_flags[@]}" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "seeding generation 1 for rollback should exit 0, got $rc: $out"

out2="$("$ubx" rebuild switch --root "$root6" --run-secrets-dir "$run_secrets6" --apply "${common_flags[@]}" 2>&1)"
rc2=$?
[ "$rc2" -eq 0 ] || fail "seeding generation 2 for rollback should exit 0, got $rc2: $out2"

: > "$mock_log"
rollback_out="$("$ubx" rollback --root "$root6" --run-secrets-dir "$run_secrets6" --secrets-dir "$secrets_src" --pro-bin "$mock_pro" --apply \
  --users-out "$work/rollback-users.sh" --passwd /dev/null --group /dev/null --shadow /dev/null 2>&1)"
rollback_rc=$?
[ "$rollback_rc" -eq 0 ] || fail "'ubx rollback --apply' should exit 0, got $rollback_rc: $rollback_out"
contains "$rollback_out" "pro:" || fail "'ubx rollback' should mention the pro domain, got: $rollback_out"

# =====================================================================
# 7) `ubx diff` reports the pro domain in its verbose output.
# =====================================================================
diff_out="$("$ubx" diff --root "$root6" 2>&1)"
diff_rc=$?
[ "$diff_rc" -eq 0 ] || fail "'ubx diff' should exit 0, got $diff_rc: $diff_out"
contains "$diff_out" "pro:" || fail "'ubx diff' should mention the pro domain, got: $diff_out"

exit "$fails"
