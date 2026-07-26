#!/usr/bin/env bash
# tests/unit/160-secrets-purity-guard.sh — SPEC.md §8.1's "ABSOLUTE
# INVARIANT: no secret material ever enters a store object", enforced at
# TWO independent points (GitHub issue #78, milestone M4):
#
#   1. nix/secrets.nix's rendered manifest structurally never carries a
#      `"src"` JSON key (or anything else outside the closed
#      name/owner/group/mode/dst/environmentVariable field list) -- checked
#      here as a static grep, since this harness has no `nix` binary (see
#      tests/unit/021-flake-purity.sh's own header for the same caveat).
#   2. bin/ubx-secrets' `validate_manifest` REJECTS a hand-crafted manifest
#      fixture that carries any extra key at all (a tampered/hand-crafted
#      manifest.json is refused before planning proceeds, independent of
#      whatever nix/secrets.nix itself would ever produce).
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

secrets_nix="nix/secrets.nix"
[ -f "$secrets_nix" ] || {
  echo "FAIL: $secrets_nix does not exist" >&2
  exit 1
}

# -- (1) nix/secrets.nix's own CODE (comments stripped) never spells the
# JSON key "src" -- comments are allowed to discuss the invariant in prose
# (as this file's own header does), only actual code matters here.
code_only="$(grep -v '^[[:space:]]*#' "$secrets_nix")"
if printf '%s' "$code_only" | grep -q '"src"'; then
  fail "$secrets_nix's CODE contains the literal JSON key \"src\" -- the rendered manifest must never carry secret-material-forcing paths"
fi

# The manifest-construction site must build each entry via an explicit,
# closed field list (name/owner/group/mode/dst/environmentVariable) rather
# than splatting the evaluated secret's own attrset (which would carry
# `src` straight through) -- a `evaled.${n} // { ... }`-style splat (the
# exact shape nix/users.nix's OWN mkManifest legitimately uses for `users`/
# `groups`, which have no material-bearing field to worry about) must NOT
# appear here.
if printf '%s' "$code_only" | grep -qE '\bevaled\.\$\{n\}\s*//'; then
  fail "$secrets_nix splats the evaluated secret attrset directly into the manifest -- this would carry 'src' straight through (see nix/users.nix's own mkManifest for the pattern this file must NOT copy)"
fi

# -- (2) bin/ubx-secrets' validate_manifest rejects an extra-key secret -----
ubx_secrets="$UBX_REPO_ROOT/bin/ubx-secrets"
[ -x "$ubx_secrets" ] || { echo "FAIL: $ubx_secrets does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

tampered="$work/tampered-manifest.json"
cat > "$tampered" <<'EOF'
{"version": 1, "secrets": [
  {"name": "proToken", "owner": "root", "group": "root", "mode": "0400",
   "dst": "/run/secrets/proToken", "environmentVariable": null,
   "src": "/flake/secrets/pro-token"}
]}
EOF

out=""
rc=0
out="$("$ubx_secrets" plan --manifest "$tampered" --out "$work/plan.json" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a manifest secret carrying an extra 'src' key must be REFUSED (nonzero exit), got 0: $out"
case "$out" in
  *"disallowed key"*"src"*) ;;
  *) fail "refusal message should name the disallowed 'src' key, got: $out" ;;
esac
[ ! -e "$work/plan.json" ] || fail "a refused manifest must never produce a plan file"

# A second tampering shape: a plain "value" key (the most direct way real
# material could be smuggled through).
tampered2="$work/tampered-manifest2.json"
cat > "$tampered2" <<'EOF'
{"version": 1, "secrets": [
  {"name": "apiToken", "owner": "root", "group": "root", "mode": "0400",
   "dst": "/run/secrets/apiToken", "environmentVariable": null,
   "value": "not-actually-secret-but-should-still-be-refused"}
]}
EOF
rc2=0
out2="$("$ubx_secrets" plan --manifest "$tampered2" --out "$work/plan2.json" 2>&1)" || rc2=$?
[ "$rc2" -ne 0 ] || fail "a manifest secret carrying an extra 'value' key must be REFUSED, got 0: $out2"
[ ! -e "$work/plan2.json" ] || fail "a refused (value-key) manifest must never produce a plan file"

# -- A clean, allowlisted-only manifest must plan successfully --------------
clean="$work/clean-manifest.json"
cat > "$clean" <<'EOF'
{"version": 1, "secrets": [
  {"name": "proToken", "owner": "root", "group": "root", "mode": "0400",
   "dst": "/run/secrets/proToken", "environmentVariable": null}
]}
EOF
rc3=0
"$ubx_secrets" plan --manifest "$clean" --out "$work/plan3.json" > /dev/null 2>&1 || rc3=$?
[ "$rc3" -eq 0 ] || fail "a clean, allowlisted-only manifest should plan successfully, got rc=$rc3"
[ -s "$work/plan3.json" ] || fail "a clean manifest should produce a non-empty plan file"

exit "$fails"
