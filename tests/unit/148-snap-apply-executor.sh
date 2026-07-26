#!/usr/bin/env bash
# tests/unit/148-snap-apply-executor.sh — bin/ubx-snap-apply's plan->snapd
# executor (SPEC.md §4.3 switching-table row "Snaps (add/remove/pin/
# connect/config) | converge snapd via its API; vendored payloads
# signed-sideloaded; auto-refresh held permanently", §4.4; GitHub issue
# #62, milestone M3).
#
# Exercises every op bin/ubx-snap plan can emit (ack+install, ack+refresh,
# revert, remove, connect, disconnect, set, unset, hold), asserting the
# exact ordered sequence of (stubbed) `snap` calls bin/ubx-snap-apply
# issues through its injectable UBX_SNAP_CMD seam -- see that script's
# header for the seam and the payload/assertion path convention. No
# root, network, or KVM anywhere in this file (tests/README.md).
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

apply="$UBX_REPO_ROOT/bin/ubx-snap-apply"
[ -x "$apply" ] || { echo "FAIL: $apply does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

log="$work/snap-calls.log"
: > "$log"

# -- a recording stub standing in for the real `snap` client ----------------
stub="$work/snap-stub.sh"
cat > "$stub" <<EOF
#!/bin/sh
echo "\$*" >> "$log"
exit 0
EOF
chmod +x "$stub"

payload_dir="$work/payloads"
assert_dir="$work/assertions"
mkdir -p "$payload_dir" "$assert_dir"

# =====================================================================
# 1) a single plan covering every op, applied through --snap-cmd
# =====================================================================
plan="$work/plan.json"
cat > "$plan" <<'EOF'
{"version": 1, "actions": [
  {"op": "ack", "name": "firefox", "revision": 4090},
  {"op": "install", "name": "firefox", "revision": 4090, "channel": "stable", "classic": false},
  {"op": "ack", "name": "code", "revision": 55},
  {"op": "refresh", "name": "code", "fromRevision": 40, "toRevision": 55, "channel": "stable"},
  {"op": "revert", "name": "hello-world", "fromRevision": 30, "toRevision": 29},
  {"op": "remove", "name": "gone-snap"},
  {"op": "connect", "name": "firefox", "interface": "camera"},
  {"op": "disconnect", "name": "firefox", "interface": "network"},
  {"op": "set", "name": "firefox", "key": "greeting", "value": "hi"},
  {"op": "set", "name": "firefox", "key": "enabled", "value": true},
  {"op": "unset", "name": "firefox", "key": "old-key"},
  {"op": "hold", "mode": "forever"}
]}
EOF

rc=0
apply_out="$("$apply" --plan "$plan" --payload-dir "$payload_dir" --assert-dir "$assert_dir" --snap-cmd "$stub" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "apply of a full, well-formed plan should exit 0, got $rc: $apply_out"

mapfile -t calls < "$log"
[ "${#calls[@]}" -eq 12 ] || fail "expected 12 stubbed snap calls, got ${#calls[@]}: $(printf '%s\n' "${calls[@]}")"

expect_call() {
  local idx="$1" want="$2"
  local got="${calls[$idx]:-<missing>}"
  [ "$got" = "$want" ] || fail "call[$idx]: expected [$want], got [$got]"
}

expect_call 0 "ack $assert_dir/firefox_4090.snap-declaration"
expect_call 1 "install --dangerous $payload_dir/firefox_4090.snap"
expect_call 2 "ack $assert_dir/code_55.snap-declaration"
expect_call 3 "refresh --dangerous $payload_dir/code_55.snap"
expect_call 4 "revert hello-world --revision=29"
expect_call 5 "remove gone-snap"
expect_call 6 "connect firefox:camera :camera"
expect_call 7 "disconnect firefox:network"
expect_call 8 "set firefox greeting=hi"
expect_call 9 "set firefox enabled=true"
expect_call 10 "unset firefox old-key"
expect_call 11 "refresh --hold=forever"

# ack must precede its own install/refresh; install/refresh must precede
# connect/set/unset for the same snap (acceptance criteria).
firefox_install_idx=1
firefox_connect_idx=6
[ "$firefox_install_idx" -lt "$firefox_connect_idx" ] || fail "install must precede connect for the same snap"

# classic snaps get --classic on install.
classic_plan="$work/classic-plan.json"
cat > "$classic_plan" <<'EOF'
{"version": 1, "actions": [
  {"op": "ack", "name": "classic-app", "revision": 1},
  {"op": "install", "name": "classic-app", "revision": 1, "channel": "stable", "classic": true}
]}
EOF
: > "$log"
"$apply" --plan "$classic_plan" --payload-dir "$payload_dir" --assert-dir "$assert_dir" --snap-cmd "$stub" \
  || fail "classic install plan should apply cleanly"
classic_call="$(sed -n '2p' "$log")"
[ "$classic_call" = "install --dangerous --classic $payload_dir/classic-app_1.snap" ] \
  || fail "classic install should pass --classic, got: $classic_call"

# =====================================================================
# 2) empty plan -> zero calls, exit 0
# =====================================================================
empty_plan="$work/empty-plan.json"
echo '{"version": 1, "actions": []}' > "$empty_plan"
: > "$log"
empty_rc=0
empty_out="$("$apply" --plan "$empty_plan" --payload-dir "$payload_dir" --assert-dir "$assert_dir" --snap-cmd "$stub" 2>&1)" || empty_rc=$?
[ "$empty_rc" -eq 0 ] || fail "an empty plan should exit 0, got $empty_rc: $empty_out"
[ ! -s "$log" ] || fail "an empty plan must issue zero snap calls, got: $(cat "$log")"

# =====================================================================
# 3) idempotent re-apply: running the SAME non-empty plan twice issues
#    the same ordered sequence twice, with no error either time.
# =====================================================================
: > "$log"
"$apply" --plan "$plan" --payload-dir "$payload_dir" --assert-dir "$assert_dir" --snap-cmd "$stub" \
  || fail "first apply of the full plan should succeed"
first_run_count=$(wc -l < "$log")
"$apply" --plan "$plan" --payload-dir "$payload_dir" --assert-dir "$assert_dir" --snap-cmd "$stub" \
  || fail "re-applying the identical plan should succeed (idempotent within a plan)"
second_run_count=$(wc -l < "$log")
[ "$second_run_count" -eq $((first_run_count * 2)) ] \
  || fail "re-applying the same plan should append the identical call sequence again, got $first_run_count then $second_run_count total lines"
first_half="$(sed -n "1,${first_run_count}p" "$log")"
second_half="$(sed -n "$((first_run_count + 1)),$((first_run_count * 2))p" "$log")"
[ "$first_half" = "$second_half" ] || fail "re-applying the same plan should issue an identical call sequence the second time"

# =====================================================================
# 4) the UBX_SNAP_CMD env var works the same as --snap-cmd, and
#    --snap-cmd takes precedence when both are given.
# =====================================================================
env_log="$work/env-calls.log"
: > "$env_log"
env_stub="$work/env-stub.sh"
cat > "$env_stub" <<EOF
#!/bin/sh
echo "\$*" >> "$env_log"
exit 0
EOF
chmod +x "$env_stub"
hold_plan="$work/hold-plan.json"
echo '{"version": 1, "actions": [{"op": "hold", "mode": "forever"}]}' > "$hold_plan"

UBX_SNAP_CMD="$env_stub" "$apply" --plan "$hold_plan" || fail "UBX_SNAP_CMD should be honored the same as --snap-cmd"
[ -s "$env_log" ] || fail "UBX_SNAP_CMD-driven apply produced no stub call"
[ "$(cat "$env_log")" = "refresh --hold=forever" ] || fail "unexpected UBX_SNAP_CMD call: $(cat "$env_log")"

other_log="$work/other-calls.log"
: > "$other_log"
other_stub="$work/other-stub.sh"
cat > "$other_stub" <<EOF
#!/bin/sh
echo "\$*" >> "$other_log"
exit 0
EOF
chmod +x "$other_stub"
UBX_SNAP_CMD="$env_stub" "$apply" --plan "$hold_plan" --snap-cmd "$other_stub" \
  || fail "--snap-cmd should take precedence over UBX_SNAP_CMD"
[ -s "$other_log" ] || fail "--snap-cmd should have taken precedence over UBX_SNAP_CMD, but the other stub saw no call"

# =====================================================================
# 5) a failing seam call aborts the whole apply (fail-fast), nonzero exit.
# =====================================================================
failing_stub="$work/failing-stub.sh"
cat > "$failing_stub" <<'EOF'
#!/bin/sh
echo "boom: simulated snapd failure" >&2
exit 1
EOF
chmod +x "$failing_stub"
fail_rc=0
"$apply" --plan "$plan" --payload-dir "$payload_dir" --assert-dir "$assert_dir" --snap-cmd "$failing_stub" > /dev/null 2>&1 || fail_rc=$?
[ "$fail_rc" -ne 0 ] || fail "a failing snap-cmd seam call should fail the whole apply"

# =====================================================================
# 6) an unknown plan op is refused, clearly.
# =====================================================================
bad_plan="$work/bad-plan.json"
echo '{"version": 1, "actions": [{"op": "frobnicate", "name": "x"}]}' > "$bad_plan"
bad_err="$("$apply" --plan "$bad_plan" --snap-cmd "$stub" 2>&1)"
bad_rc=$?
[ "$bad_rc" -ne 0 ] || fail "an unknown plan op should be refused"
case "$bad_err" in
  *"unknown plan action"*) ;;
  *) fail "unknown-op refusal should mention 'unknown plan action', got: $bad_err" ;;
esac

exit "$fails"
