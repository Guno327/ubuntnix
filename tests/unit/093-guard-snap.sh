#!/usr/bin/env bash
# tests/unit/093-guard-snap.sh — bin/ubx-guard-snap: the snap verb matrix,
# the start/stop/restart persistence-flag carve-out, unknown-verb
# fail-closed behavior, and faithful passthrough (SPEC.md §7; GitHub issue
# #31, milestone M2). Same stub-and-record technique as
# tests/unit/091-guard-apt.sh — see that file's header for the rationale.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

guard="$UBX_REPO_ROOT/bin/ubx-guard-snap"
[ -x "$guard" ] || {
  echo "FAIL: $guard does not exist or is not executable" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

stub="$work/real-snap"
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

# -- BLOCK verb matrix (bin/ubx-guard-snap's own BLOCK_VERBS) ----------------

for verb in install remove refresh revert enable disable set unset connect \
  disconnect ack alias unalias prefer switch try; do
  assert_block "'$verb'" "$verb" snapname
done

# -- PASS verb matrix (bin/ubx-guard-snap's own PASS_VERBS) ------------------

for verb in list info find version connections interfaces services \
  changes tasks warnings get known model whoami help; do
  assert_pass "'$verb'" "$verb" snapname
done

# -- start/stop/restart: CONDITIONAL on --enable/--disable -------------------

for verb in start stop restart; do
  assert_pass "plain '$verb' (no persistence flag)" "$verb" snapname.service
  assert_block "'$verb --enable'" "$verb" snapname.service --enable
  assert_block "'$verb --disable'" "$verb" snapname.service --disable
  # the persistence flag can appear anywhere after the verb, not just
  # immediately after it.
  assert_block "'$verb' with --enable trailing after other args" "$verb" --enable snapname.service
done

# The block message for the service-persistence carve-out is specific,
# not just the generic blocked-verb message -- confirm it names the verb
# and explains plain use IS allowed (distinguishing this from an
# unconditionally blocked verb).
run start snapname --enable
case "$err" in
  *"persists across reboots"*) ;;
  *) fail "'start --enable' refusal should explain persistence, got: $err" ;;
esac
case "$err" in
  *"plain 'start'"*"is allowed"*) ;;
  *) fail "'start --enable' refusal should note plain 'start' is allowed, got: $err" ;;
esac

# -- unknown verbs fail closed -- including ones plausible enough that a
# careless implementation might assume safe (see this guard's own header
# comment on `run` specifically). ------------------------------------------

for verb in run save restore forget debug bogus-verb; do
  assert_fail_closed "unknown verb '$verb'" "not a recognized read-only operation" "$verb"
done

# -- global-option parsing before the verb -----------------------------------

assert_pass "bare '--version'" --version
assert_pass "bare '-h'" -h
assert_pass "no args at all"
assert_pass "'-h list'" -h list
assert_block "'-h install'" -h install snapname
assert_fail_closed "unrecognized global option" "could not confidently classify" --this-flag-does-not-exist list

# -- passthrough forwards argv faithfully, including tricky tokens ----------

run list "" "with space" 'glob*chars' --all
[ "$ran" -eq 1 ] || fail "faithful-forwarding check: passthrough never happened"
if [ "$ran" -eq 1 ]; then
  expected="$work/expected.txt"
  printf '%s\n' list "" "with space" 'glob*chars' --all > "$expected"
  diff -u "$expected" "$record" > "$work/diff.txt" 2>&1 ||
    fail "argv was not forwarded verbatim:
$(cat "$work/diff.txt")"
fi

exit "$fails"
