#!/usr/bin/env bash
# tests/unit/205-ubx-flake-init.sh — the /flake init flow acceptance
# criterion (SPEC.md §10 installer step 3: "Initialize `/flake` as a git
# repository containing that example configuration, with git-crypt set up
# for the `secrets/` folder and a generated per-machine GPG identity added
# as a collaborator"; GitHub issue #114). Mirrors
# tests/unit/168-secrets-gitcrypt-roundtrip.sh's own structure, skip
# contract, and style: proves, end to end, with a REAL throwaway GPG key
# and a REAL throwaway git repository (both created fresh under temp dirs
# -- this test NEVER touches this project's own repository, keys, /var, or
# remotes):
#
#   1. `bin/ubx-flake-init --flake THROWAWAY --gnupg-home THROWAWAY` turns
#      the throwaway dir into a git repo with git-crypt initialized.
#   2. The machine's own GPG key actually exists in the throwaway
#      --gnupg-home afterward.
#   3. A file placed under the flake's own secrets/ (the committed
#      index.nix's own sibling material, same as 168) is ENCRYPTED AT REST
#      -- `git show` returns ciphertext, not plaintext -- while
#      secrets/index.nix is committed PLAINTEXT.
#   4. `git-crypt status` reports clean.
#   5. The machine key is a WORKING collaborator: a SECOND, independently
#      generated key that was never added as a collaborator CANNOT
#      `git-crypt unlock` the repo -- a real access-control proof, exactly
#      168's own final assertion.
#   6. Running ubx-flake-init a SECOND time against the SAME --flake/
#      --gnupg-home is a real no-op: the working tree stays clean and no
#      duplicate `.git-crypt/keys/*/0/*.gpg` collaborator file appears.
#
# Requires `git-crypt`, `gpg`, and `git`. Skips cleanly (exit 77,
# tests/README.md's documented skip contract) rather than hard-failing the
# suite, IMMEDIATELY, before this script ever invokes a single `git`
# command -- see 168's own comment for exactly why that ordering matters.
set -u

cd "$UBX_REPO_ROOT" || exit 1

missing=""
command -v git-crypt > /dev/null 2>&1 || missing="${missing}git-crypt "
command -v gpg > /dev/null 2>&1 || missing="${missing}gpg "
command -v git > /dev/null 2>&1 || missing="${missing}git "
if [ -n "$missing" ]; then
  echo "SKIP: tests/unit/205 needs $missing(not installed) to exercise a real /flake init flow" >&2
  exit 77
fi

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

bin="$UBX_REPO_ROOT/bin/ubx-flake-init"
[ -x "$bin" ] || {
  echo "FAIL: $bin does not exist or is not executable" >&2
  exit 1
}

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

flake="$work/flake"
gnupg_home_a="$work/gpg-machine"
uid_a="flake-init-machine-a <a@example.invalid>"

# -- (1)+(2): first run initializes the flake and generates the machine key -
out1=""
rc1=0
out1="$("$bin" --flake "$flake" --config "$UBX_REPO_ROOT/examples/server.nix" \
  --gnupg-home "$gnupg_home_a" --uid "$uid_a" 2>&1)" || rc1=$?
[ "$rc1" -eq 0 ] || fail "first ubx-flake-init run failed (rc=$rc1): $out1"

[ -d "$flake/.git" ] || fail "$flake was not initialized as a git repository"
[ -d "$flake/.git-crypt" ] || fail "$flake does not have git-crypt initialized"
[ -f "$flake/configuration.nix" ] || fail "$flake/configuration.nix was not materialized"

GNUPGHOME="$gnupg_home_a" gpg --batch --with-colons --list-secret-keys -- "$uid_a" 2>/dev/null | grep -q '^sec:' ||
  fail "no machine GPG secret key found for uid '$uid_a' in $gnupg_home_a after ubx-flake-init"

# -- place a secret material file under secrets/, commit it, and prove it is
# encrypted at rest (mirrors tests/unit/168's own steps 1+2) -----------------
secret_plaintext="flake-init-super-secret-0123456789"
printf '%s\n' "$secret_plaintext" > "$flake/secrets/pro-token"
( cd "$flake" && git add secrets && \
  git -c user.name="test" -c user.email="test@example.invalid" \
    commit --quiet -m "add secrets/pro-token" ) ||
  fail "failed to commit a secret material file into $flake/secrets"

blob="$(git -C "$flake" show "HEAD:secrets/pro-token" 2> /dev/null || true)"
if [ "$blob" = "$secret_plaintext" ]; then
  fail "secrets/pro-token is stored as PLAINTEXT in the git object -- ubx-flake-init did not actually wire up git-crypt encryption at rest"
fi

index_blob="$(git -C "$flake" show "HEAD:secrets/index.nix" 2> /dev/null || true)"
printf '%s' "$index_blob" | grep -q 'proToken' ||
  fail "secrets/index.nix is not readable as plaintext straight from the git object"

# -- (4): git-crypt status reports clean -------------------------------------
status_rc=0
status_out=""
status_out="$(cd "$flake" && GNUPGHOME="$gnupg_home_a" git-crypt status 2>&1)" || status_rc=$?
[ "$status_rc" -eq 0 ] || fail "git-crypt status failed (rc=$status_rc): $status_out"
printf '%s' "$status_out" | grep -qi 'encrypted: secrets/pro-token' ||
  fail "git-crypt status does not report secrets/pro-token as encrypted: $status_out"

# -- (5): a SECOND, never-onboarded key cannot unlock the same repo ---------
gnupg_home_b="$work/gpg-machine-b"
out_b=""
rc_b=0
out_b="$("$UBX_REPO_ROOT/bin/ubx-secrets-key" machine-init --gnupg-home "$gnupg_home_b" \
  --uid "flake-init-machine-b <b@example.invalid>" --no-collaborator 2>&1)" || rc_b=$?
[ "$rc_b" -eq 0 ] || fail "machine-init for the never-onboarded second identity failed (rc=$rc_b): $out_b"

clone_b="$work/clone-b"
git clone --quiet "$flake" "$clone_b"

unlock_b_rc=0
( cd "$clone_b" && GNUPGHOME="$gnupg_home_b" git-crypt unlock ) > /dev/null 2>&1 || unlock_b_rc=$?
[ "$unlock_b_rc" -ne 0 ] ||
  fail "git-crypt unlock SUCCEEDED with a key that was never added as a collaborator -- this is a real access-control break"

still_locked="$(cat "$clone_b/secrets/pro-token" 2> /dev/null || true)"
[ "$still_locked" != "$secret_plaintext" ] ||
  fail "clone-b's secrets/pro-token reads as plaintext despite the unlock attempt having failed"

# -- (6): a SECOND ubx-flake-init run against the SAME flake/gnupg-home is a
# real no-op -------------------------------------------------------------
before_collab_files="$(find "$flake/.git-crypt/keys" -type f -name '*.gpg' 2>/dev/null | sort)"
before_collab_count="$(printf '%s\n' "$before_collab_files" | grep -c . || true)"

out2=""
rc2=0
out2="$("$bin" --flake "$flake" --config "$UBX_REPO_ROOT/examples/server.nix" \
  --gnupg-home "$gnupg_home_a" --uid "$uid_a" 2>&1)" || rc2=$?
[ "$rc2" -eq 0 ] || fail "second (idempotent) ubx-flake-init run failed (rc=$rc2): $out2"

dirty="$(git -C "$flake" status --porcelain)"
[ -z "$dirty" ] || fail "working tree is not clean after a second ubx-flake-init run: $dirty"

after_collab_files="$(find "$flake/.git-crypt/keys" -type f -name '*.gpg' 2>/dev/null | sort)"
after_collab_count="$(printf '%s\n' "$after_collab_files" | grep -c . || true)"
[ "$after_collab_count" -eq "$before_collab_count" ] ||
  fail "the number of git-crypt collaborator files changed across a re-run ($before_collab_count -> $after_collab_count) -- ubx-flake-init duplicated a collaborator"
[ "$before_collab_files" = "$after_collab_files" ] ||
  fail "the set of git-crypt collaborator filenames changed across a re-run"

exit "$fails"
