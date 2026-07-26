#!/usr/bin/env bash
# tests/unit/172-ubx-pro-plan.sh — bin/ubx-pro's own convergence planner:
# attach + esm-apps + Livepatch enable/disable, idempotent against a fixture
# `pro status` (SPEC.md §8.2 "Ubuntu Pro", §5; GitHub issue #82, milestone
# M4 — the issue's own acceptance criterion, "planner converges attach/
# esm-apps/Livepatch enable/disable idempotently against fixture pro
# status"). Mirrors tests/unit/162/163's own shape for bin/ubx-secrets.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

ubx_pro="$UBX_REPO_ROOT/bin/ubx-pro"
[ -x "$ubx_pro" ] || { echo "FAIL: $ubx_pro does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# =====================================================================
# 1) fresh, never-attached machine: declared enable+esm-apps+livepatch ->
#    attach, enable esm-apps, enable livepatch, IN THAT ORDER.
# =====================================================================
manifest_all="$work/manifest-all.json"
cat > "$manifest_all" <<'EOF'
{"version": 1, "enable": true, "tokenSecretPath": "/run/secrets/proToken", "esmApps": true, "livepatch": true}
EOF
observed_fresh="$work/observed-fresh.json"
cat > "$observed_fresh" <<'EOF'
{"version": 1, "attached": false, "services": {}}
EOF

plan1="$work/plan1.json"
"$ubx_pro" plan --manifest "$manifest_all" --observed "$observed_fresh" --out "$plan1" \
  || fail "plan (fresh machine) should succeed"

if ! python3 - "$plan1" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["empty"] is False, p
ops = [(a["op"], a.get("service")) for a in p["actions"]]
assert ops == [("attach", None), ("enable", "esm-apps"), ("enable", "livepatch")], ops
assert p["actions"][0]["tokenSecretName"] == "proToken", p["actions"][0]
PYEOF
then
  fail "plan (fresh machine) did not produce the expected [attach, enable esm-apps, enable livepatch] action sequence"
fi

# =====================================================================
# 2) fully-converged fixture `pro status`: a real no-op (idempotent).
# =====================================================================
observed_converged="$work/observed-converged.json"
cat > "$observed_converged" <<'EOF'
{"version": 1, "attached": true, "services": {"esm-apps": "enabled", "livepatch": "enabled", "esm-infra": "enabled"}}
EOF

plan2="$work/plan2.json"
"$ubx_pro" plan --manifest "$manifest_all" --observed "$observed_converged" --out "$plan2" \
  || fail "plan (already converged) should succeed"

if ! python3 - "$plan2" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["empty"] is True, p
assert p["actions"] == [], p
PYEOF
then
  fail "plan (already converged) should be a real no-op -- got: $(cat "$plan2")"
fi

# =====================================================================
# 3) attached, but esm-apps declared off / livepatch declared off ->
#    disable both, no attach action (already attached).
# =====================================================================
manifest_off="$work/manifest-off.json"
cat > "$manifest_off" <<'EOF'
{"version": 1, "enable": true, "tokenSecretPath": "/run/secrets/proToken", "esmApps": false, "livepatch": false}
EOF

plan3="$work/plan3.json"
"$ubx_pro" plan --manifest "$manifest_off" --observed "$observed_converged" --out "$plan3" \
  || fail "plan (declared services off) should succeed"

if ! python3 - "$plan3" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
ops = [(a["op"], a.get("service")) for a in p["actions"]]
assert ops == [("disable", "esm-apps"), ("disable", "livepatch")], ops
PYEOF
then
  fail "plan (declared services off) did not produce [disable esm-apps, disable livepatch] -- got: $(cat "$plan3")"
fi

# Re-planning against the SAME declared-off manifest but an observed state
# where both are already disabled must be a real no-op (idempotent).
observed_off="$work/observed-off.json"
cat > "$observed_off" <<'EOF'
{"version": 1, "attached": true, "services": {"esm-apps": "disabled", "livepatch": "disabled"}}
EOF
plan3b="$work/plan3b.json"
"$ubx_pro" plan --manifest "$manifest_off" --observed "$observed_off" --out "$plan3b" \
  || fail "plan (services already off) should succeed"
if ! python3 - "$plan3b" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["empty"] is True, p
PYEOF
then
  fail "plan (services already off) should be a real no-op -- got: $(cat "$plan3b")"
fi

# =====================================================================
# 4) declared enable=false (detach), currently attached -> a lone detach,
#    with NO separate per-service disable actions alongside it.
# =====================================================================
manifest_disabled="$work/manifest-disabled.json"
cat > "$manifest_disabled" <<'EOF'
{"version": 1, "enable": false, "tokenSecretPath": "/run/secrets/proToken", "esmApps": false, "livepatch": false}
EOF

plan4="$work/plan4.json"
"$ubx_pro" plan --manifest "$manifest_disabled" --observed "$observed_converged" --out "$plan4" \
  || fail "plan (detach) should succeed"

if ! python3 - "$plan4" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["actions"] == [{"op": "detach"}], p
PYEOF
then
  fail "plan (detach) should emit exactly one lone 'detach' action -- got: $(cat "$plan4")"
fi

# Re-planning against an already-detached observed state is a real no-op.
observed_detached="$work/observed-detached.json"
cat > "$observed_detached" <<'EOF'
{"version": 1, "attached": false, "services": {}}
EOF
plan4b="$work/plan4b.json"
"$ubx_pro" plan --manifest "$manifest_disabled" --observed "$observed_detached" --out "$plan4b" \
  || fail "plan (already detached) should succeed"
if ! python3 - "$plan4b" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["empty"] is True, p
PYEOF
then
  fail "plan (already detached) should be a real no-op -- got: $(cat "$plan4b")"
fi

# =====================================================================
# 5) partial drift: attached + esm-apps enabled, but livepatch disabled
#    while declared true -> only 'enable livepatch', no attach/esm-apps
#    action.
# =====================================================================
observed_partial="$work/observed-partial.json"
cat > "$observed_partial" <<'EOF'
{"version": 1, "attached": true, "services": {"esm-apps": "enabled", "livepatch": "disabled"}}
EOF
plan5="$work/plan5.json"
"$ubx_pro" plan --manifest "$manifest_all" --observed "$observed_partial" --out "$plan5" \
  || fail "plan (partial drift) should succeed"
if ! python3 - "$plan5" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["actions"] == [{"op": "enable", "service": "livepatch"}], p
PYEOF
then
  fail "plan (partial drift) should emit exactly [enable livepatch] -- got: $(cat "$plan5")"
fi

# =====================================================================
# 6) bin/ubx-pro observe: --status-file round-trips a fixture
#    `pro status --format json` document into the observed schema `plan`
#    consumes.
# =====================================================================
status_file="$work/pro-status.json"
cat > "$status_file" <<'EOF'
{"attached": true, "services": [
  {"name": "esm-apps", "status": "enabled"},
  {"name": "livepatch", "status": "disabled"},
  {"name": "esm-infra", "status": "enabled"}
]}
EOF
observed_out="$work/observed-from-status.json"
"$ubx_pro" observe --status-file "$status_file" --out "$observed_out" \
  || fail "ubx-pro observe --status-file should succeed"
if ! python3 - "$observed_out" <<'PYEOF'
import json, sys
o = json.load(open(sys.argv[1]))
assert o["attached"] is True, o
assert o["services"]["esm-apps"] == "enabled", o
assert o["services"]["livepatch"] == "disabled", o
PYEOF
then
  fail "ubx-pro observe did not correctly round-trip the fixture pro-status document -- got: $(cat "$observed_out")"
fi

exit "$fails"
