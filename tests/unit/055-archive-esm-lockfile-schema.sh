#!/usr/bin/env bash
# tests/unit/055-archive-esm-lockfile-schema.sh — esm-tier lockfile schema
# validation (SPEC.md §4.4 second bullet, §8.2; GitHub issue #81,
# milestone M4).
#
# tests/lib/validate-archive-lockfile.py's esm handling changed shape at
# M4: the tier is no longer required to be empty (tests/unit/040/051 still
# cover the "still valid when empty" case against the real committed
# archive.lock.json / bin/ubx-resolve's own emission). This test exercises
# the NEW branch directly, against small fixtures, so every field the
# validator checks for a POPULATED esm tier is pinned: name/version/sha256/
# path/source required, sha256 format, and the "source" must read exactly
# "esm" (the marker that lets a flattened-package-list consumer, e.g.
# bin/ubx-archive-public-manifest, tell an esm entry apart from a
# public-tier one). No network.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

validator="$UBX_REPO_ROOT/tests/lib/validate-archive-lockfile.py"
[ -f "$validator" ] || {
  echo "FAIL: $validator does not exist" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

base_public='"version": 1, "public": {"snapshot": "20260715T000000Z", "series": "noble", "packages": [
  {"name": "ed", "version": "1.20.1-1", "arch": "amd64", "component": "main", "path": "pool/main/e/ed/ed_1.20.1-1_amd64.deb", "sha256": "c26e577a24cc784d678b0b2b960db8a154fb7138fc1aa7ad1ffe504698432a43", "size": 56062},
  {"name": "hello", "version": "2.10-3build1", "arch": "amd64", "component": "main", "path": "pool/main/h/hello/hello_2.10-3build1_amd64.deb", "sha256": "e68cf4365b7aa9c4e2af4af6eee1710d6f967059b7b4af62786e8870d7366333", "size": 26006},
  {"name": "htop", "version": "3.3.0-4build1", "arch": "amd64", "component": "universe", "path": "pool/universe/h/htop/htop_3.3.0-4build1_amd64.deb", "sha256": "ee0e9cffc789788164214bac9b6e285a5127c07be1815129875c6c538ba849c6", "size": 170528}
]}'

make_lockfile() {
  local esm_json="$1" out="$2"
  printf '{%s, "esm": %s}' "$base_public" "$esm_json" > "$out"
}

# -- valid: a well-formed esm entry with version+sha256+source ------------
valid="$work/valid.json"
make_lockfile '{"packages": [{"name": "some-universe-pkg", "version": "1.2.3-1ubuntu1~esm1", "sha256": "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd", "path": "pool/esm-infra/main/s/some-universe-pkg/some-universe-pkg_1.2.3-1ubuntu1~esm1_amd64.deb", "source": "esm"}]}' "$valid"
out="$(python3 "$validator" "$valid" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "a well-formed populated esm tier should validate OK (rc=$rc): $out"
case "$out" in
  *"1 esm package"*) ;;
  *) fail "OK message should mention '1 esm package', got: $out" ;;
esac

# -- valid: still-empty esm tier (M1-era default) must keep validating -----
empty="$work/empty.json"
make_lockfile '{"packages": []}' "$empty"
out="$(python3 "$validator" "$empty" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "an empty esm tier should still validate OK (rc=$rc): $out"

reject() {
  local desc="$1" esm_json="$2" want_stderr="$3"
  local f="$work/bad.json"
  make_lockfile "$esm_json" "$f"
  local out rc
  out="$(python3 "$validator" "$f" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] || fail "$desc: expected nonzero exit, got 0 (output: $out)"
  case "$out" in
    *"$want_stderr"*) ;;
    *) fail "$desc: expected error to mention '$want_stderr', got: $out" ;;
  esac
}

reject "missing source field" \
  '{"packages": [{"name": "p", "version": "1", "sha256": "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd", "path": "pool/esm-apps/p/p_1_amd64.deb"}]}' \
  "missing required field"

reject "missing path field" \
  '{"packages": [{"name": "p", "version": "1", "sha256": "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd", "source": "esm"}]}' \
  "missing required field"

reject "wrong source value" \
  '{"packages": [{"name": "p", "version": "1", "sha256": "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd", "path": "pool/esm-apps/p/p_1_amd64.deb", "source": "public"}]}' \
  'must be exactly "esm"'

reject "malformed sha256" \
  '{"packages": [{"name": "p", "version": "1", "sha256": "not-a-hash", "path": "pool/esm-apps/p/p_1_amd64.deb", "source": "esm"}]}' \
  "must match"

reject "duplicate esm package name" \
  '{"packages": [{"name": "p", "version": "1", "sha256": "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd", "path": "pool/esm-apps/p/p_1_amd64.deb", "source": "esm"}, {"name": "p", "version": "2", "sha256": "fedcbafedcbafedcbafedcbafedcbafedcbafedcbafedcbafedcbafedcbafedc", "path": "pool/esm-apps/p/p_2_amd64.deb", "source": "esm"}]}' \
  "duplicate package name in esm.packages"

reject "empty-string version" \
  '{"packages": [{"name": "p", "version": "", "sha256": "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd", "path": "pool/esm-apps/p/p_1_amd64.deb", "source": "esm"}]}' \
  "must be a non-empty string"

exit "$fails"
