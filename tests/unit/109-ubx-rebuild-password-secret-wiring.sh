#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $6$...$ crypt hashes are intentionally single-quoted (must NOT shell-expand)
# tests/unit/109-ubx-rebuild-password-secret-wiring.sh — `ubx rebuild
# switch` wiring hashedPasswordSecret end to end: the secrets domain is
# planned/applied BEFORE the users domain, `ubx-users plan` cross-checks
# hashedPasswordSecret against the secrets domain's own NEW manifest, and
# `ubx-users apply-passwords` converges a real (fixture) shadow file from
# the secret's real materialized bytes (SPEC.md §6, §8.1; GitHub issue #80,
# milestone M4). Mirrors tests/unit/165-ubx-rebuild-secrets-wiring.sh's own
# end-to-end shape.
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
printf '$6$fakesalt$alicehash\n' > "$secrets_src/alicePw"

secrets_manifest="$work/secrets-manifest.json"
cat > "$secrets_manifest" << 'EOF'
{"version": 1, "secrets": [
  {"name": "alicePw", "owner": "root", "group": "root", "mode": "0400", "dst": "/run/secrets/alicePw", "environmentVariable": null}
]}
EOF

users_manifest="$work/users-manifest.json"
cat > "$users_manifest" << 'EOF'
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

passwd="$work/passwd"
printf 'root:x:0:0:root:/root:/bin/bash\nalice:x:1000:1000:alice:/home/alice:/usr/bin/bash\n' > "$passwd"
group="$work/group"
printf 'root:x:0:\nalice:x:1000:\n' > "$group"

common_flags=(--rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --secrets-manifest "$secrets_manifest" --secrets-dir "$secrets_src" \
  --users-manifest "$users_manifest" --passwd "$passwd" --group "$group")

# =====================================================================
# 1) `rebuild switch --apply`: secrets get materialized AND the fixture
#    shadow file gets alice's hash set, in ONE run -- proves secrets
#    delivery lands before ubx-users apply-passwords reads it back.
# =====================================================================
root1="$work/gens1"
run_secrets1="$work/run-secrets1"
shadow1="$work/shadow1"
printf 'root:*:19000:0:99999:7:::\nalice:!:19000:0:99999:7:::\n' > "$shadow1"

out="$("$ubx" rebuild switch --root "$root1" --run-secrets-dir "$run_secrets1" --shadow "$shadow1" --apply "${common_flags[@]}" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild switch --apply' should exit 0, got $rc: $out"
[ -f "$run_secrets1/alicePw" ] || fail "'rebuild switch --apply' should have materialized $run_secrets1/alicePw"
grep -qxF 'alice:$6$fakesalt$alicehash:19000:0:99999:7:::' "$shadow1" \
  || fail "'rebuild switch --apply' should have set alice's password hash in $shadow1, got: $(grep alice "$shadow1")"
contains "$out" "users: 1 action(s) touched" || fail "'rebuild switch' should report 1 users action (the password_set), got: $out"

# =====================================================================
# 2) `rebuild switch` WITHOUT --apply: dry-run only, nothing materialized,
#    shadow untouched.
# =====================================================================
root2="$work/gens2"
run_secrets2="$work/run-secrets2"
shadow2="$work/shadow2"
printf 'root:*:19000:0:99999:7:::\nalice:!:19000:0:99999:7:::\n' > "$shadow2"

out2="$("$ubx" rebuild switch --root "$root2" --run-secrets-dir "$run_secrets2" --shadow "$shadow2" "${common_flags[@]}" 2>&1)"
rc2=$?
[ "$rc2" -eq 0 ] || fail "'rebuild switch' (no --apply) should exit 0, got $rc2: $out2"
[ ! -e "$run_secrets2/alicePw" ] || fail "'rebuild switch' without --apply must not materialize anything"
grep -qxF 'alice:!:19000:0:99999:7:::' "$shadow2" || fail "'rebuild switch' without --apply must not touch $shadow2"

# =====================================================================
# 3) hashedPasswordSecret referencing an UNDECLARED secret: 'ubx-users
#    plan' refuses, and 'ubx rebuild' propagates that as a hard failure
#    (never silently proceeds without the password domain converged).
# =====================================================================
root3="$work/gens3"
run_secrets3="$work/run-secrets3"
shadow3="$work/shadow3"
printf 'root:*:19000:0:99999:7:::\nalice:!:19000:0:99999:7:::\n' > "$shadow3"

out3="$("$ubx" rebuild switch --root "$root3" --run-secrets-dir "$run_secrets3" --shadow "$shadow3" --apply \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --secrets-dir "$secrets_src" \
  --users-manifest "$users_manifest" --passwd "$passwd" --group "$group" 2>&1)"
rc3=$?
[ "$rc3" -ne 0 ] || fail "'rebuild switch --apply' with hashedPasswordSecret but no --secrets-manifest declared should fail, got exit 0: $out3"
contains "$out3" "hashedPasswordSecret" || fail "the failure should mention hashedPasswordSecret, got: $out3"
[ ! -e "$run_secrets3/alicePw" ] || fail "a refused plan must never have materialized anything"
grep -qxF 'alice:!:19000:0:99999:7:::' "$shadow3" || fail "a refused plan must not have mutated $shadow3"

exit "$fails"
