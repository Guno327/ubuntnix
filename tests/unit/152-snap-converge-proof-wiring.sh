#!/usr/bin/env bash
# tests/unit/152-snap-converge-proof-wiring.sh — nix/boot.nix's
# snap-converge-proof section: static wiring checks (SPEC.md §11 M3 exit
# criterion; GitHub issue #64). Mirrors tests/unit/071-boot-flake-wiring.sh's
# relationship to nix/boot.nix's M1 section, one level up the milestone.
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same standing caveat), so nothing here can actually
# evaluate or build the flake -- that's CI-only (a "snap-convergence" job in
# .github/workflows/ci.yml building `.#snap-converge-proof`, and
# tests/e2e/030-qemu-snap-e2e.sh). This test is a machine-checked textual
# guard instead: it confirms the new proof is wired into nix/boot.nix, pulls
# nix/snap.nix's real compileManifest/snaps under the names that file
# actually exposes, exposes a real `packages.snap-converge-proof` flake
# output, bakes the real vendored hello-world payload/assertion (not
# synthetic bytes), documents the snapd-mutation seam as simulated, and that
# CI builds/asserts the proof and runs the e2e harness.
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

# -- pulls nix/snap.nix's real compiler/fetchers under the names that file
#    actually exposes (cross-check, mirrors 071's own "catches a rename on
#    one side" posture). ----------------------------------------------------
grep -qE 'inherit\s*\(config\.flake\.lib\.snap\)\s*compileManifest\s+snaps' "$boot_nix" ||
  fail "$boot_nix does not pull compileManifest/snaps from config.flake.lib.snap"
grep -q 'flake.lib.snap' nix/snap.nix ||
  fail "nix/snap.nix no longer exposes flake.lib.snap (boot.nix's snap-converge-proof depends on it)"
grep -qE '\bcompileManifest\s*=' nix/snap.nix ||
  fail "nix/snap.nix no longer defines compileManifest (boot.nix's snap-converge-proof depends on it)"

# -- the new flake output proof itself --------------------------------------
grep -q 'packages.snap-converge-proof' "$boot_nix" ||
  fail "$boot_nix does not declare packages.snap-converge-proof"

# -- reuses the ALREADY-VENDORED hello-world pin, not a synthetic/new one --
grep -q 'snaps\.hello-world\.snap' "$boot_nix" ||
  fail "$boot_nix's snap-converge-proof does not reference the real snaps.hello-world.snap fetch"
grep -qE 'snaps\.hello-world\."assert"' "$boot_nix" ||
  fail "$boot_nix's snap-converge-proof does not reference the real snaps.hello-world.\"assert\" fetch"

# -- the declared entry must actually pin revision 29 (snaps.lock.json's
#    committed hello-world pin) -- a drifted revision here would silently
#    stop cross-referencing against the real lockfile. ---------------------
grep -q 'revision = 29;' "$boot_nix" ||
  fail "$boot_nix's snap-converge-proof does not declare hello-world at its committed pinned revision (29)"

lockfile="snaps.lock.json"
[ -f "$lockfile" ] || fail "$lockfile does not exist"
if [ -f "$lockfile" ]; then
  python3 - "$lockfile" <<'PYEOF' || fail "snaps.lock.json's hello-world entry is not pinned at revision 29 (nix/boot.nix's snap-converge-proof assumes it is)"
import json, sys
data = json.load(open(sys.argv[1]))
entries = {e.get("name"): e for e in data.get("snaps", [])}
sys.exit(0 if entries.get("hello-world", {}).get("revision") == 29 else 1)
PYEOF
  vendored="snaps/assertions/hello-world_29.snap-declaration"
  [ -f "$vendored" ] || fail "$vendored does not exist -- nix/boot.nix's snap-converge-proof (fetchAssert) depends on it"
fi

# -- the injectable seams: real bin/ubx-snap-apply/bin/ubx-snap-purge seam
#    names must be referenced by name (regression guard: a rename in either
#    script silently breaks this proof's own simulator wiring). ------------
for seam in UBX_SNAP_CMD UBX_SNAP_BIN; do
  grep -q "$seam" "$boot_nix" ||
    fail "$boot_nix's snap-converge-proof does not reference the injectable seam $seam"
done
grep -q 'ubx-snap-sim' "$boot_nix" ||
  fail "$boot_nix's snap-converge-proof does not bake its own simulated snapd backend (ubx-snap-sim)"

# -- the three markers this proof's own driver must emit, and the harness
#    that scrapes them for real. --------------------------------------------
for marker in UBX-M3-S1-PASS UBX-M3-S2-PASS UBX-M3-S3-PASS; do
  grep -qF "$marker" "$boot_nix" ||
    fail "$boot_nix's snap-converge-proof does not emit the $marker marker"
done

harness="tests/e2e/030-qemu-snap-e2e.sh"
[ -x "$harness" ] || fail "$harness does not exist or is not executable"
if [ -f "$harness" ]; then
  for marker in UBX-M3-S1-PASS UBX-M3-S2-PASS UBX-M3-S3-PASS; do
    grep -qF "$marker" "$harness" ||
      fail "$harness does not reference $marker"
  done
fi

# -- the real bin/ubx-guard-snap drift-block decision (scenario 2's own
#    interactive-install-blocked half) must be exercised, not skipped. -----
grep -q 'ubx-guard-snap' "$boot_nix" ||
  fail "$boot_nix's snap-converge-proof does not install the real ubx-guard-snap diversion"

# -- CI wiring ---------------------------------------------------------------
ci_yml=".github/workflows/ci.yml"
[ -f "$ci_yml" ] || fail "$ci_yml does not exist"
if [ -f "$ci_yml" ]; then
  grep -q 'snap-converge-proof' "$ci_yml" ||
    fail "$ci_yml does not reference snap-converge-proof (the CI build step is missing)"
  grep -q '030-qemu-snap-e2e.sh' "$ci_yml" ||
    fail "$ci_yml does not run tests/e2e/030-qemu-snap-e2e.sh"
  grep -q 'sandbox relaxed' "$ci_yml" ||
    fail "$ci_yml does not request --option sandbox relaxed anywhere (needed transitively via runInUbuntuBase)"
fi

# The purity guard must still hold with this section in the tree -- mirrors
# tests/unit/071's own final check.
purity_test="tests/unit/021-flake-purity.sh"
if [ -x "$purity_test" ]; then
  "$purity_test" || fail "$purity_test no longer passes with nix/boot.nix's snap-converge-proof in the tree"
else
  fail "$purity_test is missing or not executable"
fi

exit "$fails"
