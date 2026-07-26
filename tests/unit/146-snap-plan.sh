#!/usr/bin/env bash
# tests/unit/146-snap-plan.sh — `ubx-snap plan`'s diff/convergence
# algorithm: fresh install, no-op reconverge, revision change
# (refresh-forward and revert-backward), connection add/remove, config
# set/unset, permanent auto-refresh hold, and the removal-scope rule
# (SPEC.md §4.3 "Snaps (add/remove/pin/connect/config) | converge snapd via
# its API; vendored payloads signed-sideloaded; auto-refresh held
# permanently"; GitHub issue #61, milestone M3).
#
# Every fixture manifest here is hand-crafted directly in bin/ubx-snap's
# own manifest schemas (see that script's header) -- no `nix` binary, real
# snapd, or network access is needed to exercise `plan` itself.
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

declared_entry() {
  # declared_entry NAME CHANNEL REVISION CLASSIC CONNECTIONS_JSON CONFIG_JSON
  cat <<EOF
{"name": "$1", "channel": "$2", "revision": $3, "classic": $4, "publisher": "Canonical", "publisherVerified": true, "connections": $5, "config": $6}
EOF
}

observed_entry() {
  # observed_entry NAME CHANNEL REVISION CLASSIC CONNECTIONS_JSON CONFIG_JSON
  cat <<EOF
{"name": "$1", "revision": $3, "channel": "$2", "classic": $4, "connections": $5, "config": $6}
EOF
}

# =====================================================================
# Scenario setup:
#   - converged   : unchanged in old/new/observed -> must produce NOTHING
#   - installme   : declared new, absent from observed -> install
#   - upme        : revision increases -> ack + refresh
#   - downme      : revision decreases -> revert (no ack)
#   - connectme   : declared connections differ from observed -> connect/disconnect
#   - configme    : declared config differs from observed -> set/unset
#   - goneold     : in OLD and OBSERVED, dropped from NEW -> remove
#   - nevermanaged: in OBSERVED only (never in OLD or NEW) -> must NEVER be removed
# =====================================================================

old="$work/old.json"
cat > "$old" <<EOF
{"version": 1, "snaps": [
$(declared_entry converged stable 10 false '[]' '{}'),
$(declared_entry upme stable 10 false '[]' '{}'),
$(declared_entry downme stable 20 false '[]' '{}'),
$(declared_entry connectme stable 10 false '["network"]' '{}'),
$(declared_entry configme stable 10 false '[]' '{"key-a": "old"}'),
$(declared_entry goneold stable 5 false '[]' '{}')
]}
EOF

new="$work/new.json"
cat > "$new" <<EOF
{"version": 1, "snaps": [
$(declared_entry converged stable 10 false '[]' '{}'),
$(declared_entry installme edge 7 true '["home"]' '{"greeting": "hi"}'),
$(declared_entry upme stable 15 false '[]' '{}'),
$(declared_entry downme stable 12 false '[]' '{}'),
$(declared_entry connectme stable 10 false '["camera", "network"]' '{}'),
$(declared_entry configme stable 10 false '[]' '{"key-a": "new", "key-b": "added"}')
]}
EOF

observed="$work/observed.json"
cat > "$observed" <<EOF
{"version": 1, "refreshHold": false, "snaps": [
$(observed_entry converged stable 10 false '[]' '{}'),
$(observed_entry upme stable 10 false '[]' '{}'),
$(observed_entry downme stable 20 false '[]' '{}'),
$(observed_entry connectme stable 10 false '["network", "legacy"]' '{}'),
$(observed_entry configme stable 10 false '[]' '{"key-a": "old", "key-c": "stale"}'),
$(observed_entry goneold stable 5 false '[]' '{}'),
$(observed_entry nevermanaged stable 1 false '[]' '{}')
]}
EOF

plan_out="$work/plan.json"
"$snap" plan --old-manifest "$old" --new-manifest "$new" --observed-manifest "$observed" --out "$plan_out"
rc=$?
[ "$rc" -eq 0 ] || fail "plan should exit 0, got rc=$rc"

check="$(python3 - "$plan_out" <<'PYEOF'
import json
import sys

data = json.load(open(sys.argv[1]))
assert data["version"] == 1, data
actions = data["actions"]

by_op = {}
for a in actions:
    by_op.setdefault(a["op"], []).append(a)

errors = []

# -- converged snap: no action at all, anywhere -----------------------
for a in actions:
    if a.get("name") == "converged":
        errors.append(f"'converged' should produce NO action, found: {a}")

# -- fresh install: ack + install, ack precedes install ----------------
names_ack = [a["name"] for a in by_op.get("ack", [])]
names_install = [a["name"] for a in by_op.get("install", [])]
if "installme" not in names_ack:
    errors.append("fresh install did not plan an 'ack' for installme")
if "installme" not in names_install:
    errors.append("fresh install did not plan an 'install' for installme")
idx_ack = next((i for i, a in enumerate(actions) if a["op"] == "ack" and a["name"] == "installme"), None)
idx_install = next((i for i, a in enumerate(actions) if a["op"] == "install" and a["name"] == "installme"), None)
if idx_ack is None or idx_install is None or idx_ack >= idx_install:
    errors.append("ack must precede install for the same snap")
install_action = next(a for a in actions if a["op"] == "install" and a["name"] == "installme")
if install_action["revision"] != 7 or install_action["channel"] != "edge" or install_action["classic"] is not True:
    errors.append(f"install action fields wrong: {install_action}")

# fresh install's declared connections/config are fully planned (observed
# treated as empty for a never-installed snap).
connects_installme = [a["interface"] for a in by_op.get("connect", []) if a["name"] == "installme"]
if connects_installme != ["home"]:
    errors.append(f"fresh install's declared connections should all be 'connect', got: {connects_installme}")
sets_installme = [(a["key"], a["value"]) for a in by_op.get("set", []) if a["name"] == "installme"]
if sets_installme != [("greeting", "hi")]:
    errors.append(f"fresh install's declared config should all be 'set', got: {sets_installme}")
# ack/install must precede connect/set for the SAME snap.
idx_connect = next((i for i, a in enumerate(actions) if a["op"] == "connect" and a["name"] == "installme"), None)
idx_set = next((i for i, a in enumerate(actions) if a["op"] == "set" and a["name"] == "installme"), None)
if idx_install >= idx_connect or idx_install >= idx_set:
    errors.append("install must precede connect/set for the same snap")

# -- revision increase: ack + refresh, never revert ---------------------
if "upme" not in [a["name"] for a in by_op.get("ack", [])]:
    errors.append("revision increase (upme) did not plan an 'ack'")
refresh_upme = [a for a in by_op.get("refresh", []) if a["name"] == "upme"]
if len(refresh_upme) != 1 or refresh_upme[0]["fromRevision"] != 10 or refresh_upme[0]["toRevision"] != 15:
    errors.append(f"upme should refresh 10 -> 15, got: {refresh_upme}")
if any(a["name"] == "upme" for a in by_op.get("revert", [])):
    errors.append("upme (revision increase) must never plan a 'revert'")

# -- revision decrease: revert only, no ack (retained locally) ----------
revert_downme = [a for a in by_op.get("revert", []) if a["name"] == "downme"]
if len(revert_downme) != 1 or revert_downme[0]["fromRevision"] != 20 or revert_downme[0]["toRevision"] != 12:
    errors.append(f"downme should revert 20 -> 12, got: {revert_downme}")
if any(a["name"] == "downme" for a in by_op.get("ack", [])):
    errors.append("downme (revert) must never plan an 'ack'")
if any(a["name"] == "downme" for a in by_op.get("refresh", [])):
    errors.append("downme (revert) must never plan a 'refresh'")

# -- connection add/remove: connectme gains 'camera', loses 'legacy' -----
connectme_connect = sorted(a["interface"] for a in by_op.get("connect", []) if a["name"] == "connectme")
connectme_disconnect = sorted(a["interface"] for a in by_op.get("disconnect", []) if a["name"] == "connectme")
if connectme_connect != ["camera"]:
    errors.append(f"connectme should 'connect' exactly ['camera'], got: {connectme_connect}")
if connectme_disconnect != ["legacy"]:
    errors.append(f"connectme should 'disconnect' exactly ['legacy'], got: {connectme_disconnect}")
# already-shared 'network' must not appear in either.
if "network" in connectme_connect or "network" in connectme_disconnect:
    errors.append("connectme's already-converged 'network' connection must not appear in the plan")

# -- config set/unset: configme changes key-a, adds key-b, drops key-c --
configme_set = sorted((a["key"], a["value"]) for a in by_op.get("set", []) if a["name"] == "configme")
configme_unset = sorted(a["key"] for a in by_op.get("unset", []) if a["name"] == "configme")
if configme_set != [("key-a", "new"), ("key-b", "added")]:
    errors.append(f"configme should 'set' key-a=new and key-b=added, got: {configme_set}")
if configme_unset != ["key-c"]:
    errors.append(f"configme should 'unset' exactly ['key-c'], got: {configme_unset}")

# -- removal scope: goneold (old+observed, dropped from new) -> remove;
# nevermanaged (observed only, never old or new) -> NEVER removed --------
remove_names = sorted(a["name"] for a in by_op.get("remove", []))
if remove_names != ["goneold"]:
    errors.append(f"expected exactly 'goneold' to be removed, got: {remove_names}")

# -- permanent auto-refresh hold: observed refreshHold is false -> exactly
# one 'hold' action, at the very end -------------------------------------
hold_actions = by_op.get("hold", [])
if len(hold_actions) != 1:
    errors.append(f"expected exactly one 'hold' action, got: {hold_actions}")
if actions[-1]["op"] != "hold":
    errors.append(f"'hold' must be the last action in the plan, got last: {actions[-1]}")

if errors:
    print("\n".join(errors))
    sys.exit(1)
print("OK")
PYEOF
)"
[ "$check" = "OK" ] || fail "plan diff scenarios failed:
$check"

# =====================================================================
# No-op reconverge: old == new == observed (single unchanged snap, with a
# refreshHold already true) -> an entirely EMPTY plan, exit 0.
# =====================================================================
conv="$work/converged-only.json"
cat > "$conv" <<EOF
{"version": 1, "snaps": [
$(declared_entry stable-snap stable 10 false '["network"]' '{"k": "v"}')
]}
EOF
conv_obs="$work/converged-observed.json"
cat > "$conv_obs" <<EOF
{"version": 1, "refreshHold": true, "snaps": [
$(observed_entry stable-snap stable 10 false '["network"]' '{"k": "v"}')
]}
EOF
noop_out="$work/noop-plan.json"
"$snap" plan --old-manifest "$conv" --new-manifest "$conv" --observed-manifest "$conv_obs" --out "$noop_out"
noop_rc=$?
[ "$noop_rc" -eq 0 ] || fail "a fully converged plan should exit 0, got rc=$noop_rc"

noop_check="$(python3 -c "
import json
d = json.load(open('$noop_out'))
assert d == {'version': 1, 'actions': []}, d
print('OK')
")"
[ "$noop_check" = "OK" ] || fail "fully converged (incl. refresh-hold already forever) plan should have zero actions: $noop_check"

exit "$fails"
