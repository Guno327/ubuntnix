#!/usr/bin/env bash
# tests/unit/090-guard-lib.sh — bin/ubx-guard-lib, the shared core `source`d
# by bin/ubx-guard-apt, -dpkg, and -snap (SPEC.md §7; GitHub issue #31,
# milestone M2). This exercises the two shared functions directly and in
# isolation; each wrapper's own verb/action matrix is exercised by its own
# tests/unit/09x-guard-*.sh instead of here.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

lib="$UBX_REPO_ROOT/bin/ubx-guard-lib"
[ -f "$lib" ] || {
  echo "FAIL: $lib does not exist" >&2
  exit 1
}
# Deliberately NOT executable, and never run directly -- it is only ever
# `source`d (see the file's own header). Confirm that stays true rather
# than someone accidentally chmod +x-ing it and changing its contract.
[ ! -x "$lib" ] || fail "$lib is executable -- it is a sourced-only library, not a standalone script"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# -- ubx_guard_refuse ---------------------------------------------------------

refuse_out="$(
  # shellcheck source=bin/ubx-guard-lib
  . "$lib"
  ubx_guard_refuse "testprog" "some specific reason." 2>&1
)"

case "$refuse_out" in
  *"testprog: some specific reason."*) ;;
  *) fail "ubx_guard_refuse did not print 'PROG: REASON' verbatim, got: $refuse_out" ;;
esac
case "$refuse_out" in
  *"SPEC.md §7"*) ;;
  *) fail "ubx_guard_refuse output does not cite SPEC.md §7, got: $refuse_out" ;;
esac
case "$refuse_out" in
  *"ubx rebuild switch"*) ;;
  *) fail "ubx_guard_refuse output does not point at 'ubx rebuild switch', got: $refuse_out" ;;
esac
case "$refuse_out" in
  *"no override"*) ;;
  *) fail "ubx_guard_refuse output does not state there is no override, got: $refuse_out" ;;
esac

# ubx_guard_refuse must write to stderr, not stdout.
refuse_stdout="$(
  # shellcheck source=bin/ubx-guard-lib
  . "$lib"
  ubx_guard_refuse "testprog" "reason" 2>/dev/null
)"
[ -z "$refuse_stdout" ] || fail "ubx_guard_refuse wrote to stdout (expected stderr only), got: $refuse_stdout"

# -- ubx_guard_exec_real: no UBX_GUARD_REAL_BIN set --------------------------

no_bin_out="$(
  exec 2>&1
  unset UBX_GUARD_REAL_BIN
  # shellcheck source=bin/ubx-guard-lib
  . "$lib"
  ubx_guard_exec_real "testprog" list
  echo "rc=$?"
)"
case "$no_bin_out" in
  *"rc=1"*) ;;
  *) fail "ubx_guard_exec_real with no UBX_GUARD_REAL_BIN should return 1, got: $no_bin_out" ;;
esac
case "$no_bin_out" in
  *"UBX_GUARD_REAL_BIN"*) ;;
  *) fail "ubx_guard_exec_real's no-real-bin error does not mention UBX_GUARD_REAL_BIN, got: $no_bin_out" ;;
esac

# -- ubx_guard_exec_real: UBX_GUARD_REAL_BIN set but not executable ----------

not_exec="$work/not-executable"
: > "$not_exec"
chmod -x "$not_exec"
bad_bin_out="$(
  exec 2>&1
  UBX_GUARD_REAL_BIN="$not_exec"
  export UBX_GUARD_REAL_BIN
  # shellcheck source=bin/ubx-guard-lib
  . "$lib"
  ubx_guard_exec_real "testprog" list
  echo "rc=$?"
)"
case "$bad_bin_out" in
  *"rc=1"*) ;;
  *) fail "ubx_guard_exec_real with a non-executable UBX_GUARD_REAL_BIN should return 1, got: $bad_bin_out" ;;
esac
case "$bad_bin_out" in
  *"not an executable"*) ;;
  *) fail "ubx_guard_exec_real's not-executable error is unclear, got: $bad_bin_out" ;;
esac

# UBX_GUARD_REAL_BIN pointing at a path that does not exist at all must fail
# the same way as "not executable", not crash on an unbound/missing-file
# surprise.
missing_bin_out="$(
  exec 2>&1
  UBX_GUARD_REAL_BIN="$work/does-not-exist"
  export UBX_GUARD_REAL_BIN
  # shellcheck source=bin/ubx-guard-lib
  . "$lib"
  ubx_guard_exec_real "testprog" list
  echo "rc=$?"
)"
case "$missing_bin_out" in
  *"rc=1"*) ;;
  *) fail "ubx_guard_exec_real with a nonexistent UBX_GUARD_REAL_BIN should return 1, got: $missing_bin_out" ;;
esac

# -- ubx_guard_exec_real: real hand-off, argv forwarded verbatim, exit code
# untouched -- this is the load-bearing property every wrapper's passthrough
# depends on. Run in a subshell since ubx_guard_exec_real calls `exec`,
# replacing the current process.

record="$work/record.txt"
stub="$work/real-testprog"
cat > "$stub" <<'STUBEOF'
#!/usr/bin/env bash
: > "$STUB_RECORD"
for a in "$@"; do
  printf '%s\n' "$a" >> "$STUB_RECORD"
done
exit "${STUB_EXIT:-0}"
STUBEOF
chmod +x "$stub"

(
  UBX_GUARD_REAL_BIN="$stub"
  STUB_RECORD="$record"
  STUB_EXIT="66"
  export UBX_GUARD_REAL_BIN STUB_RECORD STUB_EXIT
  # shellcheck source=bin/ubx-guard-lib
  . "$lib"
  ubx_guard_exec_real "testprog" first "" "with space" 'with*glob'
)
exec_rc=$?

[ "$exec_rc" -eq 66 ] || fail "ubx_guard_exec_real did not propagate the real binary's exit code (expected 66, got $exec_rc)"
[ -f "$record" ] || fail "ubx_guard_exec_real never invoked the real binary -- $record was not written"
if [ -f "$record" ]; then
  expected="$work/expected.txt"
  printf '%s\n' first "" "with space" 'with*glob' > "$expected"
  diff -u "$expected" "$record" > "$work/diff.txt" 2>&1 ||
    fail "ubx_guard_exec_real did not forward argv verbatim:
$(cat "$work/diff.txt")"
fi

exit "$fails"
