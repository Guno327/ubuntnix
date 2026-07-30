#!/usr/bin/env bash
# tests/unit/192-home-activation-proof-wiring.sh — nix/boot.nix's
# home-activation-proof section: static wiring checks (SPEC.md §9, §11 M5
# exit criterion; GitHub issue #105, a live-QEMU follow-up to #98). Mirrors
# tests/unit/155-soft-reboot-proof-wiring.sh's/
# tests/unit/152-snap-converge-proof-wiring.sh's relationship to their own
# nix/boot.nix sections.
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same standing caveat), so nothing here can actually
# evaluate or build the flake -- that's CI-only (a "home-activation" job in
# .github/workflows/ci.yml building `.#home-activation-proof`, and
# tests/e2e/060-qemu-home-activation-e2e.sh). This test is a machine-
# checked textual guard instead: it confirms the new proof is wired into
# nix/boot.nix, exposes a real `packages.home-activation-proof` flake
# output, reuses the generic three-partition `switchLoopDiskImage`/
# `switchLoopVarImage` machinery (not a duplicate), overwrites the M1
# default `/home` tmpfs mount with a real ext4 one, drives real
# `ubx rebuild switch --apply` calls against BOTH `--users-manifest` and
# `--home-manifest`, documents the systemctl --user/linger fallback,
# emits every documented marker, and that CI builds/asserts the proof and
# runs the e2e harness.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

boot_nix="nix/boot.nix"
[ -f "$boot_nix" ] || {
  echo "FAIL: $boot_nix does not exist" >&2
  exit 1
}

# -- the new flake output proof itself --------------------------------------
grep -q 'packages.home-activation-proof' "$boot_nix" ||
  fail "$boot_nix does not declare packages.home-activation-proof"

# -- reuses the generic three-partition switchLoopDiskImage/switchLoopVarImage
#    (this proof needs a real, persistent /home partition -- see this
#    section's own header, decision 1) rather than duplicating them. -------
grep -q 'homeActivationDiskImageDrv = switchLoopDiskImage {' "$boot_nix" ||
  fail "$boot_nix's home-activation-proof does not reuse switchLoopDiskImage"
grep -q 'homeActivationVarImageDrv = switchLoopVarImage {' "$boot_nix" ||
  fail "$boot_nix's home-activation-proof does not reuse switchLoopVarImage"

# -- must reuse M1's proofKernel rather than re-extracting a second one -----
awk '/homeActivationDiskImageDrv = switchLoopDiskImage \{/,/\};/' "$boot_nix" | grep -q 'kernel = proofKernel;' ||
  fail "$boot_nix's home-activation-proof does not reuse M1's proofKernel"

# -- must override the M1 default /home tmpfs mount with a real ext4 one,
#    mounted from the third disk partition (/dev/vda3, matching
#    switchLoopDiskImage's own boot/squashfs/ext4 partition order). --------
grep -q 'home\.mount' "$boot_nix" ||
  fail "$boot_nix's home-activation-proof does not write a home.mount unit"
grep -qE 'What=/dev/vda3' "$boot_nix" ||
  fail "$boot_nix's home-activation-proof does not mount the third partition (/dev/vda3) at /home"

# -- must drive real ubx rebuild switch --apply calls against both the
#    users domain (account creation) and the home domain (--home-manifest/
#    --home-content-dir) -- never a stand-in. --------------------------
# shellcheck disable=SC2016 # single-quoted on purpose: matching literal
# nix/boot.nix embedded-script text, not expanding in this test's shell.
grep -qE -- '--users-manifest "\$ASSETS/users-manifest\.json"' "$boot_nix" ||
  fail "$boot_nix's home-activation-proof does not pass --users-manifest to a real ubx rebuild switch call"
# shellcheck disable=SC2016
grep -qE -- '--home-manifest "\$ASSETS/gen1/home-manifest\.json"' "$boot_nix" ||
  fail "$boot_nix's home-activation-proof does not pass --home-manifest for generation 1"
# shellcheck disable=SC2016
grep -qE -- '--home-manifest "\$ASSETS/gen2/home-manifest\.json"' "$boot_nix" ||
  fail "$boot_nix's home-activation-proof does not pass --home-manifest for generation 2"
grep -q -- '--home-content-dir' "$boot_nix" ||
  fail "$boot_nix's home-activation-proof does not pass --home-content-dir"

# -- the documented, non-fatal systemctl --user/linger fallback -------------
grep -q 'enable-linger' "$boot_nix" ||
  fail "$boot_nix's home-activation-proof does not call loginctl enable-linger"
grep -q -- '--home-observed' "$boot_nix" ||
  fail "$boot_nix's home-activation-proof does not use --home-observed to skip service actions when the bus is unreachable"

# -- ownership/mode/content assertions -- the acceptance criteria's own
#    "stat -c '%U:%G %a'" contract. -----------------------------------
grep -qE "stat -c '%U:%G %a'" "$boot_nix" ||
  fail "$boot_nix's home-activation-proof does not assert owner/group/mode via stat -c '%U:%G %a'"

# -- the diff-driven "not rewritten" proof (mtime+inode, not just content) --
grep -qE "stat -c '%Y %i'" "$boot_nix" ||
  fail "$boot_nix's home-activation-proof does not assert mtime+inode via stat -c '%Y %i' (the gen1-file-not-rewritten diff proof)"

# -- the marker scheme: every documented marker must actually be emitted --
for marker in UBX-HOME-USER-PASS UBX-HOME-LINGER-PASS UBX-HOME-LINGER-NOTE UBX-HOME-GEN1-PASS UBX-HOME-GEN2-PASS UBX-HOME-REBOOT-PASS UBX-HOME-FAIL; do
  grep -qF "$marker" "$boot_nix" ||
    fail "$boot_nix's home-activation-proof does not emit the $marker marker"
done

# -- the host harness that scrapes these markers ----------------------------
harness="tests/e2e/060-qemu-home-activation-e2e.sh"
[ -x "$harness" ] || fail "$harness does not exist or is not executable"
if [ -f "$harness" ]; then
  for marker in UBX-HOME-USER-PASS UBX-HOME-GEN1-PASS UBX-HOME-GEN2-PASS UBX-HOME-REBOOT-PASS UBX-HOME-FAIL; do
    grep -qF "$marker" "$harness" ||
      fail "$harness does not reference $marker"
  done
fi

# -- CI wiring ---------------------------------------------------------------
ci_yml=".github/workflows/ci.yml"
[ -f "$ci_yml" ] || fail "$ci_yml does not exist"
if [ -f "$ci_yml" ]; then
  grep -q 'home-activation-proof' "$ci_yml" ||
    fail "$ci_yml does not reference home-activation-proof (the CI build step is missing)"
  grep -q '060-qemu-home-activation-e2e.sh' "$ci_yml" ||
    fail "$ci_yml does not run tests/e2e/060-qemu-home-activation-e2e.sh"
  grep -q 'sandbox relaxed' "$ci_yml" ||
    fail "$ci_yml does not request --option sandbox relaxed anywhere (needed transitively via runInUbuntuBase)"
  grep -q 'chmod 666 /dev/kvm' "$ci_yml" ||
    fail "$ci_yml does not grant /dev/kvm access anywhere (needed so the e2e jobs actually use KVM acceleration)"
fi

# The purity guard must still hold with this section in the tree -- mirrors
# tests/unit/155's own final check.
purity_test="tests/unit/021-flake-purity.sh"
if [ -x "$purity_test" ]; then
  "$purity_test" || fail "$purity_test no longer passes with nix/boot.nix's home-activation-proof in the tree"
else
  fail "$purity_test is missing or not executable"
fi

exit "$fails"
