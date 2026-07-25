#!/usr/bin/env bash
# tests/unit/143-snap-resolver-seam.sh — bin/ubx-snap-resolve's full
# declared-set -> lockfile pipeline, driven through the injectable
# UBX_SNAP_RESOLVE_CMD / --resolve-cmd Store-access seam with a recording
# stub instead of real snapd/network (SPEC.md §4.3, §4.4, §4.5, §5; GitHub
# issue #60, milestone M3: "Store access behind an injectable command seam
# so unit tests run offline"). No network, no snap client, anywhere in this
# file.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

resolve="$UBX_REPO_ROOT/bin/ubx-snap-resolve"
[ -x "$resolve" ] || {
  echo "FAIL: $resolve does not exist or is not executable" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

sha_snap="$(python3 -c "import hashlib;print(hashlib.sha256(b'snap-payload').hexdigest())")"
sha_assert="$(python3 -c "import hashlib;print(hashlib.sha256(b'assert-chain').hexdigest())")"

# A recording stub: logs every "NAME CHANNEL REVISION_PIN" invocation to
# $work/calls.log (one line per call), then prints a canned resolved JSON
# tuple. Whether the reported publisher is verified is controlled by an env
# var so different scenarios below can flip it without rewriting the stub.
stub="$work/stub.sh"
cat > "$stub" <<EOF
#!/bin/sh
echo "\$1 \$2 \$3" >> "$work/calls.log"
verified="\${STUB_VERIFIED:-true}"
publisher="\${STUB_PUBLISHER:-canonical}"
revision="\${STUB_REVISION:-29}"
cat <<JSON
{"revision": \$revision, "publisher": "\$publisher", "publisherVerified": \$verified, "snapUrl": "https://x/\$1.snap", "snapSha256": "$sha_snap", "snapSize": 1024, "assertUrl": "https://x/\$1.assert", "assertSha256": "$sha_assert"}
JSON
EOF
chmod +x "$stub"

decl="$work/decl.json"
cat > "$decl" <<'EOF'
{
  "allowUnverifiedPublishers": false,
  "snaps": {
    "hello-world": {
      "channel": "stable",
      "classic": false,
      "connections": ["network"],
      "config": {"greeting": "hi"},
      "unverifiedPublisher": false
    }
  }
}
EOF

out="$work/out.json"

# -- basic end-to-end resolve through the seam -------------------------
rm -f "$work/calls.log"
resolve_out="$("$resolve" --declaration "$decl" --out "$out" --resolve-cmd "$stub" 2>&1)"
resolve_rc=$?
[ "$resolve_rc" -eq 0 ] || fail "end-to-end resolve through the stub seam should exit 0 (rc=$resolve_rc, output: $resolve_out)"
[ -f "$out" ] || fail "resolve did not write $out"
[ -f "$work/calls.log" ] || fail "the stub was never invoked"
if [ -f "$work/calls.log" ]; then
  [ "$(wc -l < "$work/calls.log")" -eq 1 ] || fail "expected exactly one seam invocation, got: $(cat "$work/calls.log")"
  grep -q '^hello-world stable ' "$work/calls.log" || fail "seam was not invoked as 'hello-world stable <pin>', got: $(cat "$work/calls.log")"
fi

if [ -f "$out" ]; then
  if ! python3 - "$out" <<'PYEOF'
import json
import sys

data = json.load(open(sys.argv[1]))
s = data["snaps"][0]
assert s["name"] == "hello-world", s
assert s["channel"] == "stable", s
assert s["revision"] == 29, s
assert s["classic"] is False, s
assert s["connections"] == ["network"], s
assert s["config"] == {"greeting": "hi"}, s
assert s["publisher"] == "canonical", s
assert s["publisherVerified"] is True, s
PYEOF
  then
    fail "resolved lockfile entry does not carry the expected declared+resolved fields through end to end"
  fi
fi

# -- UBX_SNAP_RESOLVE_CMD (env var) is honored the same as --resolve-cmd --
rm -f "$work/calls.log" "$out"
env_out="$(UBX_SNAP_RESOLVE_CMD="$stub" "$resolve" --declaration "$decl" --out "$out" 2>&1)"
env_rc=$?
[ "$env_rc" -eq 0 ] || fail "UBX_SNAP_RESOLVE_CMD env var should be honored (rc=$env_rc, output: $env_out)"
[ -f "$work/calls.log" ] || fail "UBX_SNAP_RESOLVE_CMD env var did not cause the stub to be invoked"

# -- an unverified publisher, with no opt-in anywhere, is refused ----------
rm -f "$work/calls.log" "$out"
unverified_out="$(STUB_VERIFIED=false STUB_PUBLISHER=randodev "$resolve" --declaration "$decl" --out "$out" --resolve-cmd "$stub" 2>&1)"
unverified_rc=$?
[ "$unverified_rc" -ne 0 ] || fail "an unverified publisher with no opt-in should refuse to resolve"
case "$unverified_out" in
  *"is not verified"*) ;;
  *) fail "unverified-publisher refusal should mention 'is not verified', got: $unverified_out" ;;
esac
[ ! -e "$out" ] || fail "a refused resolve must not leave a lockfile at --out"

# -- per-snap unverifiedPublisher opt-in lets it through -------------------
decl_optin="$work/decl-optin.json"
python3 -c "
import json
d = json.load(open('$decl'))
d['snaps']['hello-world']['unverifiedPublisher'] = True
json.dump(d, open('$decl_optin', 'w'))
"
rm -f "$out"
optin_out="$(STUB_VERIFIED=false STUB_PUBLISHER=randodev "$resolve" --declaration "$decl_optin" --out "$out" --resolve-cmd "$stub" 2>&1)"
optin_rc=$?
[ "$optin_rc" -eq 0 ] || fail "per-snap unverifiedPublisher opt-in should let an unverified publisher through (rc=$optin_rc, output: $optin_out)"
[ -f "$out" ] || fail "opted-in unverified resolve did not write $out"

# -- system-wide allowUnverifiedPublishers also lets it through ------------
decl_allow="$work/decl-allow.json"
python3 -c "
import json
d = json.load(open('$decl'))
d['allowUnverifiedPublishers'] = True
json.dump(d, open('$decl_allow', 'w'))
"
rm -f "$out"
allow_out="$(STUB_VERIFIED=false STUB_PUBLISHER=randodev "$resolve" --declaration "$decl_allow" --out "$out" --resolve-cmd "$stub" 2>&1)"
allow_rc=$?
[ "$allow_rc" -eq 0 ] || fail "system-wide allowUnverifiedPublishers should let an unverified publisher through (rc=$allow_rc, output: $allow_out)"
[ -f "$out" ] || fail "system-wide-opted-in unverified resolve did not write $out"

# -- a declared revision pin is passed to the seam as the 3rd argument, and
# a Store-resolved revision that disagrees with the pin is a hard failure --
decl_pinned="$work/decl-pinned.json"
python3 -c "
import json
d = json.load(open('$decl'))
d['snaps']['hello-world']['revision'] = 999
json.dump(d, open('$decl_pinned', 'w'))
"
rm -f "$work/calls.log" "$out"
pinned_out="$(STUB_REVISION=1 "$resolve" --declaration "$decl_pinned" --out "$out" --resolve-cmd "$stub" 2>&1)"
pinned_rc=$?
[ "$pinned_rc" -ne 0 ] || fail "a Store-resolved revision disagreeing with the declared pin should refuse to resolve (output: $pinned_out)"
[ ! -e "$out" ] || fail "a refused (pin-mismatch) resolve must not leave a lockfile at --out"
if [ -f "$work/calls.log" ]; then
  grep -q '^hello-world stable 999$' "$work/calls.log" || fail "the declared revision pin was not passed to the seam as its 3rd argument, got: $(cat "$work/calls.log")"
fi

# A matching pin resolves cleanly.
rm -f "$work/calls.log" "$out"
matched_out="$(STUB_REVISION=999 "$resolve" --declaration "$decl_pinned" --out "$out" --resolve-cmd "$stub" 2>&1)"
matched_rc=$?
[ "$matched_rc" -eq 0 ] || fail "a Store-resolved revision matching the declared pin should resolve cleanly (rc=$matched_rc, output: $matched_out)"

# -- a seam that fails (nonzero exit) must fail the whole resolve, clearly -
failing_stub="$work/failing-stub.sh"
cat > "$failing_stub" <<'EOF'
#!/bin/sh
echo "boom: simulated Store failure" >&2
exit 1
EOF
chmod +x "$failing_stub"
rm -f "$out"
fail_out="$("$resolve" --declaration "$decl" --out "$out" --resolve-cmd "$failing_stub" 2>&1)"
fail_rc=$?
[ "$fail_rc" -ne 0 ] || fail "a failing seam should fail the whole resolve"
case "$fail_out" in
  *"boom: simulated Store failure"*) ;;
  *) fail "a failing seam's stderr should be surfaced, got: $fail_out" ;;
esac
[ ! -e "$out" ] || fail "a failed resolve must not leave a lockfile at --out"

# -- a seam that prints garbage (not JSON) is a clear, specific error ------
garbage_stub="$work/garbage-stub.sh"
cat > "$garbage_stub" <<'EOF'
#!/bin/sh
echo "not json at all"
EOF
chmod +x "$garbage_stub"
rm -f "$out"
garbage_out="$("$resolve" --declaration "$decl" --out "$out" --resolve-cmd "$garbage_stub" 2>&1)"
garbage_rc=$?
[ "$garbage_rc" -ne 0 ] || fail "a seam printing non-JSON should fail the resolve (output: $garbage_out)"

# -- a seam that omits a required field is a clear, specific error --------
partial_stub="$work/partial-stub.sh"
cat > "$partial_stub" <<'EOF'
#!/bin/sh
echo '{"revision": 1}'
EOF
chmod +x "$partial_stub"
rm -f "$out"
partial_out="$("$resolve" --declaration "$decl" --out "$out" --resolve-cmd "$partial_stub" 2>&1)"
partial_rc=$?
[ "$partial_rc" -ne 0 ] || fail "a seam omitting required fields should fail the resolve"
case "$partial_out" in
  *"missing required field"*) ;;
  *) fail "missing-field seam output should mention 'missing required field', got: $partial_out" ;;
esac

exit "$fails"
