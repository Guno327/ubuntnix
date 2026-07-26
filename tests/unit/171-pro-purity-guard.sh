#!/usr/bin/env bash
# tests/unit/171-pro-purity-guard.sh — SPEC.md §8.1's "ABSOLUTE INVARIANT:
# no secret material ever enters a store object", enforced for the Ubuntu
# Pro token specifically (SPEC.md §8.2; GitHub issue #82, milestone M4).
# Mirrors tests/unit/160-secrets-purity-guard.sh's role for nix/secrets.nix,
# adapted to nix/pro.nix + bin/ubx-pro's own consumption of a secret NAME
# (never a value):
#
#   1. nix/pro.nix's own CODE never reads/forces real secret material (no
#      `src` field, no `builtins.readFile` pointed at `secrets/`) -- a
#      static grep, since this harness has no `nix` binary.
#   2. bin/ubx-pro's `validate_manifest`/`build_plan` never touch a token
#      VALUE at all -- checked by planning against a manifest/observed pair
#      and asserting the token's own bytes never appear anywhere in the
#      emitted plan (the plan carries only `tokenSecretName`, a bare
#      identifier, never a value).
#   3. bin/ubx-pro-apply's dry-run output never leaks a token value either
#      (mirrors tests/unit/164's own "the secret VALUE must never appear in
#      the printed command text" check).
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

pro_nix="nix/pro.nix"
[ -f "$pro_nix" ] || {
  echo "FAIL: $pro_nix does not exist" >&2
  exit 1
}

# -- (1) nix/pro.nix's own CODE (comments stripped) never reads real secret
# material -- comments are allowed to discuss the invariant in prose (as
# this file's own header does), only actual code matters here.
code_only="$(grep -v '^[[:space:]]*#' "$pro_nix")"
if printf '%s' "$code_only" | grep -qE '"src"|builtins\.readFile.*secrets/'; then
  fail "$pro_nix's CODE looks like it reads real secret material directly -- it must only ever carry a secret NAME, never bytes"
fi
if printf '%s' "$code_only" | grep -qE '\btypes\.path\b'; then
  fail "$pro_nix declares a lib.types.path option -- tokenSecret must stay a plain secret-NAME string (strMatching), never a path type capable of pointing at real material"
fi

# -- (2) bin/ubx-pro: the token value never appears in a plan ---------------
ubx_pro="$UBX_REPO_ROOT/bin/ubx-pro"
ubx_pro_apply="$UBX_REPO_ROOT/bin/ubx-pro-apply"
[ -x "$ubx_pro" ] || { echo "FAIL: $ubx_pro does not exist or is not executable" >&2; exit 1; }
[ -x "$ubx_pro_apply" ] || { echo "FAIL: $ubx_pro_apply does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

secret_token="TOTALLY-SECRET-TOKEN-VALUE-abc123"

manifest="$work/manifest.json"
cat > "$manifest" <<'EOF'
{"version": 1, "enable": true, "tokenSecretPath": "/run/secrets/proToken", "esmApps": true, "livepatch": true}
EOF
observed="$work/observed.json"
cat > "$observed" <<'EOF'
{"version": 1, "attached": false, "services": {}}
EOF

plan="$work/plan.json"
"$ubx_pro" plan --manifest "$manifest" --observed "$observed" --out "$plan" \
  || fail "ubx-pro plan should succeed against a clean manifest"

if [ -f "$plan" ] && grep -q "$secret_token" "$plan"; then
  fail "the plan file must never contain a token value (it never had one to leak from, but this asserts the property directly)"
fi
if [ -f "$plan" ] && grep -qE '"token"|"value"|"tokenSecretPath"' "$plan"; then
  fail "the plan's attach action must carry only 'tokenSecretName' (a bare identifier) -- found a disallowed key (token/value/tokenSecretPath) in: $(cat "$plan")"
fi

# -- (3) bin/ubx-pro-apply: dry-run output never leaks a token value -------
run_secrets="$work/run-secrets"
mkdir -p "$run_secrets"
printf '%s' "$secret_token" > "$run_secrets/proToken"

dryrun_out="$("$ubx_pro_apply" --plan "$plan" --run-secrets-dir "$run_secrets" 2>&1)"
case "$dryrun_out" in
  *"$secret_token"*)
    fail "ubx-pro-apply dry-run output must never leak the real token value, got: $dryrun_out"
    ;;
esac

exit "$fails"
