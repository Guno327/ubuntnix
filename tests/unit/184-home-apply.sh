#!/usr/bin/env bash
# tests/unit/184-home-apply.sh — `ubx-home-apply`'s dry-run/apply command
# construction: file install/chown/chmod/rm, and per-user
# runuser+systemctl --user calls (SPEC.md §9, §4.3; GitHub issue #98,
# milestone M5). Mirrors tests/unit/139-ubx-etc-apply.sh's/
# tests/unit/137-ubx-systemd-apply-real-invocation.sh's own shape.
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

apply_bin="$UBX_REPO_ROOT/bin/ubx-home-apply"
[ -x "$apply_bin" ] || { echo "FAIL: $apply_bin does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/content/gunnar/files" "$work/content/gunnar/services"
printf 'bashrc content' > "$work/content/gunnar/files/.bashrc"
printf 'unit content' > "$work/content/gunnar/services/backup.service"

sha_file="$(sha256sum "$work/content/gunnar/files/.bashrc" | cut -d' ' -f1)"
sha_svc="$(sha256sum "$work/content/gunnar/services/backup.service" | cut -d' ' -f1)"

plan="$work/plan.json"
cat > "$plan" <<EOF
{"version": 1, "actions": [
  {"op": "install-file", "user": "gunnar", "path": ".bashrc", "action": "create", "mode": "0644", "sha256": "$sha_file"},
  {"op": "update-file-metadata", "user": "gunnar", "path": ".profile", "mode": "0640"},
  {"op": "remove-file", "user": "gunnar", "path": ".oldrc"},
  {"op": "drift-file", "user": "gunnar", "path": ".stray", "sha256": "deadbeef", "mode": "0644"},
  {"op": "write-service-file", "user": "gunnar", "service": "backup.service", "action": "create", "sha256": "$sha_svc"},
  {"op": "daemon-reload", "user": "gunnar"},
  {"op": "enable", "user": "gunnar", "service": "backup.service"},
  {"op": "start", "user": "gunnar", "service": "backup.service"}
]}
EOF

homes_dir="$work/home"
mkdir -p "$homes_dir"

# =====================================================================
# 1) --dry-run (default): prints commands, touches nothing, never requires
#    runuser/systemctl to be on PATH.
# =====================================================================
out="$("$apply_bin" --plan "$plan" --content-dir "$work/content" --homes-dir "$homes_dir" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "dry-run should exit 0, got $rc: $out"
[ ! -e "$homes_dir/gunnar/.bashrc" ] || fail "dry-run must not actually install any file"
contains "$out" "install" || fail "dry-run should print an install command for .bashrc, got: $out"
contains "$out" ".bashrc" || fail "dry-run output should mention .bashrc, got: $out"
contains "$out" "backup.service" || fail "dry-run output should mention backup.service, got: $out"
contains "$out" "runuser" || fail "dry-run should print a runuser-wrapped systemctl --user call, got: $out"
contains "$out" "systemctl" || fail "dry-run should print a systemctl --user call, got: $out"

# drift-file is stderr-only, informational -- must appear regardless of
# mode, and must never become part of the (dry-run) command list itself.
drift_stderr="$("$apply_bin" --plan "$plan" --content-dir "$work/content" --homes-dir "$homes_dir" 2>&1 1>/dev/null)"
contains "$drift_stderr" "drift" || fail "drift-file action should be reported on stderr, got: $drift_stderr"
contains "$drift_stderr" ".stray" || fail "drift stderr should name the stray path, got: $drift_stderr"

# =====================================================================
# 2) --apply, unprivileged: installs content with correct mode, but never
#    attempts ownership (this test harness runs unprivileged, mirroring
#    tests/unit/139-ubx-etc-apply.sh's own posture) -- and never actually
#    reaches for runuser/systemctl unless they're really needed; since this
#    harness has neither reliably available in a form that would succeed
#    against a real user session, this test uses a file-only plan for the
#    real --apply path and separately proves the service-action PATH-check
#    refusal below.
# =====================================================================
file_only_plan="$work/file-only-plan.json"
cat > "$file_only_plan" <<EOF
{"version": 1, "actions": [
  {"op": "install-file", "user": "gunnar", "path": ".bashrc", "action": "create", "mode": "0644", "sha256": "$sha_file"}
]}
EOF

apply_out="$("$apply_bin" --plan "$file_only_plan" --content-dir "$work/content" --homes-dir "$homes_dir" --apply 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "--apply (file-only plan) should exit 0, got $rc: $apply_out"
[ -f "$homes_dir/gunnar/.bashrc" ] || fail "--apply should have installed $homes_dir/gunnar/.bashrc"
content="$(cat "$homes_dir/gunnar/.bashrc")"
[ "$content" = "bashrc content" ] || fail "--apply installed file has wrong content: $content"
mode="$(stat -c '%a' "$homes_dir/gunnar/.bashrc")"
[ "$mode" = "644" ] || fail "--apply installed file has wrong mode: $mode"

# =====================================================================
# 3) --apply with service actions present, but neither runuser nor
#    systemctl reliably resolvable: refuses outright rather than silently
#    downgrading (mirrors bin/ubx-systemd-apply's own refusal posture) --
#    forced here by pointing PATH at an empty directory.
# =====================================================================
empty_path_dir="$work/empty-path"
mkdir -p "$empty_path_dir"
svc_out="$(PATH="$empty_path_dir" "$apply_bin" --plan "$plan" --content-dir "$work/content" --homes-dir "$homes_dir" --apply 2>&1)"
svc_rc=$?
[ "$svc_rc" -ne 0 ] || fail "--apply with service actions and no runuser/systemctl on PATH should refuse (nonzero exit), got 0: $svc_out"
contains "$svc_out" "runuser" || contains "$svc_out" "systemctl" || fail "refusal message should mention runuser/systemctl, got: $svc_out"

exit "$fails"
