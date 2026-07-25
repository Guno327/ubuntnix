#!/usr/bin/env bash
# tests/unit/139-ubx-etc-apply.sh — bin/ubx-etc-apply's plan->apply
# executor (SPEC.md §4.2, §4.3, §7; GitHub issue #54), plus end-to-end
# `ubx rebuild switch --apply` wiring through bin/ubx's execute_domains.
#
# Mirrors tests/unit/124-systemd-observe-report-apply.sh /
# tests/unit/137-ubx-systemd-apply-real-invocation.sh's own style for
# bin/ubx-systemd-apply, adapted to bin/ubx-etc-apply's create/
# update-content/update-metadata/remove/drift action set.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

apply="$UBX_REPO_ROOT/bin/ubx-etc-apply"
etc="$UBX_REPO_ROOT/bin/ubx-etc"
ubx="$UBX_REPO_ROOT/bin/ubx"
[ -x "$apply" ] || { echo "FAIL: $apply does not exist or is not executable" >&2; exit 1; }
[ -x "$etc" ] || { echo "FAIL: $etc does not exist or is not executable" >&2; exit 1; }
[ -x "$ubx" ] || { echo "FAIL: $ubx does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# =====================================================================
# 1) A real plan (create + update-metadata + remove + drift) applied
#    directly via bin/ubx-etc-apply --apply into a temp --etc-dir.
# =====================================================================
content_dir="$work/content"
mkdir -p "$content_dir/app"
printf 'Welcome.\n' > "$content_dir/motd"
printf '{"greeting":"hi"}\n' > "$content_dir/app/config.json"

etc_dir="$work/etcdir"
mkdir -p "$etc_dir/app" "$etc_dir/gone"
printf '{"greeting":"old"}\n' > "$etc_dir/app/config.json"
chmod 0644 "$etc_dir/app/config.json"
printf 'stale\n' > "$etc_dir/gone/away"

plan="$work/plan.tsv"
cat > "$plan" <<EOF
create	motd	root	root	0644	$(sha256sum "$content_dir/motd" | cut -d' ' -f1)
update-metadata	app/config.json	root	root	0640	x
remove	gone/away	-	-	-	-
drift	unmanaged/stray	someone	somegroup	0600	y
EOF

# -- --dry-run must not touch the filesystem at all.
dryrun_out="$(PATH="$PATH" "$apply" --plan "$plan" --content-dir "$content_dir" --etc-dir "$etc_dir" 2>&1)"
dryrun_rc=$?
[ "$dryrun_rc" -eq 0 ] || fail "dry-run should exit 0, got $dryrun_rc: $dryrun_out"
[ ! -e "$etc_dir/motd" ] || fail "dry-run must not create $etc_dir/motd"
[ -f "$etc_dir/gone/away" ] || fail "dry-run must not remove $etc_dir/gone/away"
[ "$(stat -c '%a' "$etc_dir/app/config.json")" = "644" ] || fail "dry-run must not change app/config.json's mode"
case "$dryrun_out" in
  *"drift: unmanaged/stray"*) ;;
  *) fail "dry-run output should surface the drift diagnostic: $dryrun_out" ;;
esac
case "$dryrun_out" in
  *"install"*"-D"*"-m"*"0644"*"motd"*) ;;
  *) fail "dry-run output should print an install command for motd: $dryrun_out" ;;
esac

# -- --apply performs the real writes.
apply_out="$("$apply" --plan "$plan" --content-dir "$content_dir" --etc-dir "$etc_dir" --apply 2>&1)"
apply_rc=$?
[ "$apply_rc" -eq 0 ] || fail "--apply should exit 0, got $apply_rc: $apply_out"

[ -f "$etc_dir/motd" ] || fail "--apply should have created $etc_dir/motd"
[ "$(cat "$etc_dir/motd" 2> /dev/null)" = "Welcome." ] || fail "$etc_dir/motd content mismatch: $(cat "$etc_dir/motd" 2> /dev/null)"
[ "$(stat -c '%a' "$etc_dir/motd" 2> /dev/null)" = "644" ] || fail "$etc_dir/motd mode mismatch: $(stat -c '%a' "$etc_dir/motd" 2> /dev/null)"

[ "$(stat -c '%a' "$etc_dir/app/config.json" 2> /dev/null)" = "640" ] || fail "update-metadata should have chmod'd app/config.json to 0640, got $(stat -c '%a' "$etc_dir/app/config.json" 2> /dev/null)"
[ "$(cat "$etc_dir/app/config.json" 2> /dev/null)" = '{"greeting":"old"}' ] || fail "update-metadata must NOT rewrite app/config.json's content, got: $(cat "$etc_dir/app/config.json" 2> /dev/null)"

[ ! -f "$etc_dir/gone/away" ] || fail "--apply should have removed $etc_dir/gone/away"

[ ! -e "$etc_dir/unmanaged/stray" ] || fail "drift must never be written by --apply"

# =====================================================================
# 2) remove of an already-absent path must exit 0 (idempotent teardown,
#    mirroring bin/ubx-systemd-apply's own tests/unit/138).
# =====================================================================
remove_plan="$work/remove-plan.tsv"
printf 'remove\tnever-existed\t-\t-\t-\t-\n' > "$remove_plan"
remove_rc=0
remove_out="$("$apply" --plan "$remove_plan" --etc-dir "$etc_dir" --apply 2>&1)" || remove_rc=$?
[ "$remove_rc" -eq 0 ] || fail "removing an already-absent path must exit 0, got $remove_rc: $remove_out"

# =====================================================================
# 3) an empty (fully converged) plan is a no-op success.
# =====================================================================
empty_plan="$work/empty-plan.tsv"
: > "$empty_plan"
empty_rc=0
"$apply" --plan "$empty_plan" --etc-dir "$etc_dir" --apply > /dev/null 2>&1 || empty_rc=$?
[ "$empty_rc" -eq 0 ] || fail "an empty plan should exit 0, got $empty_rc"

# =====================================================================
# 4) end to end: `ubx rebuild switch --apply` actually writes an /etc
#    file through bin/ubx's execute_domains wiring (mirrors
#    tests/unit/137's own systemd end-to-end section).
# =====================================================================
e2e_content_dir="$work/e2e-content"
mkdir -p "$e2e_content_dir"
printf 'hello from ubx rebuild switch\n' > "$e2e_content_dir/greeting.txt"
sha="$(sha256sum "$e2e_content_dir/greeting.txt" | cut -d' ' -f1)"

etc_ref="$work/etc-new.json"
cat > "$etc_ref" <<EOF
{"version": 1, "entries": [
  {"path": "greeting.txt", "sha256": "$sha", "owner": "root", "group": "root", "mode": "0644"}
]}
EOF

users_ref="$work/users.json"
echo '{"version": 1, "users": [], "groups": []}' > "$users_ref"
passwd="$work/passwd"
group="$work/group"
shadow="$work/shadow"
: > "$passwd"
: > "$group"
: > "$shadow"

e2e_etc_dir="$work/e2e-etcdir"
mkdir -p "$e2e_etc_dir"

export UBX_SOFT_REBOOT_CMD=true # no image delta expected; guard anyway, mirrors tests/unit/137

root="$work/gens"
out="$("$ubx" rebuild switch --root "$root" \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --etc-ref "$etc_ref" --users-manifest "$users_ref" \
  --apply --etc-content-dir "$e2e_content_dir" --etc-dir "$e2e_etc_dir" \
  --users-out "$work/gen1-users.sh" --passwd "$passwd" --group "$group" --shadow "$shadow" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'ubx rebuild switch --apply' should exit 0, got $rc: $out"
[ -f "$e2e_etc_dir/greeting.txt" ] || fail "'ubx rebuild switch --apply' should have written $e2e_etc_dir/greeting.txt"
[ "$(cat "$e2e_etc_dir/greeting.txt" 2> /dev/null)" = "hello from ubx rebuild switch" ] \
  || fail "$e2e_etc_dir/greeting.txt content mismatch: $(cat "$e2e_etc_dir/greeting.txt" 2> /dev/null)"

exit "$fails"
