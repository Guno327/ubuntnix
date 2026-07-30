#!/usr/bin/env bash
# tests/unit/206-ubx-pro-token.sh — the install-time Ubuntu Pro token
# prompt+store+attach acceptance criterion (SPEC.md §10 installer step 4:
# "prompts for an Ubuntu Pro token (required; free personal tokens), stores
# it via the secrets mechanism, and attaches"; SPEC.md §8.2; GitHub issue
# #115). Mirrors tests/unit/205-ubx-flake-init.sh's own structure and skip
# contract (a REAL throwaway flake, initialized via the real
# bin/ubx-flake-init, and a REAL throwaway git-crypt/gpg setup -- this test
# NEVER touches this project's own repository, keys, /var, or a real 'pro'
# client) and tests/unit/173-ubx-pro-apply-executor.sh's own recording-mock
# style for the attach half. Proves:
#
#   1. `bin/ubx-pro-token --token VALUE` against a flake bin/ubx-flake-init
#      already initialized routes the token into secrets/pro-token and
#      commits it GIT-CRYPT-ENCRYPTED AT REST -- the committed blob is not
#      the plaintext token -- while secrets/index.nix stays plaintext.
#   2. The token value never appears ANYWHERE in the git object store (a
#      grep across every committed blob/pack, not just secrets/pro-token's
#      own), and never appears in this script's own captured stdout/stderr.
#   3. The real, landed bin/ubx-pro-apply attach codepath is actually
#      invoked, behind a recording mock `pro` binary, with the real stored
#      token value as its argv -- proving this script drives the real
#      attach path, not a reimplementation of it.
#   4. A second run with the SAME token is a real no-op commit-wise
#      (idempotent), and the mock is invoked again (attach is not
#      "already attached, skip" logic this script's own job -- that
#      decision belongs to bin/ubx-pro's planner, not this one-shot
#      install-time step).
#   5. A missing token (no --token/--token-file, non-interactive stdin) is
#      a clear required-field error, nonzero exit, no files touched.
#
# Requires `git-crypt`, `gpg`, and `git` (bin/ubx-flake-init's own
# dependency set, exercised here first to get a real encrypted flake to
# store the token into). Skips cleanly (exit 77) rather than hard-failing,
# IMMEDIATELY, before a single `git`/`gpg` command runs -- mirrors 205's
# own ordering.
set -u

cd "$UBX_REPO_ROOT" || exit 1

missing=""
command -v git-crypt > /dev/null 2>&1 || missing="${missing}git-crypt "
command -v gpg > /dev/null 2>&1 || missing="${missing}gpg "
command -v git > /dev/null 2>&1 || missing="${missing}git "
if [ -n "$missing" ]; then
  echo "SKIP: tests/unit/206 needs $missing(not installed) to exercise a real install-time Pro token flow" >&2
  exit 77
fi

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

flake_init="$UBX_REPO_ROOT/bin/ubx-flake-init"
bin="$UBX_REPO_ROOT/bin/ubx-pro-token"
[ -x "$flake_init" ] || { echo "FAIL: $flake_init does not exist or is not executable" >&2; exit 1; }
[ -x "$bin" ] || { echo "FAIL: $bin does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

flake="$work/flake"
gnupg_home="$work/gpg-machine"
uid="pro-token-machine <a@example.invalid>"
run_secrets="$work/run-secrets"

# -- get a real, git-crypt-initialized, unlocked flake to store into -------
init_rc=0
init_out="$("$flake_init" --flake "$flake" --config "$UBX_REPO_ROOT/examples/server.nix" \
  --gnupg-home "$gnupg_home" --uid "$uid" 2>&1)" || init_rc=$?
[ "$init_rc" -eq 0 ] || { echo "FAIL: prerequisite ubx-flake-init run failed (rc=$init_rc): $init_out" >&2; exit 1; }

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

token="super-secret-pro-token-0123456789"

# =====================================================================
# (5) missing token, non-interactive -- required-field error, no files
#     touched, BEFORE the happy path below leaves any material behind to
#     confuse this assertion.
# =====================================================================
missing_rc=0
missing_out="$("$bin" --flake "$flake" --run-secrets-dir "$run_secrets" --pro-bin "$mock_pro" \
  < /dev/null 2>&1)" || missing_rc=$?
[ "$missing_rc" -ne 0 ] || fail "missing token should be a nonzero-exit error, got rc=0: $missing_out"
case "$missing_out" in
  *"required"*) ;;
  *) fail "expected a clear required-field error for a missing token, got: $missing_out" ;;
esac
[ ! -e "$flake/secrets/pro-token" ] || fail "secrets/pro-token was created despite the missing-token error"
[ ! -s "$mock_log" ] || fail "the pro mock must never be invoked when no token was provided, got: $(cat "$mock_log")"

# =====================================================================
# (1)+(2)+(3): the happy path -- store, encrypt at rest, attach for real
#              (behind the mock).
# =====================================================================
apply_rc=0
apply_out="$("$bin" --flake "$flake" --token "$token" --run-secrets-dir "$run_secrets" \
  --pro-bin "$mock_pro" 2>&1)" || apply_rc=$?
[ "$apply_rc" -eq 0 ] || fail "ubx-pro-token --token run failed (rc=$apply_rc): $apply_out"

case "$apply_out" in
  *"$token"*) fail "ubx-pro-token's own stdout/stderr leaked the token value verbatim: $apply_out" ;;
esac

[ -f "$flake/secrets/pro-token" ] || fail "$flake/secrets/pro-token was not created"

blob="$(git -C "$flake" show "HEAD:secrets/pro-token" 2> /dev/null || true)"
if [ "$blob" = "$token" ]; then
  fail "secrets/pro-token is stored as PLAINTEXT in the git object -- ubx-pro-token did not route it through git-crypt encryption at rest"
fi

index_blob="$(git -C "$flake" show "HEAD:secrets/index.nix" 2> /dev/null || true)"
printf '%s' "$index_blob" | grep -q 'proToken' ||
  fail "secrets/index.nix is not readable as plaintext straight from the git object"

# -- (2): the token value never appears ANYWHERE in the git object store ---
if git -C "$flake" cat-file --batch-all-objects --batch-check 2>/dev/null \
    | awk '{print $1}' \
    | xargs -r -n1 git -C "$flake" cat-file -p 2>/dev/null \
    | grep -qF -- "$token"; then
  fail "the raw token value was found somewhere in the git object store -- it must exist ONLY as git-crypt ciphertext"
fi

# -- (3): the mock recorded a real attach referencing the materialized token
[ -f "$run_secrets/proToken" ] || fail "the token was not materialized at $run_secrets/proToken for ubx-pro-apply's own attach codepath to read"
materialized="$(cat "$run_secrets/proToken" 2>/dev/null || true)"
[ "$materialized" = "$token" ] || fail "materialized $run_secrets/proToken does not hold the real token bytes (got: $materialized)"

mock_calls="$(cat "$mock_log")"
case "$mock_calls" in
  *"attach $token"*) ;;
  *) fail "expected the mock pro binary to record 'attach $token', got: $mock_calls" ;;
esac

# =====================================================================
# (4): a second run with the SAME token is commit-idempotent, and still
#      drives a real attach call each time (this script's own job is
#      "make sure it's stored+attached", not "was it already attached").
# =====================================================================
before_head="$(git -C "$flake" rev-parse HEAD)"
: > "$mock_log"
rerun_rc=0
rerun_out="$("$bin" --flake "$flake" --token "$token" --run-secrets-dir "$run_secrets" \
  --pro-bin "$mock_pro" 2>&1)" || rerun_rc=$?
[ "$rerun_rc" -eq 0 ] || fail "second (idempotent) ubx-pro-token run failed (rc=$rerun_rc): $rerun_out"
after_head="$(git -C "$flake" rev-parse HEAD)"
[ "$before_head" = "$after_head" ] || fail "a second run with the SAME token created a new commit -- not idempotent (before=$before_head after=$after_head)"
dirty="$(git -C "$flake" status --porcelain)"
[ -z "$dirty" ] || fail "working tree is not clean after a second ubx-pro-token run: $dirty"
case "$(cat "$mock_log")" in
  *"attach $token"*) ;;
  *) fail "expected the second run to still drive a real attach call, got: $(cat "$mock_log")" ;;
esac

exit "$fails"
