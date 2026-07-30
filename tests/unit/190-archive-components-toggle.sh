#!/usr/bin/env bash
# tests/unit/190-archive-components-toggle.sh — the restricted/multiverse
# per-machine component toggle (SPEC.md §5; GitHub issue #106): behavioral
# tests at the layer bin/ubx-resolve already exposes (declaration
# validation, sources.list generation, lockfile emission) — no live apt
# solve happens here (tests/README.md's "unit tests must not require root,
# network, or KVM" rule), mirroring tests/unit/054-ubx-resolve-suites.sh's
# and tests/unit/051-archive-resolve-emit.sh's own "pure half, testable in
# isolation" approach.
#
# Together, the two halves below stand in for the issue's own acceptance
# criterion ("with the toggle OFF, a restricted/multiverse package fails to
# resolve; with it ON, it resolves and pins"):
#   (a) sources.list generation: OFF -> the scratch sources.list bin/ubx-
#       resolve writes carries only main/universe, so apt's real solver
#       (exercised only in CI, not here) would never even see a
#       restricted/multiverse pool entry to resolve against; ON -> all
#       four components appear, so those pool entries become visible.
#   (b) lockfile emission: once resolution HAS produced a
#       restricted/multiverse-component tuple (as real resolution would,
#       toggle ON), bin/ubx-resolve's pure emission path pins it with the
#       full required schema (name/version/arch/component/path/sha256/
#       size) exactly like any main/universe entry.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

resolve="$UBX_REPO_ROOT/bin/ubx-resolve"
[ -x "$resolve" ] || {
  echo "FAIL: $resolve does not exist or is not executable" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

snapshot="20260715T000000Z"
keyring="/usr/share/keyrings/ubuntu-archive-keyring.gpg"

# -- (a) sources.list generation: toggle OFF vs ON --------------------------
#
# These fixtures mirror nix/archive.nix's effectiveComponents output for
# `{ }` (all-default, i.e. toggle off) and
# `{ restricted = true; multiverse = true; }` (toggle fully on) --
# tests/unit/189-archive-components-flake-wiring.sh keeps the Nix side's
# literal list shape in lockstep with this file's fixtures.
decl_off="$work/decl-off.json"
cat > "$decl_off" <<'EOF'
{
  "series": "noble",
  "components": ["main", "universe"],
  "packages": ["hello"]
}
EOF

decl_on="$work/decl-on.json"
cat > "$decl_on" <<'EOF'
{
  "series": "noble",
  "components": ["main", "universe", "restricted", "multiverse"],
  "packages": ["hello"]
}
EOF

# Both declarations must themselves validate (--check-declaration; no
# network, no apt).
for pair in "off:$decl_off" "on:$decl_on"; do
  label="${pair%%:*}"
  decl="${pair#*:}"
  out="$("$resolve" --check-declaration --declaration "$decl" 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] || fail "toggle-$label declaration should validate (rc=$rc): $out"
done

sources_off="$("$resolve" --print-sources-list --declaration "$decl_off" \
  --snapshot "$snapshot" --keyring "$keyring" 2>&1)"
rc_off=$?
[ "$rc_off" -eq 0 ] || fail "--print-sources-list (toggle off) should exit 0 (rc=$rc_off): $sources_off"

sources_on="$("$resolve" --print-sources-list --declaration "$decl_on" \
  --snapshot "$snapshot" --keyring "$keyring" 2>&1)"
rc_on=$?
[ "$rc_on" -eq 0 ] || fail "--print-sources-list (toggle on) should exit 0 (rc=$rc_on): $sources_on"

# With the toggle OFF: no line mentions restricted or multiverse at all --
# apt's solver (real resolution, CI-only) would have no way to see a
# restricted/multiverse pool entry, i.e. such a package "fails to resolve"
# by construction (the component isn't even in scope).
if printf '%s\n' "$sources_off" | grep -qw 'restricted'; then
  fail "toggle-off sources.list unexpectedly mentions 'restricted': $sources_off"
fi
if printf '%s\n' "$sources_off" | grep -qw 'multiverse'; then
  fail "toggle-off sources.list unexpectedly mentions 'multiverse': $sources_off"
fi
off_components="$(printf '%s\n' "$sources_off" | sed -n '1p' | cut -d' ' -f5-)"
[ "$off_components" = "main universe" ] || fail "toggle-off components should be 'main universe', got '$off_components'"

# With the toggle ON: every suite line carries all four components, in the
# fixed order effectiveComponents emits (main universe restricted
# multiverse) -- so a restricted/multiverse package's pool entries are now
# in scope for the real solver to find and pin.
on_line_count="$(printf '%s\n' "$sources_on" | grep -c '^deb ')"
[ "$on_line_count" -eq 3 ] || fail "toggle-on sources.list should have 3 'deb' lines, got $on_line_count"
on_components_1="$(printf '%s\n' "$sources_on" | sed -n '1p' | cut -d' ' -f5-)"
on_components_2="$(printf '%s\n' "$sources_on" | sed -n '2p' | cut -d' ' -f5-)"
on_components_3="$(printf '%s\n' "$sources_on" | sed -n '3p' | cut -d' ' -f5-)"
[ "$on_components_1" = "main universe restricted multiverse" ] ||
  fail "toggle-on line 1 components should be 'main universe restricted multiverse', got '$on_components_1'"
[ "$on_components_1" = "$on_components_2" ] || fail "toggle-on components differ between line 1 and line 2"
[ "$on_components_1" = "$on_components_3" ] || fail "toggle-on components differ between line 1 and line 3"

# -- (b) lockfile emission: a restricted/multiverse-component tuple pins
# its full schema, exactly like any other component, once resolution HAS
# produced it (the toggle's job is only to widen what apt is even ASKED to
# solve against -- see (a) above; emission itself is component-agnostic
# beyond the VALID_COMPONENTS membership check, and that's what this
# section pins).
resolved="$work/resolved-restricted-multiverse.json"
cat > "$resolved" <<'EOF'
[
  {
    "name": "some-restricted-driver", "version": "1.2.3-1", "arch": "amd64",
    "component": "restricted",
    "path": "pool/restricted/s/some-restricted-driver/some-restricted-driver_1.2.3-1_amd64.deb",
    "sha256": "c26e577a24cc784d678b0b2b960db8a154fb7138fc1aa7ad1ffe504698432a43",
    "size": 40960
  },
  {
    "name": "some-multiverse-codec", "version": "2.0.0-1build1", "arch": "amd64",
    "component": "multiverse",
    "path": "pool/multiverse/s/some-multiverse-codec/some-multiverse-codec_2.0.0-1build1_amd64.deb",
    "sha256": "ee0e9cffc789788164214bac9b6e285a5127c07be1815129875c6c538ba849c6",
    "size": 81920
  },
  {
    "name": "hello", "version": "2.10-3build2", "arch": "amd64",
    "component": "main",
    "path": "pool/main/h/hello/hello_2.10-3build2_amd64.deb",
    "sha256": "0b93d16d7498f092fa3070fbbad28cdbc6b3d640f1a7681b96fc37f20d1219f1",
    "size": 27680
  }
]
EOF

emitted="$work/emitted.json"
emit_out="$("$resolve" --emit-lockfile "$resolved" --snapshot "$snapshot" --series noble --out "$emitted" 2>&1)"
emit_rc=$?
[ "$emit_rc" -eq 0 ] || fail "emitting restricted/multiverse tuples should exit 0 (rc=$emit_rc): $emit_out"
[ -f "$emitted" ] || fail "--emit-lockfile did not write $emitted"

if [ -f "$emitted" ]; then
  validator="$UBX_REPO_ROOT/tests/lib/validate-archive-lockfile.py"
  if [ -f "$validator" ]; then
    schema_out="$(python3 "$validator" "$emitted" 2>&1)"
    schema_rc=$?
    [ "$schema_rc" -eq 0 ] || fail "emitted restricted/multiverse lockfile failed schema validation: $schema_out"
  else
    fail "$validator does not exist"
  fi

  fields_check="$(python3 - "$emitted" <<'PYEOF'
import json
import sys

data = json.load(open(sys.argv[1]))
want = {"name", "version", "arch", "component", "path", "sha256", "size"}
by_name = {p["name"]: p for p in data["public"]["packages"]}

for name, expect_component in (
    ("some-restricted-driver", "restricted"),
    ("some-multiverse-codec", "multiverse"),
):
    if name not in by_name:
        print(f"FAIL: {name!r} missing from emitted packages: {sorted(by_name)}")
        sys.exit(1)
    pkg = by_name[name]
    if set(pkg.keys()) != want:
        print(f"FAIL: {name!r} field set is {sorted(pkg.keys())}, want {sorted(want)}")
        sys.exit(1)
    if pkg["component"] != expect_component:
        print(f"FAIL: {name!r} component is {pkg['component']!r}, want {expect_component!r}")
        sys.exit(1)
sys.exit(0)
PYEOF
)"
  fields_rc=$?
  [ "$fields_rc" -eq 0 ] || fail "restricted/multiverse field check failed: $fields_check"
fi

exit "$fails"
