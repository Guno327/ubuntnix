#!/usr/bin/env bash
# tests/unit/092-guard-dpkg.sh — bin/ubx-guard-dpkg: the dpkg action matrix,
# the dpkg-divert/dpkg-statoverride satellite modes it also fronts, and
# unknown-action/faithful-passthrough behavior (SPEC.md §7; GitHub issue
# #31, milestone M2). Same stub-and-record technique as
# tests/unit/091-guard-apt.sh — see that file's header for the rationale.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

guard="$UBX_REPO_ROOT/bin/ubx-guard-dpkg"
[ -x "$guard" ] || {
  echo "FAIL: $guard does not exist or is not executable" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

stub="$work/real-dpkg"
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

# run [MODE] ARG... — MODE, if given, sets UBX_GUARD_DPKG_MODE (dpkg,
# divert, or statoverride); default is dpkg (basename-based default,
# untouched). Sets $rc/$out/$err/$ran.
run_mode() {
  local mode="$1"
  shift
  rm -f "$record"
  local errfile
  errfile="$(mktemp)"
  out="$(UBX_GUARD_DPKG_MODE="$mode" UBX_GUARD_REAL_BIN="$stub" STUB_RECORD="$record" STUB_EXIT="66" "$guard" "$@" 2>"$errfile")"
  rc=$?
  err="$(cat "$errfile")"
  rm -f "$errfile"
  if [ -f "$record" ]; then ran=1; else ran=0; fi
}

run() { run_mode dpkg "$@"; }

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
}

# -- dpkg proper: BLOCK action matrix -----------------------------------------

for action in -i --install --unpack --configure -r --remove -P --purge \
  --set-selections --clear-selections --update-avail --merge-avail \
  --clear-avail -A --record-avail --add-architecture \
  --remove-architecture --triggers-only; do
  assert_block "dpkg '$action'" "$action" somearg
done

# -- dpkg proper: PASS action matrix ------------------------------------------

for action in -l --list -L --listfiles -s --status -p --print-avail \
  -S --search --get-selections --print-architecture \
  --print-foreign-architectures --compare-versions -C --audit --version \
  --help -h --license --licence -c --contents -e --control -x --extract \
  -X --vextract -I --info -f --field --fsys-tarfile -W --show -b --build; do
  assert_pass "dpkg '$action'" "$action" somearg
done

# -- dpkg proper: no action at all always fails closed (unlike apt/snap,
# dpkg has no harmless bare invocation) --------------------------------------

assert_fail_closed "dpkg with no action" "dpkg always requires a recognized action"
assert_fail_closed "dpkg with only modifier options" "dpkg always requires a recognized action" --root /mnt

# -- dpkg proper: unrecognized action fails closed ---------------------------

assert_fail_closed "dpkg unknown action" "could not confidently classify" --this-is-not-a-real-action

# A non-option positional argument before any action is unparseable and
# fails closed (dpkg's action always comes first in well-formed usage).
assert_fail_closed "dpkg positional before any action" "could not confidently classify" somepackage

# -- dpkg proper: modifier-option skipping ------------------------------------

# --root/--admindir etc. take a value and must be skipped so the action
# after them is still found.
assert_pass "dpkg '--root /mnt -l'" --root /mnt -l
assert_pass "dpkg '--admindir=/x -l'" --admindir=/x -l

# --force-*/--no-force-*/--refuse-* are a glob family; skip without
# consuming a value or changing the classification of the action that
# follows, whichever way that action goes.
assert_pass "dpkg '--force-all -l' (force flag skipped, PASS action still found)" --force-all -l somearg
assert_block "dpkg '--force-all --purge' (force flag skipped, BLOCK action still found)" --force-all --purge somearg

# -D takes the debug level ATTACHED only (-D077), never as a separate
# argv slot; the space-separated form is intentionally unsupported and
# falls through to fail-closed.
assert_pass "dpkg '-D077 -l'" -D077 -l
assert_fail_closed "dpkg '-D 077 -l' (space-separated debug level, unsupported)" "could not confidently classify" -D 077 -l

# -- dpkg-divert mode ----------------------------------------------------------

run_mode divert --list somepattern
[ "$ran" -eq 1 ] || fail "dpkg-divert '--list': expected passthrough, never ran (rc=$rc, err=$err)"
[ "$rc" -eq 66 ] || fail "dpkg-divert '--list': expected exit 66, got $rc"

run_mode divert --truename /usr/bin/apt
[ "$ran" -eq 1 ] || fail "dpkg-divert '--truename': expected passthrough, never ran"

for action in --add --remove; do
  run_mode divert "$action" --local --divert /usr/bin/apt.ubx-real --rename /usr/bin/apt
  [ "$ran" -eq 0 ] || fail "dpkg-divert '$action': the real binary ran despite expecting a block"
  [ "$rc" -eq 1 ] || fail "dpkg-divert '$action': expected exit 1, got $rc"
  case "$err" in
    *"blocked on this system"*) ;;
    *) fail "dpkg-divert '$action': refusal message missing 'blocked on this system', got: $err" ;;
  esac
done

# An entirely action-flag-free invocation is treated as an IMPLICIT --add
# per dpkg-divert(1)'s own documented default -- and must still block, even
# though a trailing filename argument is present (regression coverage: an
# earlier version of this parser treated any bare positional argument as
# unparseable and fell through to the generic fail-closed path instead of
# reaching this implicit-default handling -- both refuse, but only this
# path proves the SPECIFIC documented mechanism actually fires).
run_mode divert --local --rename --divert /usr/bin/apt.ubx-real /usr/bin/apt
[ "$ran" -eq 0 ] || fail "dpkg-divert implicit --add: the real binary ran despite expecting a block"
[ "$rc" -eq 1 ] || fail "dpkg-divert implicit --add: expected exit 1, got $rc"
case "$err" in
  *"'--add' is blocked"*) ;;
  *) fail "dpkg-divert implicit --add: refusal message should specifically cite '--add' as blocked, got: $err" ;;
esac

# -- dpkg-statoverride mode ----------------------------------------------------

run_mode statoverride --list
[ "$ran" -eq 1 ] || fail "dpkg-statoverride '--list': expected passthrough, never ran"

for action in --add --remove; do
  run_mode statoverride "$action" www-data www-data 0664 /var/www
  [ "$ran" -eq 0 ] || fail "dpkg-statoverride '$action': the real binary ran despite expecting a block"
  [ "$rc" -eq 1 ] || fail "dpkg-statoverride '$action': expected exit 1, got $rc"
done

# dpkg-statoverride has NO implicit default action (unlike dpkg-divert) --
# a bare invocation, even with a trailing positional argument, is
# unparseable and fails closed rather than being guessed as --add.
run_mode statoverride /var/www
[ "$ran" -eq 0 ] || fail "dpkg-statoverride bare positional: the real binary ran despite expecting fail-closed"
[ "$rc" -eq 1 ] || fail "dpkg-statoverride bare positional: expected exit 1, got $rc"
case "$err" in
  *"could not confidently classify"*) ;;
  *) fail "dpkg-statoverride bare positional: expected the generic fail-closed message (no implicit default for statoverride), got: $err" ;;
esac

# -- mode selection via basename (not just UBX_GUARD_DPKG_MODE) --------------
# The production install mechanism diverts dpkg-divert/dpkg-statoverride to
# this same script under their own name and relies on basename dispatch;
# UBX_GUARD_DPKG_MODE exists only so tests don't need three copies on disk
# (see this script's own header comment). Prove the basename path too, via
# a self-contained copy (script + the lib it sources) under each name in
# $work -- a symlink pointing back at the real bin/ dir would resolve
# BASH_SOURCE's dirname to bin/, which is fine for the lib lookup but
# entangles this test with bin/'s contents; copying keeps the fixture
# fully self-contained.
cp "$guard" "$work/ubx-guard-dpkg"
cp "$UBX_REPO_ROOT/bin/ubx-guard-lib" "$work/ubx-guard-lib"
chmod +x "$work/ubx-guard-dpkg"
for name in dpkg-divert dpkg-statoverride; do
  cp "$work/ubx-guard-dpkg" "$work/$name"
  chmod +x "$work/$name"
  rm -f "$record"
  errfile="$(mktemp)"
  out="$(UBX_GUARD_REAL_BIN="$stub" STUB_RECORD="$record" STUB_EXIT="66" "$work/$name" --list 2>"$errfile")"
  rc=$?
  err="$(cat "$errfile")"
  rm -f "$errfile"
  [ -f "$record" ] || fail "basename dispatch for '$name --list': expected passthrough, never ran (err=$err)"
  [ "$rc" -eq 66 ] || fail "basename dispatch for '$name --list': expected exit 66, got $rc"
  [ -z "$out" ] || fail "basename dispatch for '$name --list': unexpected stdout: $out"
done

# -- unknown/unrecognized dpkg-divert and dpkg-statoverride options fail
# closed too -------------------------------------------------------------
assert_fail_closed_mode() {
  local mode="$1" desc="$2" want="$3"
  shift 3
  run_mode "$mode" "$@"
  [ "$ran" -eq 0 ] || fail "$desc: the real binary ran despite expecting fail-closed"
  [ "$rc" -eq 1 ] || fail "$desc: expected exit 1, got $rc"
  case "$err" in
    *"$want"*) ;;
    *) fail "$desc: refusal message missing '$want', got: $err" ;;
  esac
}
assert_fail_closed_mode divert "dpkg-divert unknown option" "could not confidently classify" --this-flag-does-not-exist
assert_fail_closed_mode statoverride "dpkg-statoverride unknown option" "could not confidently classify" --this-flag-does-not-exist

# -- passthrough forwards argv faithfully -------------------------------------

run -l "" "with space" 'glob*chars'
[ "$ran" -eq 1 ] || fail "faithful-forwarding check: passthrough never happened"
if [ "$ran" -eq 1 ]; then
  expected="$work/expected.txt"
  printf '%s\n' -l "" "with space" 'glob*chars' > "$expected"
  diff -u "$expected" "$record" > "$work/diff.txt" 2>&1 ||
    fail "argv was not forwarded verbatim:
$(cat "$work/diff.txt")"
fi

exit "$fails"
