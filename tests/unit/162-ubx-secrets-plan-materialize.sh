#!/usr/bin/env bash
# tests/unit/162-ubx-secrets-plan-materialize.sh — bin/ubx-secrets' `plan`
# subcommand: the canonical materialize create/update/remove/no-op diff
# (SPEC.md §8.1, §4.3 "none" downtime; GitHub issue #78, milestone M4).
# Mirrors tests/unit/101-ubx-users-plan-create-modify.sh's own style,
# adapted to bin/ubx-secrets' manifest/observed/plan schemas (see that
# script's own header for the full schema descriptions).
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

ubx_secrets="$UBX_REPO_ROOT/bin/ubx-secrets"
[ -x "$ubx_secrets" ] || { echo "FAIL: $ubx_secrets does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# plan_of NAME MANIFEST_JSON OBSERVED_JSON -- writes $work/$NAME.json,
# returns ubx-secrets' own exit code.
plan_of() {
  local name="$1" manifest="$2" observed="$3"
  "$ubx_secrets" plan --manifest "$manifest" --observed "$observed" --out "$work/$name.json"
}

# =====================================================================
# 1) empty observed state -> everything is a `create`.
# =====================================================================
manifest1="$work/manifest1.json"
cat > "$manifest1" <<'EOF'
{"version": 1, "secrets": [
  {"name": "proToken", "owner": "root", "group": "root", "mode": "0400", "dst": "/run/secrets/proToken", "environmentVariable": null},
  {"name": "apiToken", "owner": "root", "group": "root", "mode": "0400", "dst": "/run/secrets/apiToken", "environmentVariable": "API_TOKEN"}
]}
EOF
observed_empty="$work/observed-empty.json"
echo '{"version": 1, "entries": []}' > "$observed_empty"

rc=0
plan_of plan1 "$manifest1" "$observed_empty" || rc=$?
[ "$rc" -eq 0 ] || fail "plan (all-create) should exit 0, got $rc"

if ! python3 - "$work/plan1.json" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["empty"] is False, "plan should not be marked empty"
names = sorted(e["name"] for e in p["materialize"]["create"])
assert names == ["apiToken", "proToken"], f"expected both secrets created, got {names}"
assert p["materialize"]["update"] == [], "no updates expected"
assert p["materialize"]["remove"] == [], "no removals expected"
env_names = sorted(e["name"] for e in p["env"]["create"])
assert env_names == ["apiToken"], f"expected only apiToken's env file created, got {env_names}"
assert p["symlink"]["create"] == [], "no custom-dst secrets declared -- no symlink actions expected"
print("OK: all-create plan shape")
PYEOF
then
  fail "plan1.json did not have the expected all-create shape"
fi

# =====================================================================
# 2) fully converged observed state -> a real no-op (empty plan).
# =====================================================================
observed_converged="$work/observed-converged.json"
cat > "$observed_converged" <<'EOF'
{"version": 1, "entries": [
  {"name": "proToken", "owner": "root", "group": "root", "mode": "0400", "envVar": null, "symlinkTarget": null},
  {"name": "apiToken", "owner": "root", "group": "root", "mode": "0400", "envVar": "API_TOKEN", "symlinkTarget": null}
]}
EOF
rc=0
plan_of plan2 "$manifest1" "$observed_converged" || rc=$?
[ "$rc" -eq 0 ] || fail "plan (converged) should exit 0, got $rc"
if ! python3 - "$work/plan2.json" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["empty"] is True, f"a fully converged input should plan to a real no-op, got: {p}"
PYEOF
then
  fail "plan2.json (converged) was not a real no-op"
fi

# =====================================================================
# 3) an owner/mode disagreement on an already-materialized secret ->
#    `materialize.update`.
# =====================================================================
observed_drifted="$work/observed-drifted.json"
cat > "$observed_drifted" <<'EOF'
{"version": 1, "entries": [
  {"name": "proToken", "owner": "nobody", "group": "root", "mode": "0644", "envVar": null, "symlinkTarget": null},
  {"name": "apiToken", "owner": "root", "group": "root", "mode": "0400", "envVar": "API_TOKEN", "symlinkTarget": null}
]}
EOF
rc=0
plan_of plan3 "$manifest1" "$observed_drifted" || rc=$?
[ "$rc" -eq 0 ] || fail "plan (drifted metadata) should exit 0, got $rc"
if ! python3 - "$work/plan3.json" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["empty"] is False
upd = p["materialize"]["update"]
assert len(upd) == 1 and upd[0]["name"] == "proToken", f"expected exactly one update for proToken, got {upd}"
changes = upd[0]["changes"]
assert set(changes) == {"owner", "mode"}, f"expected owner+mode changes only, got {changes}"
assert changes["owner"] == {"from": "nobody", "to": "root"}
assert changes["mode"] == {"from": "0644", "to": "0400"}
assert p["materialize"]["create"] == []
assert p["materialize"]["remove"] == []
PYEOF
then
  fail "plan3.json did not have the expected single-update shape"
fi

# =====================================================================
# 4) an observed secret no longer declared -> `materialize.remove`.
# =====================================================================
manifest_smaller="$work/manifest-smaller.json"
cat > "$manifest_smaller" <<'EOF'
{"version": 1, "secrets": [
  {"name": "apiToken", "owner": "root", "group": "root", "mode": "0400", "dst": "/run/secrets/apiToken", "environmentVariable": "API_TOKEN"}
]}
EOF
rc=0
plan_of plan4 "$manifest_smaller" "$observed_converged" || rc=$?
[ "$rc" -eq 0 ] || fail "plan (removal) should exit 0, got $rc"
if ! python3 - "$work/plan4.json" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["empty"] is False
rem = p["materialize"]["remove"]
assert len(rem) == 1 and rem[0] == {"name": "proToken", "dst": "/run/secrets/proToken"}, f"expected proToken removed, got {rem}"
assert p["materialize"]["create"] == []
assert p["materialize"]["update"] == []
PYEOF
then
  fail "plan4.json did not have the expected single-removal shape"
fi

# =====================================================================
# 5) determinism: identical inputs -> byte-identical plan across repeated
#    runs (this project's standing rule).
# =====================================================================
"$ubx_secrets" plan --manifest "$manifest1" --observed "$observed_empty" --out "$work/det1.json"
"$ubx_secrets" plan --manifest "$manifest1" --observed "$observed_empty" --out "$work/det2.json"
if ! diff -q "$work/det1.json" "$work/det2.json" > /dev/null; then
  fail "plan is not deterministic across repeated runs against identical inputs"
fi

# =====================================================================
# 6) --observed omitted entirely: default to "nothing materialized yet".
# =====================================================================
rc=0
"$ubx_secrets" plan --manifest "$manifest1" --out "$work/plan6.json" || rc=$?
[ "$rc" -eq 0 ] || fail "plan without --observed should exit 0 (default: nothing materialized), got $rc"
if ! python3 - "$work/plan6.json" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
names = sorted(e["name"] for e in p["materialize"]["create"])
assert names == ["apiToken", "proToken"], f"expected both secrets created by default, got {names}"
PYEOF
then
  fail "plan6.json (no --observed) did not default to all-create"
fi

exit "$fails"
