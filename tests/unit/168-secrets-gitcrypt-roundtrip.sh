#!/usr/bin/env bash
# tests/unit/168-secrets-gitcrypt-roundtrip.sh — the git-crypt round-trip
# acceptance criterion (SPEC.md §8.1 "`/flake/secrets/` is a
# git-crypt-encrypted folder ... encrypted in the repo and on any remote,
# plaintext in the working tree for keyholders"; GitHub issue #79,
# milestone M4 groundwork). Proves, end to end, with a REAL throwaway GPG
# key and a REAL throwaway git repository (created fresh under a temp dir
# -- this test NEVER touches this project's own repository, keys, or
# remotes):
#
#   1. A secret file committed under a git-crypt-attributed secrets/ tree
#      is ENCRYPTED AT REST -- `git show`/the blob in `.git/objects` is
#      opaque ciphertext, not the plaintext bytes.
#   2. `index.nix`, left clear by secrets/.gitattributes' own carve-out
#      (see that file's own comment and tests/unit/166's static checks),
#      is committed as PLAINTEXT even in the same commit.
#   3. `git-crypt unlock` with the collaborator's own key restores the
#      secret file to its original plaintext bytes in the working tree.
#   4. `bin/ubx-secrets-key machine-init --repo` actually lands the
#      generated identity as a working git-crypt collaborator (a SECOND,
#      independently-generated key -- never having been added as a
#      collaborator -- is proven UNABLE to unlock the same repo, so this
#      is a real access-control proof, not just a smoke test of `unlock`
#      succeeding with the same key that encrypted it).
#
# Requires BOTH `git-crypt` and `gpg` to be installed. Neither is assumed
# present on every dev box (this project's own dev harness has gpg but not
# git-crypt as of this issue) -- skips cleanly (exit 77, tests/README.md's
# documented skip contract, honored by tests/run.sh for tests/unit/* too)
# rather than hard-failing the suite, IMMEDIATELY, before this script ever
# invokes a single `git` command -- see this project's own Engineer-role
# constraints for exactly why that ordering matters here.
set -u

cd "$UBX_REPO_ROOT" || exit 1

missing=""
command -v git-crypt > /dev/null 2>&1 || missing="${missing}git-crypt "
command -v gpg > /dev/null 2>&1 || missing="${missing}gpg "
command -v git > /dev/null 2>&1 || missing="${missing}git "
if [ -n "$missing" ]; then
  echo "SKIP: tests/unit/168 needs $missing(not installed) to exercise a real git-crypt round-trip" >&2
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

repo="$work/machine-flake"
mkdir -p "$repo"

git -C "$repo" init --quiet -b main
git -C "$repo" config user.email "test@example.invalid"
git -C "$repo" config user.name "ubx-secrets-key test"

mkdir -p "$repo/secrets"
cp "$UBX_REPO_ROOT/secrets/.gitattributes" "$repo/secrets/.gitattributes"

secret_plaintext="super-secret-pro-token-0123456789"
printf '%s\n' "$secret_plaintext" > "$repo/secrets/pro-token"
cp "$UBX_REPO_ROOT/secrets/index.nix" "$repo/secrets/index.nix"

git -C "$repo" add secrets
git -C "$repo" commit --quiet -m "add secrets/ with git-crypt attributes"

git -C "$repo" rev-parse --is-inside-work-tree > /dev/null 2>&1 ||
  fail "throwaway repo did not initialize correctly"

( cd "$repo" && git-crypt init ) > /dev/null 2>&1 ||
  fail "git-crypt init failed in throwaway repo"

# -- (1)+(2): re-commit now that git-crypt's clean filter is registered.
# git-crypt init does not retroactively re-filter already-committed blobs
# (git-crypt's own documented caveat), so the secret must be re-added/
# re-committed AFTER init for the clean filter to actually run over it.
git -C "$repo" rm --cached --quiet -r secrets > /dev/null 2>&1 || true
git -C "$repo" add secrets
git -C "$repo" commit --quiet -m "re-add secrets/ under the git-crypt filter" --allow-empty

blob="$(git -C "$repo" show "HEAD:secrets/pro-token" 2> /dev/null || true)"
if [ "$blob" = "$secret_plaintext" ]; then
  fail "secrets/pro-token is stored as PLAINTEXT in the git object -- git-crypt is not actually encrypting it at rest"
fi

index_blob="$(git -C "$repo" show "HEAD:secrets/index.nix" 2> /dev/null || true)"
printf '%s' "$index_blob" | grep -q 'proToken' ||
  fail "secrets/index.nix is NOT readable as plaintext straight from the git object -- it should be left clear (secrets/.gitattributes' own carve-out)"

# -- generate the machine identity and onboard it as the FIRST collaborator -
gnupg_home_a="$work/gpg-machine"
out_a=""
rc_a=0
out_a="$("$bin" machine-init --gnupg-home "$gnupg_home_a" --uid "machine-a <a@example.invalid>" --repo "$repo" 2>&1)" || rc_a=$?
[ "$rc_a" -eq 0 ] || fail "machine-init --repo failed (rc=$rc_a): $out_a"
fpr_a="$(printf '%s\n' "$out_a" | tail -1)"
case "$fpr_a" in
  [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]*) ;;
  *) fail "machine-init --repo's last output line does not look like a GPG fingerprint: $fpr_a" ;;
esac

git -C "$repo" log --oneline | grep -qi 'git-crypt' ||
  fail "no git-crypt-related commit found in $repo after machine-init --repo -- add-gpg-user should have committed the new collaborator"

# -- (3): a FRESH clone, locked, unlocked with the onboarded key ------------
clone="$work/clone-a"
git clone --quiet "$repo" "$clone"

locked_content="$(cat "$clone/secrets/pro-token" 2> /dev/null || true)"
[ "$locked_content" != "$secret_plaintext" ] ||
  fail "a fresh clone's working tree already shows PLAINTEXT before unlock -- git-crypt smudge/clean filter is not wired into the clone"

( cd "$clone" && GNUPGHOME="$gnupg_home_a" git-crypt unlock ) > /dev/null 2>&1 ||
  fail "git-crypt unlock failed in the fresh clone using the onboarded machine key"

unlocked_content="$(cat "$clone/secrets/pro-token" 2> /dev/null || true)"
[ "$unlocked_content" = "$secret_plaintext" ] ||
  fail "after unlock, secrets/pro-token does not match the original plaintext (got: $unlocked_content)"

index_content="$(cat "$clone/secrets/index.nix" 2> /dev/null || true)"
printf '%s' "$index_content" | grep -q 'proToken' ||
  fail "secrets/index.nix in the clone is not readable plaintext even BEFORE unlock's own effect on encrypted paths"

# -- (4): a SECOND, never-onboarded key cannot unlock the same repo ---------
gnupg_home_b="$work/gpg-machine-b"
out_b=""
rc_b=0
out_b="$("$bin" machine-init --gnupg-home "$gnupg_home_b" --uid "machine-b <b@example.invalid>" --no-collaborator 2>&1)" || rc_b=$?
[ "$rc_b" -eq 0 ] || fail "machine-init for the never-onboarded second identity failed (rc=$rc_b): $out_b"

clone_b="$work/clone-b"
git clone --quiet "$repo" "$clone_b"

unlock_b_rc=0
( cd "$clone_b" && GNUPGHOME="$gnupg_home_b" git-crypt unlock ) > /dev/null 2>&1 || unlock_b_rc=$?
[ "$unlock_b_rc" -ne 0 ] ||
  fail "git-crypt unlock SUCCEEDED with a key that was never added as a collaborator -- this is a real access-control break, not just an incomplete test"

still_locked="$(cat "$clone_b/secrets/pro-token" 2> /dev/null || true)"
[ "$still_locked" != "$secret_plaintext" ] ||
  fail "clone-b's secrets/pro-token reads as plaintext despite the unlock attempt having failed"

exit "$fails"
