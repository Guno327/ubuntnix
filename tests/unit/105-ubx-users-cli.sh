#!/usr/bin/env bash
# tests/unit/105-ubx-users-cli.sh — bin/ubx-users' CLI surface: --help,
# subcommand/argument handling, and clear failure on a malformed or
# incomplete manifest (SPEC.md §4.3 "Users"; GitHub issue #28, milestone
# M2). No root, no network -- pure argument/fixture handling.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

ubx_users="$UBX_REPO_ROOT/bin/ubx-users"
[ -x "$ubx_users" ] || {
  echo "FAIL: $ubx_users does not exist or is not executable" >&2
  exit 1
}

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# --help / -h: usage to stdout, exit 0, documents both subcommands.
for flag in --help -h; do
  out="$("$ubx_users" "$flag" 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] || fail "'$flag' should exit 0, got $rc"
  for word in plan execute; do
    case "$out" in
      *"$word"*) ;;
      *) fail "'$flag' output missing '$word'" ;;
    esac
  done
done

# No subcommand at all: nonzero exit, usage to stderr.
out="$("$ubx_users" 2>&1)"
rc=$?
[ "$rc" -eq 2 ] || fail "no subcommand should exit 2, got $rc"
case "$out" in
  *"usage"*) ;;
  *) fail "no-subcommand output missing 'usage', got: $out" ;;
esac

# Unknown subcommand: nonzero exit, usage to stderr.
out="$("$ubx_users" bogus-subcommand 2>&1)"
rc=$?
[ "$rc" -eq 2 ] || fail "unknown subcommand should exit 2, got $rc"

# 'plan' with no arguments: nonzero exit, mentions the missing required
# flags.
out="$("$ubx_users" plan 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "'plan' with no arguments should fail"
for flag in --manifest --passwd --group --shadow; do
  case "$out" in
    *"$flag"*) ;;
    *) fail "'plan' with no arguments: output missing '$flag', got: $out" ;;
  esac
done

# 'execute' with no arguments: nonzero exit, mentions --plan.
out="$("$ubx_users" execute 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "'execute' with no arguments should fail"
case "$out" in
  *"--plan"*) ;;
  *) fail "'execute' with no arguments: output missing '--plan', got: $out" ;;
esac

# A manifest that isn't valid JSON at all: exit 1, clear message, no
# traceback (i.e. no 'Traceback (most recent call last)' leaking to the
# user).
passwd="$work/passwd"
printf 'root:x:0:0:root:/root:/bin/bash\n' > "$passwd"
group="$work/group"
printf 'root:x:0:\n' > "$group"
shadow="$work/shadow"
printf 'root:*:19000:0:99999:7:::\n' > "$shadow"

bad_json="$work/bad.json"
printf 'not valid json at all' > "$bad_json"
out="$("$ubx_users" plan --manifest "$bad_json" --passwd "$passwd" --group "$group" --shadow "$shadow" 2>&1)"
rc=$?
[ "$rc" -eq 1 ] || fail "invalid-JSON manifest should exit 1, got $rc"
case "$out" in
  *"Traceback"*) fail "invalid-JSON manifest leaked a Python traceback: $out" ;;
esac

# A manifest missing a required field: exit 1, error names the offending
# field.
incomplete="$work/incomplete.json"
cat > "$incomplete" << 'EOF'
{ "version": 1, "users": [ { "name": "gunnar" } ], "groups": [] }
EOF
out="$("$ubx_users" plan --manifest "$incomplete" --passwd "$passwd" --group "$group" --shadow "$shadow" 2>&1)"
rc=$?
[ "$rc" -eq 1 ] || fail "incomplete manifest should exit 1, got $rc"
case "$out" in
  *"shell"*) ;;
  *) fail "incomplete-manifest error should mention the missing 'shell' field, got: $out" ;;
esac

# A manifest declaring an invalid username: exit 1, error names the bad
# username.
bad_name="$work/bad_name.json"
cat > "$bad_name" << 'EOF'
{ "version": 1, "users": [ { "name": "Not_Valid!", "uid": null, "system": false,
  "shell": "/usr/bin/bash", "home": null, "createHome": true, "groups": [],
  "authorizedKeys": [] } ], "groups": [] }
EOF
out="$("$ubx_users" plan --manifest "$bad_name" --passwd "$passwd" --group "$group" --shadow "$shadow" 2>&1)"
rc=$?
[ "$rc" -eq 1 ] || fail "invalid username should exit 1, got $rc"
case "$out" in
  *"Not_Valid!"*) ;;
  *) fail "invalid-username error should name the offending username, got: $out" ;;
esac

# A nonexistent fixture file: exit 1, clear message, no traceback.
out="$("$ubx_users" plan --manifest "$work/does-not-exist.json" --passwd "$passwd" --group "$group" --shadow "$shadow" 2>&1)"
rc=$?
[ "$rc" -eq 1 ] || fail "nonexistent manifest file should exit 1, got $rc"
case "$out" in
  *"Traceback"*) fail "nonexistent manifest file leaked a Python traceback: $out" ;;
esac

exit "$fails"
