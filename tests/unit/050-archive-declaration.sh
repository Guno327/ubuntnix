#!/usr/bin/env bash
# tests/unit/050-archive-declaration.sh — declared-package-set file
# (archive.packages.json), parsing/validation (SPEC.md §4.4, §6; GitHub
# issue #8, milestone M1: "declared packages -> lockfile").
#
# Exercises `bin/ubx-resolve --check-declaration`, which runs no network and
# no apt (pure parse + schema validation of the committed declaration
# file), against both the real committed archive.packages.json and a set of
# fixture files covering every rejection path. No network access happens
# here (tests/README.md's "unit tests must not require root, network, or
# KVM" rule) — the apt-solver end-to-end path is CI-only (see the "resolve"
# job in .github/workflows/ci.yml). tests/unit/053-archive-declaration-seed.sh
# separately cross-checks archive.packages.json against archive.lock.json
# (that it declares every already-pinned name); this file only checks
# archive.packages.json's own shape in isolation.
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

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# -- the real, committed declaration file must itself validate -------------
declfile="archive.packages.json"
[ -f "$declfile" ] || fail "$declfile does not exist"
if [ -f "$declfile" ]; then
  out="$("$resolve" --check-declaration --declaration "$declfile" 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] || fail "--check-declaration rejected the committed $declfile (rc=$rc): $out"
fi

# -- write DECL to a fixture file, run --check-declaration, and assert
# both the exit code and (for rejections) that stderr names the field.
check() {
  local desc="$1" decl="$2" want_rc="$3" want_stderr="${4:-}"
  local f="$work/decl.json"
  printf '%s' "$decl" > "$f"
  local out rc
  out="$("$resolve" --check-declaration --declaration "$f" 2>&1)"
  rc=$?
  [ "$rc" -eq "$want_rc" ] || {
    fail "$desc: expected exit $want_rc, got $rc (output: $out)"
    return
  }
  if [ -n "$want_stderr" ]; then
    case "$out" in
      *"$want_stderr"*) ;;
      *) fail "$desc: expected output to mention '$want_stderr', got: $out" ;;
    esac
  fi
}

check "valid, minimal" \
  '{"series":"noble","components":["main"],"packages":["hello"]}' \
  0

check "valid, all four components" \
  '{"series":"noble","components":["main","universe","restricted","multiverse"],"packages":["hello","htop"]}' \
  0

check "not valid JSON" \
  '{not json' \
  1 "not valid JSON"

check "top level not an object" \
  '["hello"]' \
  1 "not a JSON object"

check "wrong series" \
  '{"series":"jammy","components":["main"],"packages":["hello"]}' \
  1 "'series' must be 'noble'"

check "missing series" \
  '{"components":["main"],"packages":["hello"]}' \
  1 "'series' must be 'noble'"

check "empty components" \
  '{"series":"noble","components":[],"packages":["hello"]}' \
  1 "'components' must be a non-empty list"

check "components not a list" \
  '{"series":"noble","components":"main","packages":["hello"]}' \
  1 "'components' must be a non-empty list"

check "unsupported component" \
  '{"series":"noble","components":["main","backports"],"packages":["hello"]}' \
  1 "unsupported value"

check "duplicate component" \
  '{"series":"noble","components":["main","main"],"packages":["hello"]}' \
  1 "duplicate entries"

check "empty packages" \
  '{"series":"noble","components":["main"],"packages":[]}' \
  1 "'packages' must be a non-empty list"

check "packages not a list" \
  '{"series":"noble","components":["main"],"packages":"hello"}' \
  1 "'packages' must be a non-empty list"

check "invalid package name (uppercase)" \
  '{"series":"noble","components":["main"],"packages":["Hello"]}' \
  1 "not a valid Debian package name"

check "invalid package name (leading punctuation)" \
  '{"series":"noble","components":["main"],"packages":[".hello"]}' \
  1 "not a valid Debian package name"

check "invalid package name (not a string)" \
  '{"series":"noble","components":["main"],"packages":[42]}' \
  1 "not a valid Debian package name"

check "duplicate package name" \
  '{"series":"noble","components":["main"],"packages":["hello","hello"]}' \
  1 "duplicate package name"

# All violations in one run must be reported together (mirrors
# nix/archive.nix's validate: one throw enumerating every violation, not
# just the first).
multi_decl="$work/multi.json"
printf '%s' '{"series":"jammy","components":["backports"],"packages":["hello","hello"]}' > "$multi_decl"
multi_out="$("$resolve" --check-declaration --declaration "$multi_decl" 2>&1)"
for want in "'series' must be 'noble'" "unsupported value" "duplicate package name"; do
  case "$multi_out" in
    *"$want"*) ;;
    *) fail "multi-violation report missing '$want' (got: $multi_out)" ;;
  esac
done

# -- nonexistent declaration file --------------------------------------------
out="$("$resolve" --check-declaration --declaration "$work/does-not-exist.json" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "--check-declaration on a nonexistent file should fail"
case "$out" in
  *"does not exist"*) ;;
  *) fail "nonexistent-file error should mention 'does not exist', got: $out" ;;
esac

exit "$fails"
