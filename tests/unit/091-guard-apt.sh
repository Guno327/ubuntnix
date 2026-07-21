#!/usr/bin/env bash
# tests/unit/091-guard-apt.sh — bin/ubx-guard-apt: the apt/apt-get mutation
# guard's verb matrix, unknown-verb fail-closed behavior, and faithful
# passthrough (SPEC.md §7; GitHub issue #31, milestone M2).
#
# A stub "real apt" records the argv it was invoked with and exits a
# distinctive code, so a PASS case is proven by both "the stub ran" and
# "the guard's exit code is the stub's, unmodified", while a BLOCK/unknown
# case is proven by "the stub never ran at all" (not just a nonzero exit —
# a bug that ran the real binary AND also happened to exit nonzero would
# slip past a weaker check).
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

guard="$UBX_REPO_ROOT/bin/ubx-guard-apt"
[ -x "$guard" ] || {
  echo "FAIL: $guard does not exist or is not executable" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

stub="$work/real-apt"
cat > "$stub" <<'STUBEOF'
#!/usr/bin/env bash
: > "$STUB_RECORD"
for a in "$@"; do
  printf '%s\n' "$a" >> "$STUB_RECORD"
done
exit "${STUB_EXIT:-0}"
STUBEOF
chmod +x "$stub"

record="$work/record.txt"

# run ARG... — invokes the guard with a fresh $record and a distinctive
# stub exit code (66); sets $rc/$out/$err/$ran (whether the stub wrote
# $record, i.e. whether passthrough actually happened).
run() {
  rm -f "$record"
  local errfile
  errfile="$(mktemp)"
  out="$(UBX_GUARD_REAL_BIN="$stub" STUB_RECORD="$record" STUB_EXIT="66" "$guard" "$@" 2>"$errfile")"
  rc=$?
  err="$(cat "$errfile")"
  rm -f "$errfile"
  if [ -f "$record" ]; then ran=1; else ran=0; fi
}

assert_pass() {
  local desc="$1"
  shift
  run "$@"
  [ "$ran" -eq 1 ] || fail "$desc: expected passthrough to the real binary, but it never ran (rc=$rc, err=$err)"
  [ "$rc" -eq 66 ] || fail "$desc: expected the real binary's exit code (66) to propagate, got $rc"
}

assert_block() {
  local desc="$1"
  shift
  run "$@"
  [ "$ran" -eq 0 ] || fail "$desc: the real binary ran despite this invocation being expected to block"
  [ "$rc" -eq 1 ] || fail "$desc: expected exit 1, got $rc"
  case "$err" in
    *"blocked on this system"*) ;;
    *) fail "$desc: refusal message missing 'blocked on this system', got: $err" ;;
  esac
  case "$err" in
    *"SPEC.md §7"*) ;;
    *) fail "$desc: refusal message missing SPEC.md §7 citation, got: $err" ;;
  esac
  [ -z "$out" ] || fail "$desc: a refusal should print nothing to stdout (message is stderr-only), got: $out"
}

assert_fail_closed() {
  local desc="$1" want="$2"
  shift 2
  run "$@"
  [ "$ran" -eq 0 ] || fail "$desc: the real binary ran despite this invocation being expected to fail closed"
  [ "$rc" -eq 1 ] || fail "$desc: expected exit 1, got $rc"
  case "$err" in
    *"$want"*) ;;
    *) fail "$desc: refusal message missing '$want', got: $err" ;;
  esac
  [ -z "$out" ] || fail "$desc: a refusal should print nothing to stdout (message is stderr-only), got: $out"
}

# -- BLOCK verb matrix (bin/ubx-guard-apt's own BLOCK_VERBS) -----------------

for verb in install remove purge autoremove upgrade full-upgrade \
  dist-upgrade dselect-upgrade reinstall build-dep satisfy edit-sources \
  source; do
  assert_block "'$verb'" "$verb" pkgname
done

# `source` is blocked outright even with an innocuous-looking bare form.
assert_block "'source' with no package arg" source

# -- PASS verb matrix (bin/ubx-guard-apt's own PASS_VERBS) -------------------

for verb in list search show showpkg policy madison depends rdepends \
  download changelog moo help check indextargets update clean autoclean; do
  assert_pass "'$verb'" "$verb" pkgname
done

# -- unknown verbs fail closed, same refusal shape as a blocked verb ---------

for verb in gencaches pkgnames unmet bogus-verb typo-verb; do
  assert_fail_closed "unknown verb '$verb'" "not a recognized read-only operation" "$verb"
done

# -- global-option parsing before the verb -----------------------------------

# A bare invocation with only known no-verb options must pass through
# (letting the real binary print its own usage/version) rather than being
# treated as an unknown verb.
assert_pass "bare '--version'" --version
assert_pass "bare '-q'" -q
assert_pass "no args at all"

# Options that consume a following value must be skipped correctly so the
# verb after them is still found.
assert_pass "'-o Dir::Cache=/tmp update'" -o "Dir::Cache=/tmp" update
assert_pass "'--option=... list'" --option=Dir::Cache=/tmp list
assert_block "'-t noble install'" -t noble install pkgname

# `--` ends option parsing; the next token is the verb.
assert_pass "'-- list'" -- list
assert_block "'-- install'" -- install pkgname

# An unrecognized option before any verb must fail closed, not be guessed
# past.
assert_fail_closed "unrecognized global option" "could not confidently classify" --this-flag-does-not-exist list

# A value-option with no value provided must fail closed rather than
# consuming an unrelated following token or crashing on unbound access.
assert_fail_closed "'-o' with no value" "could not confidently classify" -o

# -- passthrough forwards argv faithfully, including tricky tokens ----------

run list "" "with space" 'glob*chars' --installed
[ "$ran" -eq 1 ] || fail "faithful-forwarding check: passthrough never happened"
if [ "$ran" -eq 1 ]; then
  expected="$work/expected.txt"
  printf '%s\n' list "" "with space" 'glob*chars' --installed > "$expected"
  diff -u "$expected" "$record" > "$work/diff.txt" 2>&1 ||
    fail "argv was not forwarded verbatim:
$(cat "$work/diff.txt")"
fi

exit "$fails"
