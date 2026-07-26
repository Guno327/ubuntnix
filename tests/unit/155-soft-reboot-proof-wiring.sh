#!/usr/bin/env bash
# tests/unit/155-soft-reboot-proof-wiring.sh — nix/boot.nix's
# soft-reboot-proof section: static wiring checks (GitHub issue #59, a
# follow-up to #55/#58). Mirrors tests/unit/152-snap-converge-proof-
# wiring.sh's relationship to nix/boot.nix's M3 section.
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same standing caveat), so nothing here can actually
# evaluate or build the flake -- that's CI-only (a "soft-reboot" job in
# .github/workflows/ci.yml building `.#soft-reboot-proof`, and
# tests/e2e/040-qemu-soft-reboot-e2e.sh). This test is a machine-checked
# textual guard instead: it confirms the new proof is wired into
# nix/boot.nix, exposes a real `packages.soft-reboot-proof` flake output,
# reuses the plain two-partition `diskImage` (not `switchLoopDiskImage`),
# drives a REAL `systemctl soft-reboot` (not a stub), asserts boot_id
# preservation, emits every documented marker, and that CI builds/asserts
# the proof and runs the e2e harness.
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
grep -q 'packages.soft-reboot-proof' "$boot_nix" ||
  fail "$boot_nix does not declare packages.soft-reboot-proof"

# -- reuses the plain two-partition diskImage (M1), NOT switchLoopDiskImage
#    (this proof needs no ext4 partition -- state lives in /run across the
#    re-exec itself; see this section's own header). ------------------------
grep -q 'softRebootDiskImageDrv = diskImage {' "$boot_nix" ||
  fail "$boot_nix's soft-reboot-proof does not reuse the plain diskImage function"

# -- must reuse M1's proofKernel rather than re-extracting a second one -----
awk '/softRebootDiskImageDrv = diskImage \{/,/\};/' "$boot_nix" | grep -q 'kernel = proofKernel;' ||
  fail "$boot_nix's soft-reboot-proof does not reuse M1's proofKernel"

# -- must drive a REAL systemctl soft-reboot, not a stub --------------------
grep -q 'systemctl soft-reboot' "$boot_nix" ||
  fail "$boot_nix's soft-reboot-proof does not invoke a real 'systemctl soft-reboot'"

# -- boot_id preservation assertion (proves no full/kernel reboot) ---------
grep -q 'boot_id' "$boot_nix" ||
  fail "$boot_nix's soft-reboot-proof does not reference /proc/sys/kernel/random/boot_id"
grep -qE 'UBX_SR_BOOT_ID_BEFORE' "$boot_nix" ||
  fail "$boot_nix's soft-reboot-proof does not persist the pre-reboot boot_id across the re-exec"

# -- the marker scheme: every documented marker must actually be emitted --
for marker in UBX-SR-PRE-PASS UBX-SR-BOOTID-PASS UBX-SR-POST-PASS UBX-SR-NOTE UBX-SR-FAIL; do
  grep -qF "$marker" "$boot_nix" ||
    fail "$boot_nix's soft-reboot-proof does not emit the $marker marker"
done

# -- clean-fallback gates: systemd version + a wall-clock slow-boot proxy --
grep -qE '\-ge 254' "$boot_nix" ||
  fail "$boot_nix's soft-reboot-proof does not gate on systemd >= 254"
grep -q '/proc/uptime' "$boot_nix" ||
  fail "$boot_nix's soft-reboot-proof does not use a wall-clock uptime heuristic for the no-KVM/slow-TCG fallback"

# -- the host harness that scrapes these markers ----------------------------
harness="tests/e2e/040-qemu-soft-reboot-e2e.sh"
[ -x "$harness" ] || fail "$harness does not exist or is not executable"
if [ -f "$harness" ]; then
  for marker in UBX-SR-BOOTID-PASS UBX-SR-POST-PASS UBX-SR-NOTE UBX-SR-FAIL; do
    grep -qF "$marker" "$harness" ||
      fail "$harness does not reference $marker"
  done
fi

# -- CI wiring ---------------------------------------------------------------
ci_yml=".github/workflows/ci.yml"
[ -f "$ci_yml" ] || fail "$ci_yml does not exist"
if [ -f "$ci_yml" ]; then
  grep -q 'soft-reboot-proof' "$ci_yml" ||
    fail "$ci_yml does not reference soft-reboot-proof (the CI build step is missing)"
  grep -q '040-qemu-soft-reboot-e2e.sh' "$ci_yml" ||
    fail "$ci_yml does not run tests/e2e/040-qemu-soft-reboot-e2e.sh"
  grep -q 'sandbox relaxed' "$ci_yml" ||
    fail "$ci_yml does not request --option sandbox relaxed anywhere (needed transitively via runInUbuntuBase)"
fi

# The purity guard must still hold with this section in the tree -- mirrors
# tests/unit/152's own final check.
purity_test="tests/unit/021-flake-purity.sh"
if [ -x "$purity_test" ]; then
  "$purity_test" || fail "$purity_test no longer passes with nix/boot.nix's soft-reboot-proof in the tree"
else
  fail "$purity_test is missing or not executable"
fi

exit "$fails"
