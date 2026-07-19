#!/usr/bin/env bash
# tests/unit/020-ubx-cli.sh — ubx CLI skeleton (issue #5).
#
# Contract under test (SPEC.md §4.5):
#   - `ubx --help` / `ubx help`: usage to stdout, exit 0, mentions every
#     subcommand.
#   - Every real subcommand (rebuild switch|boot|test, rollback,
#     list-generations, diff, update) is a pre-M1 stub: nonzero exit,
#     "not implemented" on stderr.
#   - Unknown subcommand, or `rebuild` with a missing/unknown verb: usage
#     to stderr, exit 2.
set -u

ubx="$UBX_REPO_ROOT/bin/ubx"
errfile="$(mktemp)"
trap 'rm -f "$errfile"' EXIT

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

# run CMD... — sets $rc (exit code), $out (stdout), $err (stderr).
run() {
  out="$("$ubx" "$@" 2>"$errfile")"
  rc=$?
  err="$(cat "$errfile")"
}

run --help
[ "$rc" -eq 0 ] || fail "'--help' should exit 0, got $rc"
for word in rebuild rollback list-generations diff update; do
  contains "$out" "$word" || fail "'--help' output missing '$word'"
done

run help
[ "$rc" -eq 0 ] || fail "'help' should exit 0, got $rc"
contains "$out" "rebuild" || fail "'help' output missing 'rebuild'"

for args in rollback list-generations diff update "rebuild switch" "rebuild boot" "rebuild test"; do
  # Intentional word-splitting: "rebuild switch" etc. must become two argv
  # entries.
  # shellcheck disable=SC2086
  run $args
  [ "$rc" -ne 0 ] || fail "'ubx $args' should exit nonzero"
  contains "$err" "not implemented" || fail "'ubx $args' stderr missing 'not implemented' (got: $err)"
done

run bogus
[ "$rc" -eq 2 ] || fail "unknown subcommand should exit 2, got $rc"
contains "$err" "usage" || fail "unknown subcommand stderr missing 'usage' (got: $err)"

run rebuild
[ "$rc" -eq 2 ] || fail "'rebuild' with no verb should exit 2, got $rc"
contains "$err" "usage" || fail "'rebuild' no-verb stderr missing 'usage' (got: $err)"

run rebuild bogus
[ "$rc" -eq 2 ] || fail "'rebuild bogus' should exit 2, got $rc"
contains "$err" "usage" || fail "'rebuild bogus' stderr missing 'usage' (got: $err)"

exit "$fails"
