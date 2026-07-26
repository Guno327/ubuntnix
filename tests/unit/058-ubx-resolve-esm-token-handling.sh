#!/usr/bin/env bash
# tests/unit/058-ubx-resolve-esm-token-handling.sh — bin/ubx-resolve-esm's
# CI Pro token handling (SPEC.md §8.2; GitHub issue #81, milestone M4):
# the token is consumed from UBUNTNIX_CI_PRO_TOKEN (env-only, NEVER a
# tracked file), its absence produces a clear, specific error rather than
# a leak or a confusing crash, and its VALUE is never echoed anywhere --
# including when it IS set. No network access happens here.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

resolve_esm="$UBX_REPO_ROOT/bin/ubx-resolve-esm"
[ -x "$resolve_esm" ] || {
  echo "FAIL: $resolve_esm does not exist or is not executable" >&2
  exit 1
}

# -- --help documents --check-token and never mentions a default/example
# token value.
help_out="$("$resolve_esm" --help 2>&1)"
case "$help_out" in
  *"--check-token"*) ;;
  *) fail "--help output missing '--check-token'" ;;
esac
case "$help_out" in
  *"UBUNTNIX_CI_PRO_TOKEN"*) ;;
  *) fail "--help output does not name the required env var UBUNTNIX_CI_PRO_TOKEN" ;;
esac

# -- --check-token with the var unset: nonzero exit, clear message, no
# leak (there's nothing to leak -- the var isn't set -- but the message
# must still not claim a value).
( unset UBUNTNIX_CI_PRO_TOKEN
  out="$("$resolve_esm" --check-token 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] || { echo "FAIL: --check-token with no token set should exit nonzero, got 0" >&2; exit 1; }
  case "$out" in
    *"is not set"*) ;;
    *) echo "FAIL: --check-token (unset) output should say the var is not set, got: $out" >&2; exit 1 ;;
  esac
) || fails=$((fails + 1))

# -- --check-token with the var set: zero exit, and the FAKE token value
# used here must never appear in the command's output.
# shellcheck disable=SC2030  # intentional: scoped to this subshell only
( export UBUNTNIX_CI_PRO_TOKEN="super-secret-fake-token-do-not-leak-12345"
  out="$("$resolve_esm" --check-token 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: --check-token with the token set should exit 0, got $rc (output: $out)" >&2; exit 1; }
  case "$out" in
    *"is set"*) ;;
    *) echo "FAIL: --check-token (set) output should say the var is set, got: $out" >&2; exit 1 ;;
  esac
  case "$out" in
    *"super-secret-fake-token-do-not-leak-12345"*)
      echo "FAIL: --check-token echoed the token VALUE -- this is exactly the leak this issue forbids" >&2
      exit 1
      ;;
    *) ;;
  esac
) || fails=$((fails + 1))

# -- real resolution (--declaration) with no token set: clear, specific
# error mentioning the required env var, exit nonzero, BEFORE any network
# attempt (this test provides a nonexistent/garbage declaration path too,
# so a network attempt would also fail loudly on that -- but the token
# check must fire FIRST, which we confirm by checking the error message
# names the token, not a network/file problem).
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
decl="$work/esm.packages.json"
cat > "$decl" <<'EOF'
[{"name": "some-pkg", "version": "1.0-esm1", "path": "pool/esm-apps/main/s/some-pkg/some-pkg_1.0-esm1_amd64.deb"}]
EOF

( unset UBUNTNIX_CI_PRO_TOKEN
  out="$("$resolve_esm" --declaration "$decl" --archive-lockfile "$UBX_REPO_ROOT/archive.lock.json" --out "$work/should-not-exist.json" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] || { echo "FAIL: real resolution with no token set should fail, got exit 0" >&2; exit 1; }
  case "$out" in
    *"UBUNTNIX_CI_PRO_TOKEN"*) ;;
    *) echo "FAIL: missing-token error should mention UBUNTNIX_CI_PRO_TOKEN, got: $out" >&2; exit 1 ;;
  esac
  [ ! -e "$work/should-not-exist.json" ] || { echo "FAIL: --out was written despite the missing-token failure" >&2; exit 1; }
) || fails=$((fails + 1))

# -- real resolution requires --declaration; omitting it fails clearly
# regardless of token state (mirrors bin/ubx-resolve's own required-arg
# contract).
# shellcheck disable=SC2030,SC2031  # intentional: scoped to this subshell only
( export UBUNTNIX_CI_PRO_TOKEN="another-fake-token-should-not-appear"
  out="$("$resolve_esm" --archive-lockfile "$UBX_REPO_ROOT/archive.lock.json" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] || { echo "FAIL: real resolution with no --declaration should fail, got exit 0" >&2; exit 1; }
  case "$out" in
    *"another-fake-token-should-not-appear"*)
      echo "FAIL: the fake token leaked into the missing-declaration error output" >&2
      exit 1
      ;;
    *) ;;
  esac
) || fails=$((fails + 1))

exit "$fails"
