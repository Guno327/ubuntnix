#!/usr/bin/env bash
# tests/unit/185-ubx-rebuild-home-wiring.sh — `ubx rebuild switch|test|boot`,
# `ubx rollback`, and `ubx diff` wiring the home domain into bin/ubx's own
# convergence orchestration (SPEC.md §9, §4.3; GitHub issue #98, milestone
# M5). Mirrors tests/unit/174-ubx-rebuild-pro-wiring.sh's own overall
# shape, adapted to the home domain's plain --apply/--dry-run gating (no
# snap-purge-style "test never applies" carve-out — see bin/ubx's own
# execute_domains header) and a real, unprivileged file-only home manifest
# for the --apply path (service actions are covered by
# tests/unit/184-home-apply.sh's own runuser/systemctl seam checks — this
# test only proves bin/ubx's OWN wiring, not bin/ubx-home-apply's internal
# command construction again).
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
[ -x "$ubx" ] || { echo "FAIL: $ubx does not exist or is not executable" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

export UBX_SOFT_REBOOT_CMD=true
export UBX_NEXTROOT_STAGE_CMD=true

mkdir -p "$work/home-content/gunnar/files"
printf 'export EDITOR=vim\n' > "$work/home-content/gunnar/files/.bashrc"
sha_bashrc="$(sha256sum "$work/home-content/gunnar/files/.bashrc" | cut -d' ' -f1)"

home_manifest="$work/home-manifest.json"
cat > "$home_manifest" <<EOF
{"version": 1, "users": [
  {"name": "gunnar", "files": [
    {"path": ".bashrc", "sha256": "$sha_bashrc", "mode": "0644"}
  ], "services": []}
]}
EOF

common_flags=(--rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --home-manifest "$home_manifest" --home-content-dir "$work/home-content" \
  --users-out "$work/users-out.sh" --passwd /dev/null --group /dev/null --shadow /dev/null)

# =====================================================================
# 1) `rebuild switch` (no --apply): dry-run mode, nothing installed; the
#    home domain's touch count is reported.
# =====================================================================
root1="$work/gens1"
homes1="$work/homes1"
out="$("$ubx" rebuild switch --root "$root1" --homes-dir "$homes1" "${common_flags[@]}" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild switch' (no --apply) should exit 0, got $rc: $out"
contains "$out" "home: 1 action(s) touched" || fail "'rebuild switch' should report the home domain's 1 touched action (install .bashrc), got: $out"
[ ! -e "$homes1/gunnar/.bashrc" ] || fail "'rebuild switch' without --apply must never install a home file"

# =====================================================================
# 2) `rebuild switch --apply`: real convergence -- installs the declared
#    file into --homes-dir/gunnar/.bashrc.
# =====================================================================
root2="$work/gens2"
homes2="$work/homes2"
out="$("$ubx" rebuild switch --root "$root2" --homes-dir "$homes2" --apply "${common_flags[@]}" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild switch --apply' should exit 0, got $rc: $out"
[ -f "$homes2/gunnar/.bashrc" ] || fail "'rebuild switch --apply' should have installed $homes2/gunnar/.bashrc"
content="$(cat "$homes2/gunnar/.bashrc" 2>/dev/null || true)"
[ "$content" = "export EDITOR=vim" ] || fail "installed .bashrc has wrong content: $content"

# =====================================================================
# 3) `rebuild test --apply`: home DOES apply for real under `test` too
#    (no snap-purge-style carve-out) -- see bin/ubx's execute_domains header.
# =====================================================================
root3="$work/gens3"
homes3="$work/homes3"
out="$("$ubx" rebuild test --root "$root3" --homes-dir "$homes3" --apply "${common_flags[@]}" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild test --apply' should exit 0, got $rc: $out"
[ -f "$homes3/gunnar/.bashrc" ] || fail "'rebuild test --apply' should also have installed the home file for real"

# =====================================================================
# 4) `rebuild boot`: never activates anything live (boot never calls
#    execute_domains at all).
# =====================================================================
root4="$work/gens4"
homes4="$work/homes4"
out="$("$ubx" rebuild boot --root "$root4" --homes-dir "$homes4" --apply "${common_flags[@]}" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild boot --apply' should exit 0, got $rc: $out"
[ ! -e "$homes4/gunnar/.bashrc" ] || fail "'rebuild boot' must never install a home file"

# =====================================================================
# 5) omitting --home-manifest entirely: the domain is skipped, exactly
#    like every other omitted domain ref.
# =====================================================================
root5="$work/gens5"
homes5="$work/homes5"
out="$("$ubx" rebuild switch --root "$root5" --homes-dir "$homes5" --apply \
  --rootfs-image /store/r1 --kernel /store/k1 --initrd /store/i1 --root-device /dev/sda1 \
  --users-out "$work/users-out5.sh" --passwd /dev/null --group /dev/null --shadow /dev/null 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "'rebuild switch --apply' with no --home-manifest should exit 0, got $rc: $out"
contains "$out" "home: nothing declared" || fail "'rebuild switch' with no --home-manifest declared should report 'nothing declared', got: $out"

# =====================================================================
# 6) `ubx rollback` re-converges the home domain too, reading the
#    generation's own home-manifest reference back off the sidecar file.
# =====================================================================
root6="$work/gens6"
homes6="$work/homes6"
out="$("$ubx" rebuild switch --root "$root6" --homes-dir "$homes6" --apply "${common_flags[@]}" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "seeding generation 1 for rollback should exit 0, got $rc: $out"

out2="$("$ubx" rebuild switch --root "$root6" --homes-dir "$homes6" --apply "${common_flags[@]}" 2>&1)"
rc2=$?
[ "$rc2" -eq 0 ] || fail "seeding generation 2 for rollback should exit 0, got $rc2: $out2"

rollback_out="$("$ubx" rollback --root "$root6" --homes-dir "$homes6" --home-content-dir "$work/home-content" --apply \
  --users-out "$work/rollback-users.sh" --passwd /dev/null --group /dev/null --shadow /dev/null 2>&1)"
rollback_rc=$?
[ "$rollback_rc" -eq 0 ] || fail "'ubx rollback --apply' should exit 0, got $rollback_rc: $rollback_out"
contains "$rollback_out" "home:" || fail "'ubx rollback' should mention the home domain, got: $rollback_out"

# =====================================================================
# 7) `ubx diff` reports the home domain in its verbose output.
# =====================================================================
diff_out="$("$ubx" diff --root "$root6" 2>&1)"
diff_rc=$?
[ "$diff_rc" -eq 0 ] || fail "'ubx diff' should exit 0, got $diff_rc: $diff_out"
contains "$diff_out" "home:" || fail "'ubx diff' should mention the home domain, got: $diff_out"

exit "$fails"
