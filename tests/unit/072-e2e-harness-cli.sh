#!/usr/bin/env bash
# tests/unit/072-e2e-harness-cli.sh — tests/e2e/010-qemu-boot-e2e.sh's CLI
# surface: --help, argument validation, and the documented skip-when-
# unavailable contract (GitHub issue #10, milestone M1's e2e harness line
# item; tests/README.md's "E2E tests may require KVM and declare it by
# exiting 77 (skip) when unavailable" rule).
#
# This is a UNIT test (tests/unit/, always run), not an e2e test: nothing
# here boots QEMU or needs `nix`/`qemu-system-x86_64` at all — it only
# exercises the harness's own argument handling and its graceful skip path,
# which is exactly the path this dev harness (no qemu installed) takes
# naturally. tests/e2e/010-qemu-boot-e2e.sh itself is the real boot test,
# opt-in via UBX_E2E=1 (tests/README.md), and is expected to skip (exit 77)
# right here on this host for the identical reason this test exercises.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

harness="$UBX_REPO_ROOT/tests/e2e/010-qemu-boot-e2e.sh"
[ -x "$harness" ] || {
  echo "FAIL: $harness does not exist or is not executable" >&2
  exit 1
}

# -- --help / -h --------------------------------------------------------
for flag in --help -h; do
  out="$("$harness" "$flag" 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] || fail "'$flag' should exit 0, got $rc"
  for word in --image --timeout --no-kvm --keep-log; do
    case "$out" in
      *"$word"*) ;;
      *) fail "'$flag' output missing '$word'" ;;
    esac
  done
done

# -- unknown option: usage to stderr, exit 2 -------------------------------
out="$("$harness" --this-flag-does-not-exist 2>&1)"
rc=$?
[ "$rc" -eq 2 ] || fail "an unknown option should exit 2, got $rc"
case "$out" in
  *"usage"*) ;;
  *) fail "unknown-option output missing 'usage', got: $out" ;;
esac

# -- an option requiring a value with none given must fail clearly --------
for opt in --image --timeout --keep-log; do
  out="$("$harness" "$opt" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] || fail "'$opt' with no value should fail, got exit 0"
  case "$out" in
    *"requires an argument"*) ;;
    *) fail "'$opt' with no value should say 'requires an argument', got: $out" ;;
  esac
done

# -- a non-integer --timeout is rejected -----------------------------------
out="$("$harness" --timeout not-a-number 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "--timeout not-a-number should fail, got exit 0"
case "$out" in
  *"--timeout"*) ;;
  *) fail "bad --timeout error should mention '--timeout', got: $out" ;;
esac

# -- the documented skip contract ------------------------------------------
#
# This dev harness has no qemu-system-x86_64 (verified in the SAME way the
# harness itself checks, so this assertion is meaningful regardless of
# what host ends up running this suite): the harness must SKIP (exit 77),
# not fail or hang, with a message identifying qemu as the missing piece.
if ! command -v qemu-system-x86_64 > /dev/null 2>&1; then
  out="$("$harness" 2>&1)"
  rc=$?
  [ "$rc" -eq 77 ] || fail "with no qemu-system-x86_64 on PATH, the harness should exit 77 (skip), got $rc"
  case "$out" in
    *"SKIP"*"qemu-system-x86_64"*) ;;
    *) fail "the skip message should mention SKIP and qemu-system-x86_64, got: $out" ;;
  esac
else
  echo "$0: qemu-system-x86_64 IS present on this host -- skipping the no-qemu skip-path assertion (it does not apply here)" >&2
fi

# -- an explicitly-given, nonexistent --image is a real ERROR, not a skip -
#
# Distinguishes "this environment cannot run e2e at all" (skip, above) from
# "you gave me a bad argument" (a real failure) -- only meaningful to check
# when qemu IS present (otherwise the qemu check itself short-circuits
# first, which is exercised above).
if command -v qemu-system-x86_64 > /dev/null 2>&1; then
  out="$("$harness" --image /no/such/disk.img --timeout 1 2>&1)"
  rc=$?
  [ "$rc" -eq 1 ] || fail "an explicit --image that does not exist should fail with exit 1 (not skip), got $rc"
fi

exit "$fails"
