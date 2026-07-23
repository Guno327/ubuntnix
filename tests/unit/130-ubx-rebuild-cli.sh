#!/usr/bin/env bash
# tests/unit/130-ubx-rebuild-cli.sh — bin/ubx: argument/verb parsing and
# error/exit-code paths for `rebuild`, `rollback`, `list-generations`, and
# `diff` (SPEC.md §4.3, §4.5; GitHub issue #29, milestone M2).
#
# Every path here needs no root, no network, no live systemd -- pure
# argument handling and error propagation.
set -u

ubx="$UBX_REPO_ROOT/bin/ubx"
[ -x "$ubx" ] || { echo "FAIL: $ubx does not exist or is not executable" >&2; exit 1; }

fails=0
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317  # invoked indirectly via 'trap cleanup EXIT'
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

root="$work/gens"

# =====================================================================
# rebuild: verb dispatch and --help
# =====================================================================

out="$("$ubx" rebuild --help 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild --help' should exit 0, got $rc"
for word in switch boot test rootfs-image dry-run apply; do
  contains "$out" "$word" || fail "'rebuild --help' output missing '$word'"
done

for bad in "" bogus; do
  # shellcheck disable=SC2086  # intentional: "" must become zero argv entries
  out="$("$ubx" rebuild $bad --root "$root" 2>&1)"
  rc=$?
  [ "$rc" -eq 2 ] || fail "'rebuild $bad' should exit 2, got $rc"
  contains "$out" "usage" || fail "'rebuild $bad' output missing 'usage' (got: $out)"
done

# a bad option to a valid verb: exit 2, not a silent no-op.
out="$("$ubx" rebuild switch --root "$root" --bogus-option 2>&1)"
rc=$?
[ "$rc" -eq 2 ] || fail "'rebuild switch --bogus-option' should exit 2, got $rc"

# switch/test require the generation-creation flags unless --dry-run.
for verb in switch boot test; do
  out="$("$ubx" rebuild "$verb" --root "$root" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] || fail "'rebuild $verb' with no generation flags (and no --dry-run) should fail, verb=$verb"
  contains "$out" "rootfs-image" || fail "'rebuild $verb' missing-flag error should mention --rootfs-image, got: $out"
done

# --dry-run makes the generation-creation flags optional and touches
# nothing under --root at all.
out="$("$ubx" rebuild switch --root "$root" --dry-run 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild switch --dry-run' with no generation flags should succeed, got rc=$rc: $out"
[ ! -e "$root" ] || fail "--dry-run must not create anything under --root, but $root exists"

# =====================================================================
# rollback: --help, and refusing when there is no current generation
# =====================================================================

out="$("$ubx" rollback --help 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rollback --help' should exit 0, got $rc"
contains "$out" "previous" || fail "'rollback --help' output missing 'previous'"

out="$("$ubx" rollback --root "$root" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "'rollback' with no current generation on disk should fail"
contains "$out" "current" || fail "rollback-with-no-current error should mention 'current', got: $out"

out="$("$ubx" rollback --root "$root" --bogus-option 2>&1)"
rc=$?
[ "$rc" -eq 2 ] || fail "'rollback --bogus-option' should exit 2, got $rc"

# =====================================================================
# list-generations: --help and a plain pass-through on an empty root
# =====================================================================

out="$("$ubx" list-generations --help 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'list-generations --help' should exit 0, got $rc"

out="$("$ubx" list-generations --root "$root" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'list-generations' on an empty root should still exit 0, got $rc: $out"
[ -z "$out" ] || fail "'list-generations' on an empty root should print nothing, got: $out"

out="$("$ubx" list-generations --root "$root" --bogus-option 2>&1)"
rc=$?
[ "$rc" -eq 2 ] || fail "'list-generations --bogus-option' should exit 2, got $rc"

# =====================================================================
# diff: --help, no-current refusal, and too-many-positional-args usage
# =====================================================================

out="$("$ubx" diff --help 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'diff --help' should exit 0, got $rc"

out="$("$ubx" diff --root "$root" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "'diff' with no current generation on disk should fail"

out="$("$ubx" diff 1 2 3 --root "$root" 2>&1)"
rc=$?
[ "$rc" -eq 2 ] || fail "'diff' with three positional args should exit 2 (usage), got rc=$rc: $out"

exit "$fails"
