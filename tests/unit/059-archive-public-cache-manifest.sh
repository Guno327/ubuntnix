#!/usr/bin/env bash
# tests/unit/059-archive-public-cache-manifest.sh — the public project
# cache / public ISO manifest must exclude esm content (SPEC.md §4.4 "esm
# content is subscription-gated and is never redistributed", §10 "Public
# artifacts never include esm content"; GitHub issue #81, milestone M4).
#
# Exercises bin/ubx-archive-public-manifest against a fixture lockfile
# carrying BOTH a public tier and a populated esm tier, and asserts the
# emitted manifest contains the public entries but NONE of the esm ones --
# by name, by sha256, and structurally (no 'esm' key at all in the
# output). No network access happens here.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

manifest_tool="$UBX_REPO_ROOT/bin/ubx-archive-public-manifest"
[ -x "$manifest_tool" ] || {
  echo "FAIL: $manifest_tool does not exist or is not executable" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fixture="$work/archive.lock.json"
cat > "$fixture" <<'EOF'
{
  "version": 1,
  "public": {
    "snapshot": "20260715T000000Z",
    "series": "noble",
    "packages": [
      {
        "name": "ed", "version": "1.20.1-1", "arch": "amd64",
        "component": "main", "path": "pool/main/e/ed/ed_1.20.1-1_amd64.deb",
        "sha256": "c26e577a24cc784d678b0b2b960db8a154fb7138fc1aa7ad1ffe504698432a43",
        "size": 56062
      },
      {
        "name": "hello", "version": "2.10-3build1", "arch": "amd64",
        "component": "main", "path": "pool/main/h/hello/hello_2.10-3build1_amd64.deb",
        "sha256": "e68cf4365b7aa9c4e2af4af6eee1710d6f967059b7b4af62786e8870d7366333",
        "size": 26006
      }
    ]
  },
  "esm": {
    "packages": [
      {
        "name": "secret-esm-only-pkg", "version": "1.0-1ubuntu1~esm1",
        "sha256": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
        "path": "pool/esm-apps/main/s/secret-esm-only-pkg/secret-esm-only-pkg_1.0-1ubuntu1~esm1_amd64.deb",
        "source": "esm"
      }
    ]
  }
}
EOF

out_file="$work/public-manifest.json"
out="$("$manifest_tool" --lockfile "$fixture" --out "$out_file" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "building the manifest should exit 0 (rc=$rc, output: $out)"
[ -f "$out_file" ] || fail "--out did not write $out_file"

if [ -f "$out_file" ]; then
  # -- no leak, by name --
  grep -q "secret-esm-only-pkg" "$out_file" &&
    fail "the public-cache manifest contains the esm-only package name -- esm content must never be redistributed publicly (SPEC.md §4.4, §10)"

  # -- no leak, by hash (a renamed-but-same-bytes esm artifact must not
  # slip through either) --
  grep -q "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$out_file" &&
    fail "the public-cache manifest contains the esm-only package's sha256"

  # -- structurally: no 'esm' key in the manifest output at all --
  python3 - "$out_file" <<'PYEOF'
import json
import sys

data = json.load(open(sys.argv[1]))
if "esm" in data:
    print("FAIL: manifest output has a top-level 'esm' key", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PYEOF
  py_rc=$?
  [ "$py_rc" -eq 0 ] || fail "manifest output structurally carries an 'esm' key"

  # -- the public entries ARE present, by name --
  for name in ed hello; do
    grep -q "\"$name\"" "$out_file" || fail "manifest is missing the public-tier package '$name'"
  done

  # -- package count matches the public tier exactly (2), not public+esm (3) --
  count="$(python3 -c "import json; print(len(json.load(open('$out_file'))['packages']))")"
  [ "$count" = "2" ] || fail "expected exactly 2 packages in the manifest (public tier only), got $count"
fi

# -- to stdout by default (no --out) --------------------------------------
stdout_out="$("$manifest_tool" --lockfile "$fixture" 2>/dev/null)"
case "$stdout_out" in
  *"secret-esm-only-pkg"*) fail "stdout-mode manifest leaked the esm-only package name" ;;
  *) ;;
esac
echo "$stdout_out" | python3 -c "
import json, sys
data = json.load(sys.stdin)
assert 'esm' not in data, 'esm key present in stdout manifest'
assert len(data['packages']) == 2, data['packages']
" || fail "stdout-mode manifest failed the same structural checks"

# -- a lockfile whose esm tier accidentally shares a sha256 with a public
# entry must be rejected outright (the defensive cross-check) -------------
overlap_fixture="$work/overlap.json"
python3 -c "
import json
data = json.load(open('$fixture'))
data['esm']['packages'][0]['sha256'] = data['public']['packages'][0]['sha256']
json.dump(data, open('$overlap_fixture', 'w'))
"
overlap_out="$("$manifest_tool" --lockfile "$overlap_fixture" 2>&1)"
overlap_rc=$?
[ "$overlap_rc" -ne 0 ] || fail "a lockfile with an esm/public sha256 collision should be rejected, got exit 0"
case "$overlap_out" in
  *"BOTH the esm and public tiers"*) ;;
  *) fail "the overlap error should explain the sha256 collision, got: $overlap_out" ;;
esac

# -- --help works and mentions the exclusion contract ----------------------
help_out="$("$manifest_tool" --help 2>&1)"
case "$help_out" in
  *"public"*) ;;
  *) fail "--help output does not mention 'public'" ;;
esac

exit "$fails"
