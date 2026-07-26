#!/usr/bin/env bash
# tests/unit/163-ubx-secrets-plan-env-symlink.sh — bin/ubx-secrets' `plan`
# subcommand: environmentVariable (.env) rendering decisions and custom-dst
# symlink planning, including the already-converged no-op case (SPEC.md
# §8.1; GitHub issue #78, milestone M4). Mirrors tests/unit/162's own style
# and fixture conventions.
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

manifest="$work/manifest.json"
cat > "$manifest" <<'EOF'
{"version": 1, "secrets": [
  {"name": "apiToken", "owner": "root", "group": "root", "mode": "0400", "dst": "/run/secrets/apiToken", "environmentVariable": "API_TOKEN"},
  {"name": "wgKey", "owner": "root", "group": "root", "mode": "0400", "dst": "/etc/wireguard/wg0.key", "environmentVariable": null}
]}
EOF

# =====================================================================
# 1) env.create: declared environmentVariable, none observed yet.
# =====================================================================
observed1="$work/observed1.json"
cat > "$observed1" <<'EOF'
{"version": 1, "entries": [
  {"name": "apiToken", "owner": "root", "group": "root", "mode": "0400", "envVar": null, "symlinkTarget": null},
  {"name": "wgKey", "owner": "root", "group": "root", "mode": "0400", "envVar": null, "symlinkTarget": null}
]}
EOF
"$ubx_secrets" plan --manifest "$manifest" --observed "$observed1" --out "$work/plan1.json"
if ! python3 - "$work/plan1.json" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
c = p["env"]["create"]
assert len(c) == 1 and c[0]["name"] == "apiToken", f"expected apiToken's env file created, got {c}"
assert c[0]["path"] == "/run/secrets/apiToken.env"
assert c[0]["environmentVariable"] == "API_TOKEN"
assert p["env"]["update"] == [] and p["env"]["remove"] == []
# wgKey has a custom dst and is NOT yet correctly symlinked (symlinkTarget
# null != canonical) -> symlink.create.
sc = p["symlink"]["create"]
assert len(sc) == 1 and sc[0] == {"name": "wgKey", "path": "/etc/wireguard/wg0.key", "target": "/run/secrets/wgKey"}, f"unexpected symlink plan: {sc}"
PYEOF
then
  fail "plan1.json (env create + symlink create) did not have the expected shape"
fi

# =====================================================================
# 2) env.update: a declared environmentVariable NAME change.
# =====================================================================
observed2="$work/observed2.json"
cat > "$observed2" <<'EOF'
{"version": 1, "entries": [
  {"name": "apiToken", "owner": "root", "group": "root", "mode": "0400", "envVar": "OLD_VAR_NAME", "symlinkTarget": null},
  {"name": "wgKey", "owner": "root", "group": "root", "mode": "0400", "envVar": null, "symlinkTarget": "/run/secrets/wgKey"}
]}
EOF
"$ubx_secrets" plan --manifest "$manifest" --observed "$observed2" --out "$work/plan2.json"
if ! python3 - "$work/plan2.json" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
u = p["env"]["update"]
assert len(u) == 1 and u[0]["name"] == "apiToken", f"expected apiToken's env var name update, got {u}"
assert u[0]["changes"]["environmentVariable"] == {"from": "OLD_VAR_NAME", "to": "API_TOKEN"}
assert p["env"]["create"] == [] and p["env"]["remove"] == []
# wgKey's symlink is ALREADY correct (symlinkTarget == canonical) -> no
# symlink action planned (the no-op case this file's header promises).
assert p["symlink"]["create"] == [], f"an already-correct symlink must not be re-planned, got {p['symlink']['create']}"
PYEOF
then
  fail "plan2.json (env update + symlink no-op) did not have the expected shape"
fi

# =====================================================================
# 3) env.remove: environmentVariable dropped from the declaration.
# =====================================================================
manifest_no_env="$work/manifest-no-env.json"
cat > "$manifest_no_env" <<'EOF'
{"version": 1, "secrets": [
  {"name": "apiToken", "owner": "root", "group": "root", "mode": "0400", "dst": "/run/secrets/apiToken", "environmentVariable": null}
]}
EOF
observed3="$work/observed3.json"
cat > "$observed3" <<'EOF'
{"version": 1, "entries": [
  {"name": "apiToken", "owner": "root", "group": "root", "mode": "0400", "envVar": "API_TOKEN", "symlinkTarget": null}
]}
EOF
"$ubx_secrets" plan --manifest "$manifest_no_env" --observed "$observed3" --out "$work/plan3.json"
if ! python3 - "$work/plan3.json" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
r = p["env"]["remove"]
assert len(r) == 1 and r[0] == {"name": "apiToken", "path": "/run/secrets/apiToken.env"}, f"expected apiToken's env file removed, got {r}"
assert p["env"]["create"] == [] and p["env"]["update"] == []
# materialize itself is unaffected (owner/group/mode still agree).
assert p["materialize"]["create"] == [] and p["materialize"]["update"] == [] and p["materialize"]["remove"] == []
PYEOF
then
  fail "plan3.json (env remove) did not have the expected shape"
fi

# =====================================================================
# 4) a stale custom-dst symlink pointing somewhere else is re-planned
#    (symlinkTarget disagrees with canonical -> symlink.create fires again).
# =====================================================================
observed4="$work/observed4.json"
cat > "$observed4" <<'EOF'
{"version": 1, "entries": [
  {"name": "apiToken", "owner": "root", "group": "root", "mode": "0400", "envVar": "API_TOKEN", "symlinkTarget": null},
  {"name": "wgKey", "owner": "root", "group": "root", "mode": "0400", "envVar": null, "symlinkTarget": "/run/secrets/some-other-stale-target"}
]}
EOF
"$ubx_secrets" plan --manifest "$manifest" --observed "$observed4" --out "$work/plan4.json"
if ! python3 - "$work/plan4.json" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
sc = p["symlink"]["create"]
assert len(sc) == 1 and sc[0]["name"] == "wgKey" and sc[0]["target"] == "/run/secrets/wgKey", f"a stale symlink target must be re-planned, got {sc}"
PYEOF
then
  fail "plan4.json (stale symlink) did not re-plan the symlink"
fi

exit "$fails"
