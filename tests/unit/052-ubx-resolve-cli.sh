#!/usr/bin/env bash
# tests/unit/052-ubx-resolve-cli.sh — bin/ubx-resolve CLI surface: --help,
# argument handling, and clear failure when the host has no apt (GitHub
# issue #8, milestone M1). No network access happens here.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

resolve="$UBX_REPO_ROOT/bin/ubx-resolve"
[ -x "$resolve" ] || {
  echo "FAIL: $resolve does not exist or is not executable" >&2
  exit 1
}

# --help / -h: usage to stdout, exit 0, documents every real flag.
for flag in --help -h; do
  out="$("$resolve" "$flag" 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] || fail "'$flag' should exit 0, got $rc"
  for word in --declaration --out --snapshot --keyring --work-dir \
    --check-declaration --emit-lockfile; do
    case "$out" in
      *"$word"*) ;;
      *) fail "'$flag' output missing '$word'" ;;
    esac
  done
done

# Unknown option: usage to stderr, exit 2 (mirrors bin/ubx's own contract
# for unrecognized input — tests/unit/020-ubx-cli.sh).
out="$("$resolve" --this-flag-does-not-exist 2>&1)"
rc=$?
[ "$rc" -eq 2 ] || fail "an unknown option should exit 2, got $rc"
case "$out" in
  *"usage"*) ;;
  *) fail "unknown-option output missing 'usage', got: $out" ;;
esac

# An option requiring a value with none given must fail clearly rather than
# consume the next unrelated flag as its value or crash on unbound access.
out="$("$resolve" --declaration 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "'--declaration' with no value should fail, got exit 0"

# --emit-lockfile without --snapshot: clear, specific error (SPEC.md's
# "resolution is inherently impure" — a caller must always pin the
# snapshot explicitly for anything reproducible, including this pure path).
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
echo '[]' > "$work/empty.json"
out="$("$resolve" --emit-lockfile "$work/empty.json" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "'--emit-lockfile' without '--snapshot' should fail"
case "$out" in
  *"--snapshot"*) ;;
  *) fail "missing-snapshot error should mention --snapshot, got: $out" ;;
esac

exit "$fails"
