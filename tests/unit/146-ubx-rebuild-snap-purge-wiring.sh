#!/usr/bin/env bash
# tests/unit/146-ubx-rebuild-snap-purge-wiring.sh — `ubx rebuild
# switch|boot|test` wiring bin/ubx-snap-purge into its convergence
# sequence (SPEC.md §7; GitHub issue #66, milestone M3).
#
# Mirrors tests/unit/137-ubx-systemd-apply-real-invocation.sh's own
# "end-to-end through a real `ubx rebuild ...` invocation, stub instead of
# the real underlying binary" style, adapted to bin/ubx-snap-purge's own
# UBX_SNAP_BIN seam (see tests/unit/094-ubx-snap-purge.sh, from which the
# stub `snap` below is copied).
#
# What this test asserts (none of it needs root, network, or a real
# snapd):
#   1. `rebuild switch` (no --apply) invokes ubx-snap-purge in --dry-run
#      mode: the plan is printed, but the stub's `remove --purge` is never
#      actually invoked.
#   2. `rebuild switch --apply` invokes ubx-snap-purge with --apply: the
#      undeclared snap is really (via the stub) purged.
#   3. `rebuild test --apply` NEVER passes --apply through to
#      ubx-snap-purge -- issue #66's explicit safety carve-out for this
#      destructive sweep (see bin/ubx's execute_domains header) -- even
#      though --apply was given and etc/systemd/users do apply for real
#      under `test`.
#   4. `rebuild boot` never invokes ubx-snap-purge at all (boot never
#      calls execute_domains -- no live activation of any domain).
#   5. Omitting --snap-manifest entirely skips the domain (no invocation),
#      matching every other domain's "nothing declared" convention.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

ubx="$UBX_REPO_ROOT/bin/ubx"
purge="$UBX_REPO_ROOT/bin/ubx-snap-purge"
[ -x "$ubx" ] || { echo "FAIL: $ubx does not exist or is not executable" >&2; exit 1; }
[ -x "$purge" ] || { echo "FAIL: $purge does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# -- stub `snap` (list + remove --purge), same shape as tests/unit/094's --
stub="$work/stub-snap"
cat > "$stub" <<'STUBEOF'
#!/usr/bin/env bash
set -u
if [ "$1" = "list" ]; then
  cat "$STUB_LIST_OUTPUT"
  exit 0
fi
if [ "$1" = "remove" ] && [ "$2" = "--purge" ]; then
  echo "$3" >> "$STUB_PURGE_RECORD"
  exit 0
fi
echo "stub-snap: unexpected invocation: $*" >&2
exit 99
STUBEOF
chmod +x "$stub"

list_output="$work/list-output.txt"
cat > "$list_output" <<'EOF'
Name      Version   Rev   Tracking       Publisher     Notes
core22    20230101  123   latest/stable  canonical**   base
snapd     2.60      456   latest/stable  canonical**   snapd
firefox   118.0     789   latest/stable  mozilla**     -
htop-snap 3.0       12    latest/stable  someuser      -
EOF

# -- the real #60 manifest shape: {"version":1, "snaps":[{"name":...}]} --
snap_manifest="$work/snap-manifest.json"
cat > "$snap_manifest" <<'EOF'
{"version": 1, "snaps": [
  {"name": "firefox", "channel": "stable", "revision": 789, "classic": false, "connections": [], "config": {}}
]}
EOF

export UBX_SNAP_BIN="$stub"
export STUB_LIST_OUTPUT="$list_output"
# Every scenario below is a first-ever generation with a real rootfs image
# path, which classifies as an "image" delta (see bin/ubx-rebuild-lib's
# "Soft-reboot delta classification") -- stub out both the nextroot
# staging and the soft-reboot call themselves (issues #30/#55) so this
# test needs no real mount/systemctl privilege, exactly like
# tests/unit/137-ubx-systemd-apply-real-invocation.sh's own guards.
export UBX_SOFT_REBOOT_CMD=true
export UBX_NEXTROOT_STAGE_CMD=true

common_flags=(--rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --snap-manifest "$snap_manifest")

run_rebuild() {
  # run_rebuild ROOT VERB [extra args...] -- fresh --root per call so
  # generation numbering never collides across the scenarios below.
  local root="$1" verb="$2"
  shift 2
  "$ubx" rebuild "$verb" --root "$root" "${common_flags[@]}" "$@"
}

# =====================================================================
# 1) `rebuild switch` (no --apply): dry-run mode, no real purge.
# =====================================================================
root1="$work/gens1"
purge_record="$work/purge1.txt"
export STUB_PURGE_RECORD="$purge_record"
out="$(run_rebuild "$root1" switch 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild switch' (no --apply) should exit 0, got $rc: $out"
contains "$out" "purge htop-snap" || fail "'rebuild switch' should print ubx-snap-purge's dry-run plan ('purge htop-snap'), got: $out"
[ ! -s "$purge_record" ] || fail "'rebuild switch' without --apply must NOT actually purge anything, recorded: $(cat "$purge_record")"

# =====================================================================
# 2) `rebuild switch --apply`: real purge via the stub.
# =====================================================================
root2="$work/gens2"
purge_record="$work/purge2.txt"
export STUB_PURGE_RECORD="$purge_record"
out="$(run_rebuild "$root2" switch --apply 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild switch --apply' should exit 0, got $rc: $out"
if [ ! -f "$purge_record" ] || [ "$(cat "$purge_record")" != "htop-snap" ]; then
  fail "'rebuild switch --apply' should have really purged exactly 'htop-snap', recorded: $(cat "$purge_record" 2>/dev/null)"
fi

# =====================================================================
# 3) `rebuild test --apply`: NEVER passes --apply through to
#    ubx-snap-purge, even though --apply was given (issue #66's explicit
#    safety carve-out for this destructive sweep).
# =====================================================================
root3="$work/gens3"
purge_record="$work/purge3.txt"
export STUB_PURGE_RECORD="$purge_record"
out="$(run_rebuild "$root3" test --apply 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild test --apply' should exit 0, got $rc: $out"
contains "$out" "purge htop-snap" || fail "'rebuild test --apply' should still print the snap-purge dry-run plan, got: $out"
[ ! -s "$purge_record" ] || fail "'rebuild test --apply' must NEVER really purge (snap-purge always dry-run under 'test'), recorded: $(cat "$purge_record")"

# =====================================================================
# 4) `rebuild boot`: never invokes ubx-snap-purge at all (boot never
#    activates live domains).
# =====================================================================
root4="$work/gens4"
purge_record="$work/purge4.txt"
export STUB_PURGE_RECORD="$purge_record"
out="$(run_rebuild "$root4" boot --apply 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild boot --apply' should exit 0, got $rc: $out"
contains "$out" "purge" && fail "'rebuild boot' must never invoke ubx-snap-purge at all, got: $out"
[ ! -s "$purge_record" ] || fail "'rebuild boot' must not purge anything, recorded: $(cat "$purge_record")"

# =====================================================================
# 5) Omitting --snap-manifest entirely: the domain is skipped, exactly
#    like an omitted --etc-ref/--systemd-ref/--users-manifest.
# =====================================================================
root5="$work/gens5"
purge_record="$work/purge5.txt"
export STUB_PURGE_RECORD="$purge_record"
out="$("$ubx" rebuild switch --root "$root5" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --apply 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild switch --apply' with no --snap-manifest should exit 0, got $rc: $out"
contains "$out" "purge" && fail "'rebuild switch' with no --snap-manifest declared must never invoke ubx-snap-purge, got: $out"
[ ! -s "$purge_record" ] || fail "'rebuild switch' with no --snap-manifest declared must not purge anything, recorded: $(cat "$purge_record")"

exit "$fails"
