#!/usr/bin/env bash
# tests/unit/113-etc-plan.sh — `ubx-etc plan`'s diff/activation algorithm:
# create/update-content/update-metadata/remove/no-op/drift, against
# fixture old/new/observed manifests (SPEC.md §4.2 "generated /etc", §4.3
# "diff-driven activation"; GitHub issue #26, milestone M2, scope item 2
# "removal only applies to previously-managed entries").
#
# Every fixture manifest here is hand-crafted directly in bin/ubx-etc's
# own manifest schema (see that script's header) -- no `nix` binary or
# real filesystem access is needed to exercise `plan` itself, per that
# same header's "Inputs: three manifests, one schema".
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

# An exceptions file with no exceptions in it -- these fixtures don't
# exercise the exception-refusal path (that's tests/unit/114's job).
no_exceptions="$work/no-exceptions.json"
cat > "$no_exceptions" <<'EOF'
{"version": 1, "exceptions": []}
EOF

sha_a="$(printf 'content-a' | sha256sum | cut -d' ' -f1)"
sha_b1="$(printf 'content-b1' | sha256sum | cut -d' ' -f1)"
sha_b2="$(printf 'content-b2' | sha256sum | cut -d' ' -f1)"
sha_c="$(printf 'content-c' | sha256sum | cut -d' ' -f1)"
sha_d="$(printf 'content-d' | sha256sum | cut -d' ' -f1)"
sha_e="$(printf 'content-e' | sha256sum | cut -d' ' -f1)"
sha_f="$(printf 'content-f' | sha256sum | cut -d' ' -f1)"

# old: a (converged), b@sha_b1, c (dropped from new, present in observed
# -> remove), e (metadata target, dropped is irrelevant here)
old="$work/old.json"
cat > "$old" <<EOF
{"version": 1, "entries": [
  {"path": "a", "sha256": "$sha_a", "owner": "root", "group": "root", "mode": "0644"},
  {"path": "b", "sha256": "$sha_b1", "owner": "root", "group": "root", "mode": "0644"},
  {"path": "c", "sha256": "$sha_c", "owner": "root", "group": "root", "mode": "0644"},
  {"path": "g", "sha256": "$sha_a", "owner": "root", "group": "root", "mode": "0644"}
]}
EOF

# new: a (unchanged -> no-op), b@sha_b2 (content changed -> update-content),
# d (absent from observed -> create), e (sha matches observed but
# owner/mode differ -> update-metadata). c and g dropped.
new="$work/new.json"
cat > "$new" <<EOF
{"version": 1, "entries": [
  {"path": "a", "sha256": "$sha_a", "owner": "root", "group": "root", "mode": "0644"},
  {"path": "b", "sha256": "$sha_b2", "owner": "root", "group": "root", "mode": "0644"},
  {"path": "d", "sha256": "$sha_d", "owner": "root", "group": "root", "mode": "0644"},
  {"path": "e", "sha256": "$sha_e", "owner": "www-data", "group": "www-data", "mode": "0640"}
]}
EOF

# observed: a converged; b at the OLD content (drives update-content); c
# present (drives remove, since c is in old, absent from new); e present
# at the target sha256 but stale owner/group/mode (drives
# update-metadata); f present but never declared by old OR new, and not
# an exception (drives drift). g is ABSENT (dropped from new, but nothing
# to remove since it was never actually written -> no line at all). d is
# absent (drives create).
observed="$work/observed.json"
cat > "$observed" <<EOF
{"version": 1, "entries": [
  {"path": "a", "sha256": "$sha_a", "owner": "root", "group": "root", "mode": "0644"},
  {"path": "b", "sha256": "$sha_b1", "owner": "root", "group": "root", "mode": "0644"},
  {"path": "c", "sha256": "$sha_c", "owner": "root", "group": "root", "mode": "0644"},
  {"path": "e", "sha256": "$sha_e", "owner": "root", "group": "root", "mode": "0644"},
  {"path": "f", "sha256": "$sha_f", "owner": "root", "group": "root", "mode": "0644"}
]}
EOF

out="$work/plan.tsv"
"$etc" plan --old-manifest "$old" --new-manifest "$new" --observed-manifest "$observed" \
  --exceptions "$no_exceptions" --out "$out"
rc=$?
[ "$rc" -eq 0 ] || fail "plan should exit 0 for a well-formed (non-exception) diff, got rc=$rc"

want=$'update-content\tb\troot\troot\t0644\t'"$sha_b2"$'\n'
want+=$'remove\tc\t-\t-\t-\t-\n'
want+=$'create\td\troot\troot\t0644\t'"$sha_d"$'\n'
want+=$'update-metadata\te\twww-data\twww-data\t0640\t'"$sha_e"$'\n'
want+=$'drift\tf\troot\troot\t0644\t'"$sha_f"

got="$(cat "$out")"
[ "$got" = "$want" ] || fail "plan output mismatch:
--- want ---
$want
--- got ---
$got"

# -- 'a' (fully converged) and 'g' (dropped from new, absent from
# observed) must NOT appear anywhere in the output -----------------------
case "$got" in
  *$'\ta\t'*) fail "converged path 'a' should not appear in the plan at all" ;;
esac
case "$got" in
  *$'\tg\t'*) fail "'g' (dropped, never actually written) should not appear in the plan at all" ;;
esac

# -- removal scope (issue #26 scope item 2): a path that was NEVER in
# --old-manifest can never be planned for removal, no matter what
# --observed-manifest says. 'f' is exactly that case above (drift, not
# remove) -- assert it explicitly by action, not just by presence.
remove_lines="$(printf '%s\n' "$got" | awk -F'\t' '$1=="remove"{print $2}')"
[ "$remove_lines" = "c" ] || fail "only 'c' (present in --old-manifest AND observed) should be 'remove', got: $remove_lines"

# -- output ordering: sorted by PATH regardless of action ------------------
paths="$(printf '%s\n' "$got" | cut -f2)"
sorted_check="$(printf '%s\n' "$paths" | sort -c 2>&1)"
[ -z "$sorted_check" ] || fail "plan output is not sorted by path: $sorted_check"

# -- a fully converged input set (old == new == observed) produces an
# EMPTY plan and exit 0 -- a no-op plan is success, not an error ----------
conv_out="$work/converged.json"
conv="$work/converged-plan.tsv"
cat > "$conv_out" <<EOF
{"version": 1, "entries": [
  {"path": "a", "sha256": "$sha_a", "owner": "root", "group": "root", "mode": "0644"}
]}
EOF
"$etc" plan --old-manifest "$conv_out" --new-manifest "$conv_out" --observed-manifest "$conv_out" \
  --exceptions "$no_exceptions" --out "$conv"
conv_rc=$?
[ "$conv_rc" -eq 0 ] || fail "a fully converged plan should exit 0, got rc=$conv_rc"
[ ! -s "$conv" ] || fail "a fully converged plan should produce an empty file, got: $(cat "$conv")"

exit "$fails"
