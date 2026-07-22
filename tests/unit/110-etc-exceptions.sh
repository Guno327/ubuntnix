#!/usr/bin/env bash
# tests/unit/110-etc-exceptions.sh — etc.exceptions.json schema validation
# and `ubx-etc exceptions` (SPEC.md §4.2 "an enumerated short list ...
# machine-id, SSH host keys, adjtime", §4.3; GitHub issue #26, milestone
# M2).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header), so nix/etc.nix's own `validateExceptions` can't be exercised
# here directly — CI's "flake" job forces it. This test instead validates
# the committed etc.exceptions.json's SHAPE directly with
# tests/lib/validate-etc-exceptions.py (the standalone reimplementation of
# that exact schema — see that file's header) and exercises
# `ubx-etc exceptions`, the one command in bin/ubx-etc's own CLI surface
# that reads this file directly.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

etc="$UBX_REPO_ROOT/bin/ubx-etc"
[ -x "$etc" ] || { echo "FAIL: $etc does not exist or is not executable" >&2; exit 1; }
validator="$UBX_REPO_ROOT/tests/lib/validate-etc-exceptions.py"
[ -f "$validator" ] || { echo "FAIL: $validator does not exist" >&2; exit 1; }

exceptions_file="$UBX_REPO_ROOT/etc.exceptions.json"
[ -f "$exceptions_file" ] || { echo "FAIL: $exceptions_file does not exist" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# -- the committed file must validate --------------------------------------
schema_out="$(python3 "$validator" "$exceptions_file" 2>&1)"
schema_rc=$?
[ "$schema_rc" -eq 0 ] || fail "committed etc.exceptions.json failed schema validation: $schema_out"

# -- `ubx-etc exceptions` (no --file): default to the repo root's copy,
# one path per line, sorted, matching the committed set exactly ----------
want_paths="adjtime
machine-id
ssh/ssh_host_ecdsa_key
ssh/ssh_host_ecdsa_key.pub
ssh/ssh_host_ed25519_key
ssh/ssh_host_ed25519_key.pub
ssh/ssh_host_rsa_key
ssh/ssh_host_rsa_key.pub"

got_paths="$(UBX_REPO_ROOT="$UBX_REPO_ROOT" "$etc" exceptions)"
[ "$got_paths" = "$want_paths" ] || fail "ubx-etc exceptions (default) mismatch:
want:
$want_paths
got:
$got_paths"

sorted_check="$(printf '%s\n' "$got_paths" | sort -c 2>&1)"
[ -z "$sorted_check" ] || fail "ubx-etc exceptions output is not sorted: $sorted_check"

# -- --file overrides the default, against a small hand-crafted fixture ---
fixture="$work/exceptions.json"
cat > "$fixture" <<'EOF'
{
  "version": 1,
  "exceptions": [
    { "path": "zzz-last", "owner": "root", "group": "root", "mode": "0644", "sensitive": false, "reason": "z" },
    { "path": "aaa-first", "owner": "root", "group": "root", "mode": "0644", "sensitive": false, "reason": "a" }
  ]
}
EOF
got="$("$etc" exceptions --file "$fixture")"
want="aaa-first
zzz-last"
[ "$got" = "$want" ] || fail "ubx-etc exceptions --file did not read/sort the override file, got: $got"

# -- a nonexistent --file is a hard error, not an empty/silent success ----
missing_rc=0
missing_out="$("$etc" exceptions --file "$work/does-not-exist.json" 2>&1)" || missing_rc=$?
[ "$missing_rc" -ne 0 ] || fail "ubx-etc exceptions --file <missing> should fail, got rc=0: $missing_out"

# -- rejection paths for the validator itself (fixture-driven, mirrors
# tests/unit/051's 'reject' helper for the archive lockfile validator) ----
reject() {
  local desc="$1" json="$2" want_msg="$3"
  local f="$work/bad.json"
  printf '%s' "$json" > "$f"
  local err rc
  err="$(python3 "$validator" "$f" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] || fail "$desc: validator should have rejected this, got exit 0"
  case "$err" in
    *"$want_msg"*) ;;
    *) fail "$desc: expected validator error to mention '$want_msg', got: $err" ;;
  esac
}

reject "missing field" \
  '{"version":1,"exceptions":[{"path":"foo","owner":"root","group":"root","mode":"0644","sensitive":false}]}' \
  "missing required field"
reject "malformed mode" \
  '{"version":1,"exceptions":[{"path":"foo","owner":"root","group":"root","mode":"644","sensitive":false,"reason":"r"}]}' \
  "must be 4 octal digits"
reject "sensitive + world-readable mode" \
  '{"version":1,"exceptions":[{"path":"foo","owner":"root","group":"root","mode":"0644","sensitive":true,"reason":"r"}]}' \
  "world-readable"
reject "duplicate path" \
  '{"version":1,"exceptions":[{"path":"foo","owner":"root","group":"root","mode":"0644","sensitive":false,"reason":"r"},{"path":"foo","owner":"root","group":"root","mode":"0644","sensitive":false,"reason":"r"}]}' \
  "duplicate exception path"
reject "wrong version" \
  '{"version":2,"exceptions":[]}' \
  "'version' must be the integer 1"

# -- a sensitive entry with a non-world-readable mode (e.g. 0600) must be
# ACCEPTED -- the rule is specifically about the world bit, not sensitive
# entries in general.
ok_fixture="$work/ok.json"
cat > "$ok_fixture" <<'EOF'
{"version":1,"exceptions":[{"path":"foo","owner":"root","group":"root","mode":"0600","sensitive":true,"reason":"r"}]}
EOF
ok_out="$(python3 "$validator" "$ok_fixture" 2>&1)"
ok_rc=$?
[ "$ok_rc" -eq 0 ] || fail "a sensitive entry with mode 0600 should be accepted, got: $ok_out"

exit "$fails"
