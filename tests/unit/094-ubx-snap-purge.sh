#!/usr/bin/env bash
# tests/unit/094-ubx-snap-purge.sh — bin/ubx-snap-purge: the reconcile-time
# undeclared-snap purge sweep (SPEC.md §7; GitHub issue #63, milestone M3).
# Same stub-and-record technique as tests/unit/093-guard-snap.sh, but the
# stub here fronts BOTH `snap list` (observed-set fixture) and `snap remove
# --purge` (the purge action itself) -- see bin/ubx-snap-purge's header,
# "Purge seam".
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

tool="$UBX_REPO_ROOT/bin/ubx-snap-purge"
[ -x "$tool" ] || {
  echo "FAIL: $tool does not exist or is not executable" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# -- stub snap binary ---------------------------------------------------------
#
# `list` prints a fixed, fixture-controlled table (STUB_LIST_OUTPUT, a file
# path) mimicking real `snap list` output (header + name-first columns).
# `remove --purge NAME` records the purged name to STUB_PURGE_RECORD (one
# per invocation, appended) and exits 0, unless STUB_PURGE_FAIL names the
# snap that invocation should fail for.
stub="$work/stub-snap"
cat > "$stub" <<'STUBEOF'
#!/usr/bin/env bash
set -u
if [ "$1" = "list" ]; then
  cat "$STUB_LIST_OUTPUT"
  exit 0
fi
if [ "$1" = "remove" ] && [ "$2" = "--purge" ]; then
  name="$3"
  echo "$name" >> "$STUB_PURGE_RECORD"
  if [ "$name" = "${STUB_PURGE_FAIL:-}" ]; then
    exit 1
  fi
  exit 0
fi
echo "stub-snap: unexpected invocation: $*" >&2
exit 99
STUBEOF
chmod +x "$stub"

list_output="$work/list-output.txt"
purge_record="$work/purge-record.txt"
manifest="$work/manifest.json"

# A realistic `snap list` table: header line + name-first columns.
cat > "$list_output" <<'EOF'
Name      Version   Rev   Tracking       Publisher     Notes
core22    20230101  123   latest/stable  canonical**   base
snapd     2.60      456   latest/stable  canonical**   snapd
firefox   118.0     789   latest/stable  mozilla**     -
htop-snap 3.0       12    latest/stable  someuser      -
EOF

run() {
  rm -f "$purge_record"
  local errfile
  errfile="$(mktemp)"
  out="$(UBX_SNAP_BIN="$stub" STUB_LIST_OUTPUT="$list_output" STUB_PURGE_RECORD="$purge_record" \
    "$tool" --manifest "$manifest" "$@" 2>"$errfile")"
  rc=$?
  err="$(cat "$errfile")"
  rm -f "$errfile"
  purged="$(cat "$purge_record" 2>/dev/null || true)"
}

# -- undeclared purge, declared spared, base-snap spared (dry-run) ----------
#
# Manifest shape is issue #60's: a JSON object keyed by snap name, each
# entry carrying channel/revision, classic, connections, config -- this
# script reads only the top-level keys (see bin/ubx-snap-purge's header).

cat > "$manifest" <<'EOF'
{"firefox": {"channel": "stable/latest", "revision": "789", "classic": false, "connections": [], "config": {}}}
EOF

run --dry-run
[ "$rc" -eq 0 ] || fail "dry-run: expected exit 0, got $rc (err: $err)"
case "$out" in
  *"purge htop-snap"*) ;;
  *) fail "dry-run: expected 'purge htop-snap' in plan output, got: $out" ;;
esac
case "$out" in
  *"purge firefox"*) fail "dry-run: declared snap 'firefox' must not appear in the purge plan, got: $out" ;;
esac
case "$out" in
  *"purge core22"* | *"purge snapd"*) fail "dry-run: protected base snaps must not appear in the purge plan, got: $out" ;;
esac
[ -z "$purged" ] || fail "dry-run: must not actually invoke 'remove --purge' (recorded: $purged)"
case "$err" in
  *"keep (declared): firefox"*) ;;
  *) fail "dry-run: expected a 'keep (declared): firefox' informational line on stderr, got: $err" ;;
esac
case "$err" in
  *"keep (protected base): snapd"*) ;;
  *) fail "dry-run: expected a 'keep (protected base): snapd' informational line on stderr, got: $err" ;;
esac

# -- --apply actually purges exactly the undeclared, non-base snap ----------

run --apply
[ "$rc" -eq 0 ] || fail "apply: expected exit 0, got $rc (err: $err)"
[ "$purged" = "htop-snap" ] || fail "apply: expected exactly 'htop-snap' to be purged, got: $purged"
case "$out" in
  *"purge htop-snap"*) ;;
  *) fail "apply: expected 'purge htop-snap' printed, got: $out" ;;
esac

# -- manifest with both non-base snaps declared, full per-entry fields ------

cat > "$manifest" <<'EOF'
{
  "firefox": {"channel": "stable", "revision": "789", "classic": false, "connections": [], "config": {}},
  "htop-snap": {"channel": "stable", "revision": "12", "classic": false, "connections": [], "config": {}}
}
EOF
run --dry-run
[ "$rc" -eq 0 ] || fail "fully-declared manifest: expected exit 0, got $rc (err: $err)"
case "$out" in
  *"purge"*) fail "fully-declared manifest: nothing should be undeclared once both non-base snaps are declared, got: $out" ;;
esac

# -- empty declared manifest: only the protected base snaps survive ---------

cat > "$manifest" <<'EOF'
{}
EOF
run --dry-run
[ "$rc" -eq 0 ] || fail "empty manifest: expected exit 0, got $rc (err: $err)"
for want in firefox htop-snap; do
  case "$out" in
    *"purge $want"*) ;;
    *) fail "empty manifest: expected 'purge $want' in plan output, got: $out" ;;
  esac
done
case "$out" in
  *"purge core22"* | *"purge snapd"*) fail "empty manifest: protected base snaps must still be spared, got: $out" ;;
esac

# -- malformed manifest fails closed, never silently treated as "declare
# nothing" (which would be the most destructive possible misreading) -------

cat > "$manifest" <<'EOF'
["firefox", "htop-snap"]
EOF
run --dry-run
[ "$rc" -ne 0 ] || fail "malformed manifest (bare array, not an object keyed by name): expected nonzero exit, got 0"
[ -z "$purged" ] || fail "malformed manifest: must not purge anything, got: $purged"

cat > "$manifest" <<'EOF'
"just a string"
EOF
run --dry-run
[ "$rc" -ne 0 ] || fail "malformed manifest (bare scalar): expected nonzero exit, got 0"

cat > "$manifest" <<'EOF'
{"": {"channel": "stable"}}
EOF
run --dry-run
[ "$rc" -ne 0 ] || fail "malformed manifest (empty-string snap name key): expected nonzero exit, got 0"

# -- missing --manifest / missing file ---------------------------------------

out="$(UBX_SNAP_BIN="$stub" STUB_LIST_OUTPUT="$list_output" STUB_PURGE_RECORD="$purge_record" \
  "$tool" --dry-run 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "no --manifest and no UBX_SNAP_DECLARED_MANIFEST: expected nonzero exit, got 0"

out="$(UBX_SNAP_BIN="$stub" STUB_LIST_OUTPUT="$list_output" STUB_PURGE_RECORD="$purge_record" \
  "$tool" --manifest "$work/does-not-exist.json" --dry-run 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "nonexistent --manifest file: expected nonzero exit, got 0"

# -- UBX_SNAP_DECLARED_MANIFEST env var fallback -----------------------------

cat > "$manifest" <<'EOF'
{"firefox": {"channel": "stable"}, "htop-snap": {"channel": "stable"}}
EOF
out="$(UBX_SNAP_BIN="$stub" STUB_LIST_OUTPUT="$list_output" STUB_PURGE_RECORD="$purge_record" \
  UBX_SNAP_DECLARED_MANIFEST="$manifest" "$tool" --dry-run 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] || fail "UBX_SNAP_DECLARED_MANIFEST fallback: expected exit 0, got $rc"
[ -z "$out" ] || fail "UBX_SNAP_DECLARED_MANIFEST fallback: nothing should be undeclared, got: $out"

# -- a purge failure (real 'remove --purge' exiting nonzero) is surfaced,
# not silently swallowed -----------------------------------------------------

cat > "$manifest" <<'EOF'
{"firefox": {"channel": "stable"}}
EOF
rm -f "$purge_record"
out="$(UBX_SNAP_BIN="$stub" STUB_LIST_OUTPUT="$list_output" STUB_PURGE_RECORD="$purge_record" \
  STUB_PURGE_FAIL="htop-snap" "$tool" --manifest "$manifest" --apply 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "purge failure: expected nonzero exit when 'remove --purge' fails, got 0"
case "$out" in
  *"failed to purge 'htop-snap'"*) ;;
  *) fail "purge failure: expected a failure diagnostic naming htop-snap, got: $out" ;;
esac

# -- interactive-block regression: bin/ubx-guard-snap is untouched by this
# issue -- confirm it is still present, executable, and still blocks
# 'install' exactly as issue #31 left it. (Full behavior is already
# regression-tested by tests/unit/093-guard-snap.sh; this is a narrow smoke
# check that this issue did not alter it.) --------------------------------

guard="$UBX_REPO_ROOT/bin/ubx-guard-snap"
[ -x "$guard" ] || fail "bin/ubx-guard-snap is missing or not executable -- regression"
guard_stub="$work/real-snap-for-guard"
cat > "$guard_stub" <<'STUBEOF'
#!/usr/bin/env bash
exit 0
STUBEOF
chmod +x "$guard_stub"
guard_err="$(UBX_GUARD_REAL_BIN="$guard_stub" "$guard" install somesnap 2>&1 1>/dev/null)"
guard_rc=$?
[ "$guard_rc" -eq 1 ] || fail "regression: 'snap install' via bin/ubx-guard-snap should still block (exit 1), got $guard_rc"
case "$guard_err" in
  *"blocked on this system"*) ;;
  *) fail "regression: bin/ubx-guard-snap's block message changed unexpectedly, got: $guard_err" ;;
esac

exit "$fails"
