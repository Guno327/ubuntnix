#!/usr/bin/env bash
# tests/unit/114-etc-plan-exceptions-determinism.sh — `ubx-etc plan`'s
# machine-local mutable exception refusal (SPEC.md §4.2/§4.3; GitHub
# issue #26 scope item 3: "the planner must never plan create/update/
# remove on exception paths even if declared") plus output determinism
# (byte-identical across repeated runs against unchanged inputs) and CLI
# error handling.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

etc="$UBX_REPO_ROOT/bin/ubx-etc"
[ -x "$etc" ] || { echo "FAIL: $etc does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

exceptions="$work/exceptions.json"
cat > "$exceptions" <<'EOF'
{"version": 1, "exceptions": [
  {"path": "machine-id", "owner": "root", "group": "root", "mode": "0444", "sensitive": false, "reason": "test fixture"},
  {"path": "ssh/ssh_host_rsa_key", "owner": "root", "group": "root", "mode": "0600", "sensitive": true, "reason": "test fixture"}
]}
EOF

empty_observed="$work/empty-observed.json"
echo '{"version": 1, "entries": []}' > "$empty_observed"

# =====================================================================
# refusal: an exception path declared in --new-manifest
# =====================================================================
new_bad="$work/new-bad.json"
cat > "$new_bad" <<'EOF'
{"version": 1, "entries": [
  {"path": "machine-id", "sha256": "0000000000000000000000000000000000000000000000000000000000000000", "owner": "root", "group": "root", "mode": "0444"}
]}
EOF
empty_old="$work/empty-old.json"
echo '{"version": 1, "entries": []}' > "$empty_old"

err_out="$work/refuse-new.out"
"$etc" plan --old-manifest "$empty_old" --new-manifest "$new_bad" \
  --observed-manifest "$empty_observed" --exceptions "$exceptions" --out "$err_out" > "$work/stderr1.txt" 2>&1
rc=$?
[ "$rc" -ne 0 ] || fail "plan should refuse when --new-manifest declares an exception path"
[ ! -s "$err_out" ] || fail "plan must print NO plan output when refusing (fail-closed), got: $(cat "$err_out" 2>/dev/null)"
grep -q 'machine-id' "$work/stderr1.txt" || fail "refusal error should name the offending path 'machine-id', got: $(cat "$work/stderr1.txt")"

# =====================================================================
# refusal: an exception path declared in --old-manifest (not --new)
# =====================================================================
old_bad="$work/old-bad.json"
cat > "$old_bad" <<'EOF'
{"version": 1, "entries": [
  {"path": "ssh/ssh_host_rsa_key", "sha256": "0000000000000000000000000000000000000000000000000000000000000000", "owner": "root", "group": "root", "mode": "0600"}
]}
EOF
err_out2="$work/refuse-old.out"
"$etc" plan --old-manifest "$old_bad" --new-manifest "$empty_old" \
  --observed-manifest "$empty_observed" --exceptions "$exceptions" --out "$err_out2" > "$work/stderr2.txt" 2>&1
rc2=$?
[ "$rc2" -ne 0 ] || fail "plan should refuse when --old-manifest (alone) declares an exception path"
[ ! -s "$err_out2" ] || fail "plan must print no plan output when refusing via --old-manifest, got: $(cat "$err_out2" 2>/dev/null)"
grep -q 'ssh/ssh_host_rsa_key' "$work/stderr2.txt" || fail "refusal error should name 'ssh/ssh_host_rsa_key', got: $(cat "$work/stderr2.txt")"

# =====================================================================
# an exception path present ONLY in --observed-manifest (never declared)
# is simply never considered -- expected, not create/update/remove/drift
# =====================================================================
observed_with_exception="$work/observed-exc.json"
cat > "$observed_with_exception" <<'EOF'
{"version": 1, "entries": [
  {"path": "machine-id", "sha256": "1111111111111111111111111111111111111111111111111111111111111111", "owner": "root", "group": "root", "mode": "0444"},
  {"path": "unmanaged-other", "sha256": "2222222222222222222222222222222222222222222222222222222222222222", "owner": "root", "group": "root", "mode": "0644"}
]}
EOF
ok_out="$work/exc-plan.tsv"
"$etc" plan --old-manifest "$empty_old" --new-manifest "$empty_old" \
  --observed-manifest "$observed_with_exception" --exceptions "$exceptions" --out "$ok_out"
ok_rc=$?
[ "$ok_rc" -eq 0 ] || fail "plan should succeed when the exception path only appears in --observed-manifest"
got="$(cat "$ok_out" 2>/dev/null || true)"
case "$got" in
  *machine-id*) fail "an exception path present only in --observed-manifest must never appear in the plan (create/update/remove/drift), got: $got" ;;
esac
# the OTHER unmanaged path (not an exception) must still be reported as
# drift -- exceptions are the only carve-out.
case "$got" in
  *$'\tunmanaged-other\t'*) ;;
  *) fail "a genuinely unmanaged, non-exception observed path should still be reported as drift, got: $got" ;;
esac

# =====================================================================
# determinism: repeated `plan` runs against UNCHANGED inputs are
# byte-identical (mirrors tests/unit/051's idempotence check for
# bin/ubx-resolve --emit-lockfile)
# =====================================================================
sha_x="$(printf 'content-x' | sha256sum | cut -d' ' -f1)"
sha_y="$(printf 'content-y' | sha256sum | cut -d' ' -f1)"
det_old="$work/det-old.json"
det_new="$work/det-new.json"
det_observed="$work/det-observed.json"
cat > "$det_old" <<EOF
{"version": 1, "entries": [
  {"path": "x", "sha256": "$sha_x", "owner": "root", "group": "root", "mode": "0644"}
]}
EOF
cat > "$det_new" <<EOF
{"version": 1, "entries": [
  {"path": "y", "sha256": "$sha_y", "owner": "root", "group": "root", "mode": "0644"}
]}
EOF
cat > "$det_observed" <<EOF
{"version": 1, "entries": [
  {"path": "x", "sha256": "$sha_x", "owner": "root", "group": "root", "mode": "0644"}
]}
EOF

det_out1="$work/det1.tsv"
det_out2="$work/det2.tsv"
"$etc" plan --old-manifest "$det_old" --new-manifest "$det_new" --observed-manifest "$det_observed" \
  --exceptions "$exceptions" --out "$det_out1"
"$etc" plan --old-manifest "$det_old" --new-manifest "$det_new" --observed-manifest "$det_observed" \
  --exceptions "$exceptions" --out "$det_out2"
if [ -f "$det_out1" ] && [ -f "$det_out2" ]; then
  diff -u "$det_out1" "$det_out2" > "$work/det-diff.txt" || fail "two plan runs against unchanged inputs are not byte-identical:
$(cat "$work/det-diff.txt")"
fi

# stdout determinism too (the --out '-' default path).
stdout1="$("$etc" plan --old-manifest "$det_old" --new-manifest "$det_new" --observed-manifest "$det_observed" --exceptions "$exceptions")"
stdout2="$("$etc" plan --old-manifest "$det_old" --new-manifest "$det_new" --observed-manifest "$det_observed" --exceptions "$exceptions")"
[ "$stdout1" = "$stdout2" ] || fail "two plan runs to stdout against unchanged inputs are not identical"

# =====================================================================
# CLI error handling
# =====================================================================
missing_arg_rc=0
"$etc" plan --new-manifest "$det_new" --observed-manifest "$det_observed" --exceptions "$exceptions" \
  > /dev/null 2>&1 || missing_arg_rc=$?
[ "$missing_arg_rc" -ne 0 ] || fail "plan without --old-manifest should fail"

nonexistent_rc=0
"$etc" plan --old-manifest "$work/does-not-exist.json" --new-manifest "$det_new" \
  --observed-manifest "$det_observed" --exceptions "$exceptions" > /dev/null 2>&1 || nonexistent_rc=$?
[ "$nonexistent_rc" -ne 0 ] || fail "plan with a nonexistent --old-manifest should fail"

bad_version="$work/bad-version.json"
echo '{"version": 2, "entries": []}' > "$bad_version"
bad_version_rc=0
bad_version_out="$("$etc" plan --old-manifest "$bad_version" --new-manifest "$det_new" \
  --observed-manifest "$det_observed" --exceptions "$exceptions" 2>&1)" || bad_version_rc=$?
[ "$bad_version_rc" -ne 0 ] || fail "plan with a manifest 'version' != 1 should fail"
case "$bad_version_out" in
  *"version"*) ;;
  *) fail "bad-version error should mention 'version', got: $bad_version_out" ;;
esac

missing_field="$work/missing-field.json"
echo '{"version": 1, "entries": [{"path": "x", "sha256": "abc"}]}' > "$missing_field"
missing_field_rc=0
"$etc" plan --old-manifest "$missing_field" --new-manifest "$det_new" \
  --observed-manifest "$det_observed" --exceptions "$exceptions" > /dev/null 2>&1 || missing_field_rc=$?
[ "$missing_field_rc" -ne 0 ] || fail "plan with an entry missing owner/group/mode should fail"

# -- every --help text must be clean, static prose: an unquoted heredoc
# delimiter (`cat <<USAGE` instead of `cat <<'USAGE'`) would let the shell
# command-substitute any backtick-quoted word in the help text (e.g. this
# script's own header prose mentions `plan`), silently corrupting --help
# output and printing "command not found" to stderr. Exercised for every
# subcommand plus the top-level usage.
for args in "--help" "exceptions --help" "observe --help" "plan --help"; do
  # shellcheck disable=SC2086  # intentional word-splitting of $args
  help_err="$("$etc" $args 2>&1 >/dev/null)"
  [ -z "$help_err" ] || fail "'ubx-etc $args' wrote to stderr (heredoc/backtick corruption?): $help_err"
done

exit "$fails"
