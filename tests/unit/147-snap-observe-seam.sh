#!/usr/bin/env bash
# tests/unit/147-snap-observe-seam.sh — `ubx-snap observe`'s injectable
# UBX_SNAP_QUERY_CMD / --query-cmd snapd-query seam, and `ubx-snap
# report`'s human-readable rendering (SPEC.md §4.3; GitHub issue #61,
# milestone M3: "Observed-state reading MUST go behind an injectable
# snap/snapd-query command seam ... so unit tests feed canned observed
# state offline"). No network, no snapd, anywhere in this file.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

snap="$UBX_REPO_ROOT/bin/ubx-snap"
[ -x "$snap" ] || { echo "FAIL: $snap does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# -- a well-formed canned stub, invoked via --query-cmd --------------------
good_stub="$work/good-stub.sh"
cat > "$good_stub" <<'EOF'
#!/bin/sh
cat <<JSON
{"version": 1, "refreshHold": true, "snaps": [
  {"name": "hello-world", "revision": 29, "channel": "stable",
   "classic": false, "connections": ["network"], "config": {"greeting": "hi"}}
]}
JSON
EOF
chmod +x "$good_stub"

out="$work/observed.json"
"$snap" observe --query-cmd "$good_stub" --out "$out"
rc=$?
[ "$rc" -eq 0 ] || fail "observe through a well-formed --query-cmd stub should exit 0, got rc=$rc"

check="$(python3 -c "
import json
d = json.load(open('$out'))
assert d['version'] == 1, d
assert d['refreshHold'] is True, d
s = d['snaps'][0]
assert s['name'] == 'hello-world', s
assert s['revision'] == 29, s
assert s['connections'] == ['network'], s
assert s['config'] == {'greeting': 'hi'}, s
print('OK')
")"
[ "$check" = "OK" ] || fail "observe output through --query-cmd did not round-trip the stub's JSON: $check"

# -- the SAME stub, invoked via the UBX_SNAP_QUERY_CMD env var instead -----
env_out="$work/observed-env.json"
UBX_SNAP_QUERY_CMD="$good_stub" "$snap" observe --out "$env_out"
env_rc=$?
[ "$env_rc" -eq 0 ] || fail "observe should honor UBX_SNAP_QUERY_CMD the same as --query-cmd, got rc=$env_rc"
[ -s "$env_out" ] || fail "UBX_SNAP_QUERY_CMD-driven observe produced no output"
diff -q "$out" "$env_out" > /dev/null 2>&1 || fail "--query-cmd and UBX_SNAP_QUERY_CMD should produce identical output for the same stub"

# --query-cmd takes precedence over UBX_SNAP_QUERY_CMD when both given.
other_stub="$work/other-stub.sh"
cat > "$other_stub" <<'EOF'
#!/bin/sh
echo '{"version": 1, "refreshHold": false, "snaps": []}'
EOF
chmod +x "$other_stub"
precedence_out="$work/precedence.json"
UBX_SNAP_QUERY_CMD="$other_stub" "$snap" observe --query-cmd "$good_stub" --out "$precedence_out"
precedence_check="$(python3 -c "
import json
d = json.load(open('$precedence_out'))
assert d['refreshHold'] is True, d
print('OK')
")"
[ "$precedence_check" = "OK" ] || fail "--query-cmd should take precedence over UBX_SNAP_QUERY_CMD: $precedence_check"

# -- a seam that fails (nonzero exit) must fail 'observe', clearly ---------
failing_stub="$work/failing-stub.sh"
cat > "$failing_stub" <<'EOF'
#!/bin/sh
echo "boom: simulated snapd failure" >&2
exit 1
EOF
chmod +x "$failing_stub"
fail_err="$("$snap" observe --query-cmd "$failing_stub" 2>&1)"
fail_rc=$?
[ "$fail_rc" -ne 0 ] || fail "a failing query seam should fail 'observe'"
case "$fail_err" in
  *"exited nonzero"*) ;;
  *) fail "a failing seam's failure should be surfaced clearly, got: $fail_err" ;;
esac

# -- a seam that prints garbage (not JSON) is a clear, specific error -----
garbage_stub="$work/garbage-stub.sh"
cat > "$garbage_stub" <<'EOF'
#!/bin/sh
echo "not json at all"
EOF
chmod +x "$garbage_stub"
garbage_err="$("$snap" observe --query-cmd "$garbage_stub" 2>&1)"
garbage_rc=$?
[ "$garbage_rc" -ne 0 ] || fail "a seam printing non-JSON should fail 'observe'"
case "$garbage_err" in
  *"well-formed JSON"*) ;;
  *) fail "non-JSON seam output should mention 'well-formed JSON', got: $garbage_err" ;;
esac

# -- a seam whose JSON is missing a required top-level field is refused ---
missing_hold_stub="$work/missing-hold-stub.sh"
cat > "$missing_hold_stub" <<'EOF'
#!/bin/sh
echo '{"version": 1, "snaps": []}'
EOF
chmod +x "$missing_hold_stub"
missing_err="$("$snap" observe --query-cmd "$missing_hold_stub" 2>&1)"
missing_rc=$?
[ "$missing_rc" -ne 0 ] || fail "a seam omitting 'refreshHold' should fail 'observe'"
case "$missing_err" in
  *"refreshHold"*) ;;
  *) fail "missing-field seam output should mention 'refreshHold', got: $missing_err" ;;
esac

# -- a seam whose per-snap entry is missing a required field is refused ---
missing_snap_field_stub="$work/missing-snap-field-stub.sh"
cat > "$missing_snap_field_stub" <<'EOF'
#!/bin/sh
echo '{"version": 1, "refreshHold": false, "snaps": [{"name": "x"}]}'
EOF
chmod +x "$missing_snap_field_stub"
missing_snap_err="$("$snap" observe --query-cmd "$missing_snap_field_stub" 2>&1)"
missing_snap_rc=$?
[ "$missing_snap_rc" -ne 0 ] || fail "a seam with an incomplete snap entry should fail 'observe'"
case "$missing_snap_err" in
  *"missing field"*) ;;
  *) fail "incomplete-snap-entry seam output should mention 'missing field', got: $missing_snap_err" ;;
esac

# =====================================================================
# report: renders an already-computed plan as human-readable text.
# =====================================================================
old="$work/old.json"
echo '{"version": 1, "snaps": []}' > "$old"
new="$work/new.json"
cat > "$new" <<'EOF'
{"version": 1, "snaps": [
  {"name": "hello-world", "channel": "stable", "revision": 29, "classic": false,
   "publisher": "Canonical", "publisherVerified": true, "connections": ["network"],
   "config": {"greeting": "hi"}}
]}
EOF
observed_empty="$work/observed-empty.json"
echo '{"version": 1, "refreshHold": true, "snaps": []}' > "$observed_empty"

plan_json="$work/plan.json"
"$snap" plan --old-manifest "$old" --new-manifest "$new" --observed-manifest "$observed_empty" --out "$plan_json"

report_out="$("$snap" report --plan "$plan_json")"
case "$report_out" in
  *"hello-world"*) ;;
  *) fail "report output does not mention hello-world: $report_out" ;;
esac
case "$report_out" in
  *"action(s) planned"*) ;;
  *) fail "report output does not summarize action count: $report_out" ;;
esac

# -- report on a fully converged (empty-actions) plan says so plainly ------
empty_plan="$work/empty-plan.json"
"$snap" plan --old-manifest "$old" --new-manifest "$old" --observed-manifest "$observed_empty" --out "$empty_plan"
empty_report="$("$snap" report --plan "$empty_plan")"
case "$empty_report" in
  *"nothing to do"*|*"fully converged"*) ;;
  *) fail "report on an empty plan should say there's nothing to do, got: $empty_report" ;;
esac

exit "$fails"
