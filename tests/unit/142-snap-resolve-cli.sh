#!/usr/bin/env bash
# tests/unit/142-snap-resolve-cli.sh — bin/ubx-snap-resolve CLI surface:
# --help, argument handling (GitHub issue #60, milestone M3). No network
# access happens here.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

resolve="$UBX_REPO_ROOT/bin/ubx-snap-resolve"
[ -x "$resolve" ] || {
  echo "FAIL: $resolve does not exist or is not executable" >&2
  exit 1
}

# --help / -h: usage to stdout, exit 0, documents every real flag.
for flag in --help -h; do
  out="$("$resolve" "$flag" 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] || fail "'$flag' should exit 0, got $rc"
  for word in --declaration --out --resolve-cmd --check-declaration --emit-lockfile; do
    case "$out" in
      *"$word"*) ;;
      *) fail "'$flag' output missing '$word'" ;;
    esac
  done
done

# Unknown option: usage to stderr, exit 2 (mirrors bin/ubx-resolve's own
# contract, tests/unit/052).
out="$("$resolve" --this-flag-does-not-exist 2>&1)"
rc=$?
[ "$rc" -eq 2 ] || fail "an unknown option should exit 2, got $rc"
case "$out" in
  *"usage"*) ;;
  *) fail "unknown-option output missing 'usage', got: $out" ;;
esac

# An option requiring a value with none given must fail clearly.
out="$("$resolve" --declaration 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "'--declaration' with no value should fail, got exit 0"

out="$("$resolve" --resolve-cmd 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "'--resolve-cmd' with no value should fail, got exit 0"

# --emit-lockfile pointed at a nonexistent file: clear, specific error.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
out="$("$resolve" --emit-lockfile "$work/does-not-exist.json" --out "$work/out.json" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "'--emit-lockfile' on a nonexistent file should fail"
case "$out" in
  *"does not exist"*) ;;
  *) fail "missing-resolved-file error should mention 'does not exist', got: $out" ;;
esac

# --check-declaration on a nonexistent declaration: clear, specific error
# (also exercised in tests/unit/140, kept here too as a CLI-surface smoke
# test alongside the other flag-handling checks).
out2="$("$resolve" --check-declaration --declaration "$work/nope.json" 2>&1)"
rc2=$?
[ "$rc2" -ne 0 ] || fail "'--check-declaration' on a nonexistent file should fail (output: $out2)"

exit "$fails"
