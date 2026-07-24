#!/usr/bin/env bash
# tests/unit/071-boot-flake-wiring.sh — kernel selection, GRUB generation
# machinery, and disk-image assembly: static wiring checks (SPEC.md §4.2/
# §4.3, §6 `ubuntnix.boot`; GitHub issue #10, milestone M1).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same standing caveat), so nothing here can actually
# evaluate or build the flake -- that's CI-only (a "boot" job in
# .github/workflows/ci.yml building `.#boot-image-proof` and friends, and
# tests/e2e/'s QEMU harness). This test is a machine-checked textual guard
# instead, mirroring tests/unit/030/041/060's relationship to their own
# files: it confirms nix/boot.nix exists, is imported by flake.nix, reaches
# the stdenv/archive/compose libraries under the names those files actually
# expose, exposes its own flake.lib.boot, is wired to real per-system proof
# packages, that every package name it hardcodes is actually pinned in
# archive.lock.json, that CI builds/asserts the proof and runs the e2e
# harness, and that the purity guard still holds.
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

# flake.nix must actually import the dendritic module (SPEC.md §2 G8).
grep -q '\./nix/boot\.nix' flake.nix ||
  fail "flake.nix does not import ./nix/boot.nix"

# It must reach the stdenv/archive/compose builder abstractions under the
# EXACT names those files expose -- not some renamed/reinvented equivalent.
grep -qE 'inherit\s*\(config\.flake\.lib\.stdenv\)\s*runInUbuntuBase' "$boot_nix" ||
  fail "$boot_nix does not pull runInUbuntuBase from config.flake.lib.stdenv"
grep -qE 'inherit\s*\(config\.flake\.lib\.archive\)\s*lockfile\s+debs' "$boot_nix" ||
  fail "$boot_nix does not pull lockfile/debs from config.flake.lib.archive"
grep -qE 'inherit\s*\(config\.flake\.lib\.compose\)\s*composeRootfs\s+squashfsImage\s+toolsFHS' "$boot_nix" ||
  fail "$boot_nix does not pull composeRootfs/squashfsImage/toolsFHS from config.flake.lib.compose"

# Cross-check: the names it pulls out must actually be things the other
# files declare under flake.lib -- catches a rename on one side that the
# other wasn't updated for (mirrors 060's identical cross-check).
grep -q 'flake.lib.archive' nix/archive.nix ||
  fail "nix/archive.nix no longer exposes flake.lib.archive (boot.nix depends on it)"
grep -qE '\blockfile\s*=' nix/archive.nix ||
  fail "nix/archive.nix no longer defines lockfile (boot.nix depends on it)"
grep -q 'flake.lib.compose' nix/compose.nix ||
  fail "nix/compose.nix no longer exposes flake.lib.compose (boot.nix depends on it)"

# This file's own library contribution: every advertised function must
# actually be defined AND actually exposed under flake.lib.boot.
grep -q 'flake.lib.boot' "$boot_nix" ||
  fail "$boot_nix does not expose flake.lib.boot"

for fn in mkBootSpec resolveKernelFlavor kernelPathsForFlavor bootRootfs kernelArtifacts grubCfg diskImage; do
  grep -qE "^\s*${fn}\s*=" "$boot_nix" ||
    fail "$boot_nix does not define $fn"
done
# The flake.lib.boot attrset literal must actually list every function
# (not just define it standalone) -- extracted as the block between
# `flake.lib.boot = {` and its closing `};`.
boot_lib_block="$(awk '/flake\.lib\.boot = \{/{p=1} p{print} p && /^\s*\};\s*$/{exit}' "$boot_nix")"
for fn in mkBootSpec resolveKernelFlavor kernelPathsForFlavor bootRootfs kernelArtifacts grubCfg diskImage; do
  echo "$boot_lib_block" | grep -q "\b${fn}\b" ||
    fail "$boot_nix's flake.lib.boot attrset does not list $fn"
done

# perSystem wiring: the M1 proof outputs (issue #10 scope item 4: "Expose
# the image as a flake output proof, e.g. .#boot-image-proof").
grep -q 'systems = \[ "x86_64-linux" \]' "$boot_nix" ||
  fail "$boot_nix does not declare systems = [ \"x86_64-linux\" ]"
for pkg in boot-image-proof boot-kernel-artifacts-proof boot-grub-cfg-proof; do
  grep -q "packages.${pkg}" "$boot_nix" ||
    fail "$boot_nix does not declare packages.${pkg}"
done

# -- the grub.cfg renderer this file drives ---------------------------------
gen_grub="bin/ubx-gen-grub-cfg"
[ -x "$gen_grub" ] || fail "$gen_grub does not exist or is not executable"
grep -q 'genScript = \.\./bin/ubx-gen-grub-cfg' "$boot_nix" ||
  fail "$boot_nix's grubCfg does not reference bin/ubx-gen-grub-cfg as genScript"
# shellcheck disable=SC2016 # single-quoted on purpose: matching a literal
# "$genScript" shell-variable-looking substring in nix/boot.nix's own
# embedded script text, not expanding it in THIS (the test's own) shell.
grep -qF 'source "$genScript"' "$boot_nix" ||
  fail "$boot_nix's grubCfg does not source \$genScript (see that function's own comment on why source, not exec)"

# -- lockfile cross-check ---------------------------------------------------
#
# Every package name this file hardcodes (the kernel default, its concrete
# flavor's pattern-matched result depends on archive.lock.json content
# directly so isn't checked here by name, and diskImage's toolsFHS package
# list) MUST already exist in archive.lock.json's public.packages.
lockfile="archive.lock.json"
[ -f "$lockfile" ] || fail "$lockfile does not exist"

if [ -f "$lockfile" ]; then
  for pkg in linux-image-virtual grub-pc-bin grub-common dosfstools mtools parted; do
    python3 - "$lockfile" "$pkg" <<'PYEOF' || fail "package '$pkg' referenced in $boot_nix is not pinned in $lockfile"
import json, sys
lockfile, pkg = sys.argv[1], sys.argv[2]
data = json.load(open(lockfile))
names = {p.get("name") for p in data.get("public", {}).get("packages", [])}
sys.exit(0 if pkg in names else 1)
PYEOF
  done

  # resolveKernelFlavor's whole mechanism depends on the lockfile carrying
  # AT LEAST ONE "linux-image-<digit...>-generic"-shaped concrete kernel
  # package (its own eval-time throw covers "zero" and "more than one" --
  # this just confirms the one this repo currently locks is still there,
  # so a wiring regression here is caught without needing `nix` to surface
  # resolveKernelFlavor's own throw).
  python3 - "$lockfile" <<'PYEOF' || fail "$lockfile carries no linux-image-<version>-generic concrete kernel package for resolveKernelFlavor to resolve to"
import json, re, sys
data = json.load(open(sys.argv[1]))
names = [p.get("name", "") for p in data.get("public", {}).get("packages", [])]
pat = re.compile(r"^linux-image-[0-9].*-generic$")
sys.exit(0 if any(pat.match(n) for n in names) else 1)
PYEOF
fi

# -- CI wiring ---------------------------------------------------------------
ci_yml=".github/workflows/ci.yml"
[ -f "$ci_yml" ] || fail "$ci_yml does not exist"
if [ -f "$ci_yml" ]; then
  grep -q 'boot-image-proof' "$ci_yml" ||
    fail "$ci_yml does not reference boot-image-proof (the CI build step is missing)"
  grep -qi 'qemu' "$ci_yml" ||
    fail "$ci_yml does not install/reference qemu (the e2e harness needs qemu-system-x86_64)"
  grep -q 'sandbox relaxed' "$ci_yml" ||
    fail "$ci_yml's boot job does not request --option sandbox relaxed (needed transitively via runInUbuntuBase, same as stdenv-proof/archive-fetch-proof/compose-proof)"
fi

# The purity guard must still hold with nix/boot.nix in the tree -- mirrors
# tests/unit/030/041/060's own final check.
purity_test="tests/unit/021-flake-purity.sh"
if [ -x "$purity_test" ]; then
  "$purity_test" || fail "$purity_test no longer passes with nix/boot.nix in the tree"
else
  fail "$purity_test is missing or not executable"
fi

exit "$fails"
