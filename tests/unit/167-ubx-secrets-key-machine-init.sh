#!/usr/bin/env bash
# tests/unit/167-ubx-secrets-key-machine-init.sh — bin/ubx-secrets-key
# machine-init (SPEC.md §8.1 "The installer generates a machine keypair
# (stored root-only outside the store)"; GitHub issue #79, milestone M4
# groundwork). Exercises the keygen half of onboarding end to end with a
# REAL gpg keypair in a throwaway --gnupg-home (never touches a real
# GNUPGHOME, never touches git or git-crypt at all -- see
# tests/unit/168-secrets-gitcrypt-roundtrip.sh for the git-crypt-dependent
# collaborator-add half).
#
# Skips cleanly (exit 77 -- tests/README.md's documented skip contract,
# also honored by tests/run.sh for tests/unit/*, not just tests/e2e/*) if
# `gpg` is not installed, rather than hard-failing the whole suite on a
# missing external tool.
set -u

cd "$UBX_REPO_ROOT" || exit 1

if ! command -v gpg > /dev/null 2>&1; then
  echo "SKIP: gpg is not installed -- tests/unit/167 needs a real gpg to exercise key generation" >&2
  exit 77
fi

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

bin="$UBX_REPO_ROOT/bin/ubx-secrets-key"
[ -x "$bin" ] || {
  echo "FAIL: $bin does not exist or is not executable" >&2
  exit 1
}

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

gnupg_home="$work/gpg"
uid="ubuntnix-test-machine <test@example.invalid>"

# -- first run: generates a fresh keypair ------------------------------------
out1=""
rc1=0
out1="$("$bin" machine-init --gnupg-home "$gnupg_home" --uid "$uid" 2>&1)" || rc1=$?
[ "$rc1" -eq 0 ] || fail "first machine-init run failed (rc=$rc1): $out1"

fpr1="$(printf '%s\n' "$out1" | tail -1)"
case "$fpr1" in
  [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]*) ;;
  *) fail "first run's last line does not look like a GPG fingerprint: $fpr1" ;;
esac

case "$out1" in
  *"generated new machine GPG identity"*) ;;
  *) fail "first run's stderr does not announce generating a new identity: $out1" ;;
esac

# -- path/permission behavior: root-only outside any store ------------------
[ -d "$gnupg_home" ] || fail "$gnupg_home was not created"

case "$gnupg_home" in
  */ubx/store/* | */ubx/store) fail "GNUPGHOME landed under a store-like path: $gnupg_home" ;;
esac

perm="$(stat -c '%a' "$gnupg_home" 2>/dev/null || echo '?')"
[ "$perm" = "700" ] || fail "GNUPGHOME dir mode is $perm, expected 700 (root-only)"

# Every regular file under GNUPGHOME must be 600 (no group/other access to
# key material) -- this is what "root-only" means once euid isn't actually
# 0 in this dev harness (see bin/ubx-secrets-key's own header,
# "Privilege": chmod always runs, chown-to-root only runs as real root).
bad_perms="$(find "$gnupg_home" -type f ! -perm 600 2>/dev/null)"
[ -z "$bad_perms" ] || fail "file(s) under $gnupg_home are not mode 600: $bad_perms"

bad_dir_perms="$(find "$gnupg_home" -type d ! -perm 700 2>/dev/null)"
[ -z "$bad_dir_perms" ] || fail "subdirectorie(s) under $gnupg_home are not mode 700: $bad_dir_perms"

# A real secret key must actually exist for the declared uid.
GNUPGHOME="$gnupg_home" gpg --batch --with-colons --list-secret-keys -- "$uid" 2>/dev/null | grep -q '^sec:' ||
  fail "no secret key found for uid '$uid' in $gnupg_home after machine-init"

# -- idempotence: second run must NOT regenerate or duplicate ---------------
before_snapshot="$(find "$gnupg_home" -type f -name '*.key' | sort)"
key_count_before="$(printf '%s\n' "$before_snapshot" | grep -c . || true)"

out2=""
rc2=0
out2="$("$bin" machine-init --gnupg-home "$gnupg_home" --uid "$uid" 2>&1)" || rc2=$?
[ "$rc2" -eq 0 ] || fail "second (idempotent) machine-init run failed (rc=$rc2): $out2"

fpr2="$(printf '%s\n' "$out2" | tail -1)"
[ "$fpr2" = "$fpr1" ] || fail "second run produced a DIFFERENT fingerprint ($fpr2) than the first ($fpr1) -- machine-init must reuse the existing identity, not regenerate"

case "$out2" in
  *"already exists"*"skipping generation"*) ;;
  *) fail "second run's stderr does not report skipping generation as already-existing: $out2" ;;
esac

after_snapshot="$(find "$gnupg_home" -type f -name '*.key' | sort)"
key_count_after="$(printf '%s\n' "$after_snapshot" | grep -c . || true)"
[ "$key_count_after" -eq "$key_count_before" ] ||
  fail "the number of private key files changed across a re-run ($key_count_before -> $key_count_after) -- machine-init duplicated key material"

[ "$before_snapshot" = "$after_snapshot" ] ||
  fail "the set of private key filenames changed across a re-run -- machine-init clobbered existing key material"

# -- a DIFFERENT uid in the SAME gnupg-home generates a SECOND, independent
# identity (machine-init is per-uid idempotent, not "at most one key ever") -
out3=""
rc3=0
out3="$("$bin" machine-init --gnupg-home "$gnupg_home" --uid "another-uid <other@example.invalid>" 2>&1)" || rc3=$?
[ "$rc3" -eq 0 ] || fail "machine-init for a second, different uid failed (rc=$rc3): $out3"
fpr3="$(printf '%s\n' "$out3" | tail -1)"
[ "$fpr3" != "$fpr1" ] || fail "a different --uid produced the SAME fingerprint as the first identity"

exit "$fails"
