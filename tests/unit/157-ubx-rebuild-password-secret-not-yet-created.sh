#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $6$...$ crypt hashes are intentionally single-quoted (must NOT shell-expand)
# tests/unit/157-ubx-rebuild-password-secret-not-yet-created.sh —
# `ubx rebuild switch --apply`'s FIRST-ever convergence of a brand-new
# hashedPasswordSecret user (GitHub issue #90, milestone M4): the account
# does not exist in --shadow yet, so `ubx-users execute` only ever EMITS
# an activation script (bin/ubx's own execute_domains, "users" block) and
# `ubx-users apply-passwords` (the "password hashes" block right after it)
# cannot set a password for an account not yet present in --shadow. This
# is the exact scenario nix/boot.nix's own "M4: hashedPasswordSecret login
# proof" e2e driver runs as its FIRST of two real switches, and this test
# pins the underlying `bin/ubx` behaviour that driver's own narrowed
# assertion (GitHub issue #153) relies on: the activation script IS
# emitted, the run's own JSON summary reports EXACTLY ONE error -- the
# documented "not present in shadow" one, naming this run's own user --
# and nothing else, and the process exits 1 (bin/ubx-users' own
# cmd_apply_passwords: `sys.exit(1 if errors else 0)`, propagated by
# bin/ubx's own `set -euo pipefail`). Mirrors tests/unit/109-ubx-rebuild-
# password-secret-wiring.sh's own end-to-end shape, one case deeper.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
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

# alice deliberately absent from passwd/group/shadow -- exactly the
# "brand-new user, never created yet" starting state.
passwd="$work/passwd"
printf 'root:x:0:0:root:/root:/bin/bash\n' > "$passwd"
group="$work/group"
printf 'root:x:0:\n' > "$group"
shadow="$work/shadow"
printf 'root:*:19000:0:99999:7:::\n' > "$shadow"

root1="$work/gens1"
run_secrets1="$work/run-secrets1"
users_out="$work/users-activate.sh"

out="$("$ubx" rebuild switch --root "$root1" --run-secrets-dir "$run_secrets1" --shadow "$shadow" --apply \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --secrets-manifest "$secrets_manifest" --secrets-dir "$secrets_src" \
  --users-manifest "$users_manifest" --passwd "$passwd" --group "$group" \
  --users-out "$users_out" 2>&1)"
rc=$?

# -- exit code: exactly 1 (apply-passwords' own documented error), never
#    0 (that would mean the password silently never converged) and never
#    anything else (that would be a crash/regression, not this documented
#    outcome).
[ "$rc" -eq 1 ] \
  || fail "first-ever 'rebuild switch --apply' for a not-yet-created hashedPasswordSecret user should exit 1, got $rc: $out"

# -- the users activation script is still emitted, even though the run as
#    a whole fails downstream (account creation is a real, useful side
#    effect of this run, not something a caller should lose).
[ -s "$users_out" ] \
  || fail "'rebuild switch --apply' should still have emitted a non-empty users activation script to $users_out, got: $out"
grep -q "useradd\|adduser" "$users_out" \
  || fail "$users_out does not look like a real user-creation activation script, got: $(cat "$users_out" 2> /dev/null)"

# -- the secrets domain still materializes for real (it runs BEFORE the
#    users domain, GitHub issue #80's own ordering requirement) even
#    though the users domain's own password_set step fails afterward.
[ -f "$run_secrets1/alicePw" ] \
  || fail "'rebuild switch --apply' should have materialized $run_secrets1/alicePw even though apply-passwords itself failed"

# -- neither passwd/group/shadow was mutated by this run: a failed
#    apply-passwords must never partially apply.
grep -qxF 'root:*:19000:0:99999:7:::' "$shadow" \
  || fail "a failed apply-passwords run must not have mutated $shadow, got: $(cat "$shadow")"

# -- the run's own JSON summary (printed to stdout, execute_domains never
#    passes apply-passwords an --out file) reports EXACTLY ONE error: the
#    documented "not present in shadow" one, naming 'alice' and this run's
#    own --shadow path -- never zero errors (that would silently drop the
#    failure) and never any OTHER/ADDITIONAL error (that would mask a real
#    regression as this expected, benign one).
json="$(printf '%s\n' "$out" | sed -n '/^{$/,/^}$/p')"
[ -n "$json" ] || fail "could not find a JSON summary block in 'rebuild switch' output: $out"
printf '%s\n' "$json" | UBX_TEST_SHADOW_PATH="$shadow" python3 -c "
import json, os, sys
d = json.load(sys.stdin)
assert d['applied'] is True, d
assert d['changed'] == [], d
expected = [
    \"user 'alice': not present in \" + os.environ['UBX_TEST_SHADOW_PATH'] +
    \" (create the user, e.g. via 'ubx-users execute', before setting its password)\"
]
assert d['errors'] == expected, d
" || fail "'rebuild switch' JSON summary should report exactly one 'not present in shadow' error for alice and nothing else, got: $json"

exit "$fails"
