#!/usr/bin/env bash
# tests/unit/112-etc-observe.sh — `ubx-etc observe`: walking a real
# directory into an observed-state manifest (SPEC.md §4.3 "activation
# computes the delta against observed system state"; GitHub issue #26,
# milestone M2).
#
# No root/privilege needed: `observe` stat()s whatever it's pointed at,
# and a plain mktemp -d directory owned by the test's own uid/gid is a
# perfectly real filesystem to observe (tests/README.md's "no root, no
# network" rule is about not requiring privilege, not about avoiding the
# filesystem entirely -- bin/ubx-etc's own header calls this out as "the
# one subcommand in this script that touches a real filesystem").
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

dir="$work/etc"
mkdir -p "$dir/ssh" "$dir/app" "$dir/emptydir"
printf 'root:x:0:0::/root:/bin/bash\n' > "$dir/motd"
printf '{"a":1}\n' > "$dir/app/config.json"
printf 'sshd config\n' > "$dir/ssh/sshd_config"
chmod 0640 "$dir/app/config.json"
chmod 0644 "$dir/motd"
# a symlink and a directory-only entry must both be skipped (regular files
# only -- see cmd_observe_usage's own doc).
ln -s motd "$dir/motd-link"

out="$work/observed.json"
"$etc" observe --dir "$dir" --out "$out" || fail "observe --dir failed"
[ -f "$out" ] || fail "observe did not write $out"

if [ -f "$out" ]; then
  check="$(python3 - "$out" "$dir" <<'PYEOF'
import hashlib
import json
import os
import sys

out_path, dir_path = sys.argv[1:3]
data = json.load(open(out_path))
assert data["version"] == 1, data

entries = {e["path"]: e for e in data["entries"]}
want_paths = {"motd", "app/config.json", "ssh/sshd_config"}
got_paths = set(entries)
if got_paths != want_paths:
    print(f"unexpected path set: {sorted(got_paths)} (want {sorted(want_paths)})")
    sys.exit(1)

# sorted-by-path ordering, no explicit tiebreak needed.
paths_in_order = [e["path"] for e in data["entries"]]
if paths_in_order != sorted(paths_in_order):
    print(f"entries not sorted by path: {paths_in_order}")
    sys.exit(1)

# content hash matches a real independent sha256 computation.
for rel in want_paths:
    full = os.path.join(dir_path, rel)
    h = hashlib.sha256(open(full, "rb").read()).hexdigest()
    if entries[rel]["sha256"] != h:
        print(f"{rel}: sha256 mismatch: manifest={entries[rel]['sha256']} actual={h}")
        sys.exit(1)

# mode is captured as a 4-digit octal string matching what was chmod'd.
if entries["app/config.json"]["mode"] != "0640":
    print(f"app/config.json: expected mode 0640, got {entries['app/config.json']['mode']!r}")
    sys.exit(1)
if entries["motd"]["mode"] != "0644":
    print(f"motd: expected mode 0644, got {entries['motd']['mode']!r}")
    sys.exit(1)

for e in data["entries"]:
    if set(e.keys()) != {"path", "sha256", "owner", "group", "mode"}:
        print(f"unexpected field set: {sorted(e.keys())}")
        sys.exit(1)
PYEOF
)"
  check_rc=$?
  [ "$check_rc" -eq 0 ] || fail "observed manifest content check failed: $check"
fi

# -- symlinks and directories never appear as entries -----------------------
if [ -f "$out" ]; then
  grep -q 'motd-link' "$out" && fail "observe included a symlink (motd-link) as an entry"
  grep -q 'emptydir' "$out" && fail "observe included a directory (emptydir) as an entry"
fi

# -- determinism: repeated observe of an UNCHANGED tree is byte-identical --
out2="$work/observed2.json"
"$etc" observe --dir "$dir" --out "$out2" || fail "second observe --dir failed"
if [ -f "$out" ] && [ -f "$out2" ]; then
  diff -u "$out" "$out2" > "$work/diff.txt" || fail "two observe runs against an unchanged tree are not byte-identical:
$(cat "$work/diff.txt")"
fi

# -- --dir is required, and a nonexistent dir is a hard error --------------
missing_rc=0
"$etc" observe --dir "$work/does-not-exist" > /dev/null 2>&1 || missing_rc=$?
[ "$missing_rc" -ne 0 ] || fail "observe --dir <missing> should fail"

no_dir_rc=0
"$etc" observe > /dev/null 2>&1 || no_dir_rc=$?
[ "$no_dir_rc" -ne 0 ] || fail "observe with no --dir should fail"

# -- an EMPTY directory produces a well-formed, empty-entries manifest -----
empty_dir="$work/empty"
mkdir -p "$empty_dir"
empty_out="$work/empty-observed.json"
"$etc" observe --dir "$empty_dir" --out "$empty_out" || fail "observe on an empty dir failed"
if [ -f "$empty_out" ]; then
  python3 -c "
import json, sys
d = json.load(open('$empty_out'))
assert d == {'version': 1, 'entries': []}, d
" || fail "observe on an empty dir did not produce {version:1, entries:[]}"
fi

# -- stdout default (--out omitted, or '-') ---------------------------------
stdout_out="$("$etc" observe --dir "$dir")"
python3 -c "
import json
json.loads('''$stdout_out''')
" || fail "observe with no --out did not print valid JSON to stdout"

exit "$fails"
