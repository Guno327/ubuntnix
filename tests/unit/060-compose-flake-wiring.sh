#!/usr/bin/env bash
# tests/unit/060-compose-flake-wiring.sh — rootfs composition, static wiring
# checks (SPEC.md §4.2/§11 M1; GitHub issue #9).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so nothing here can actually evaluate or
# build the flake — that's CI-only (the "compose" job in
# .github/workflows/ci.yml, which builds `.#compose-proof`,
# `.#compose-preseed-proof`, and `.#compose-image-proof` and asserts on
# their output). This test is a machine-checked textual guard instead,
# mirroring tests/unit/030-stdenv-flake-wiring.sh and
# tests/unit/041-archive-flake-wiring.sh: it confirms nix/compose.nix
# exists, is imported by flake.nix, reaches the stdenv/archive libraries
# under the names those files actually expose, exposes its own
# flake.lib.compose, is wired to real per-system proof packages, that every
# package name it references is actually pinned in archive.lock.json, and
# that CI builds/asserts all three proofs plus the determinism comparison.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

compose_nix="nix/compose.nix"

[ -f "$compose_nix" ] || {
  echo "FAIL: $compose_nix does not exist" >&2
  exit 1
}

# flake.nix must actually import the dendritic module (SPEC.md §2 G8).
grep -q '\./nix/compose\.nix' flake.nix ||
  fail "flake.nix does not import ./nix/compose.nix"

# It must reach the stdenv/archive builder abstractions under the EXACT
# names those files expose (nix/stdenv.nix's flake.lib.stdenv.runInUbuntuBase,
# nix/archive.nix's flake.lib.archive.debs) — not some renamed/reinvented
# equivalent.
grep -qE 'inherit\s*\(config\.flake\.lib\.stdenv\)\s*runInUbuntuBase' "$compose_nix" ||
  fail "$compose_nix does not pull runInUbuntuBase from config.flake.lib.stdenv"
grep -qE 'inherit\s*\(config\.flake\.lib\.archive\)\s*debs' "$compose_nix" ||
  fail "$compose_nix does not pull debs from config.flake.lib.archive"

# Cross-check: the names it pulls out must actually be things nix/stdenv.nix
# and nix/archive.nix declare under flake.lib -- catches a rename on one
# side that the other wasn't updated for.
grep -q 'flake.lib.stdenv' nix/stdenv.nix ||
  fail "nix/stdenv.nix no longer exposes flake.lib.stdenv (compose.nix depends on it)"
grep -qE 'runInUbuntuBase\s*=' nix/stdenv.nix ||
  fail "nix/stdenv.nix no longer defines runInUbuntuBase (compose.nix depends on it)"
grep -q 'flake.lib.archive' nix/archive.nix ||
  fail "nix/archive.nix no longer exposes flake.lib.archive (compose.nix depends on it)"
grep -qE '\bdebs\s*=' nix/archive.nix ||
  fail "nix/archive.nix no longer defines debs (compose.nix depends on it)"

# This file's own library contribution (issue #9 task items 1-3): every
# advertised function must actually be defined AND actually exposed under
# flake.lib.compose, following the same contribution pattern nix/stdenv.nix
# and nix/archive.nix use.
grep -q 'flake.lib.compose' "$compose_nix" ||
  fail "$compose_nix does not expose flake.lib.compose"

for fn in renderPreseed composeRootfs toolsFHS squashfsImage; do
  grep -qE "^\s*${fn}\s*=" "$compose_nix" ||
    fail "$compose_nix does not define $fn"
  grep -qE "inherit[^;]*\b${fn}\b[^;]*;" "$compose_nix" ||
    fail "$compose_nix defines $fn but does not expose it under flake.lib.compose"
done

# perSystem wiring for the three proof derivations the issue's task list
# calls for.
grep -q 'systems = \[ "x86_64-linux" \]' "$compose_nix" ||
  fail "$compose_nix does not declare systems = [ \"x86_64-linux\" ]"
for pkg in compose-proof compose-preseed-proof compose-image-proof; do
  grep -q "packages.${pkg}" "$compose_nix" ||
    fail "$compose_nix does not declare packages.${pkg}"
done

# The preseed proof must actually preseed something (SPEC.md §6's
# ubuntnix.debconf shape) and it must be tzdata -> America/New_York, the
# exact effect CI is expected to assert on (not tzdata's own Etc/UTC
# fallback, so a match can only come from the preseed actually reaching the
# maintainer script).
grep -q 'preseed = {' "$compose_nix" ||
  fail "$compose_nix's compose-preseed-proof does not pass a preseed attrset"
grep -q '"tzdata/Areas" = "America"' "$compose_nix" ||
  fail "$compose_nix's compose-preseed-proof does not preseed tzdata/Areas = America"
grep -q '"tzdata/Zones/America" = "New_York"' "$compose_nix" ||
  fail "$compose_nix's compose-preseed-proof does not preseed tzdata/Zones/America = New_York"

# -- lockfile cross-check ---------------------------------------------------
#
# Every package name composeRootfs/toolsFHS is asked to compose (in this
# file's own perSystem proofs, and inside squashfsImage's own toolsFHS call)
# MUST already exist in archive.lock.json's public.packages -- composeRootfs
# itself throws at eval time otherwise, but that eval-time throw is exactly
# what this harness can't exercise (no `nix`), so check the same invariant
# statically instead.
lockfile="archive.lock.json"
[ -f "$lockfile" ] || fail "$lockfile does not exist"

if [ -f "$lockfile" ]; then
  # Collect every quoted package name compose.nix references as a `packages
  # = [ ... ]` list element, across composeProof/composePreseedProof and
  # squashfsImage's own hardcoded toolsFHS call. This is a static text
  # extraction (this harness has no Nix evaluator), scoped to quoted
  # identifiers immediately inside a `packages = [ ... ]`-shaped list so it
  # doesn't false-positive on unrelated quoted strings elsewhere in the
  # file.
  mapfile -t referenced < <(
    grep -oE 'packages = \[[^]]*\]' "$compose_nix" |
      grep -oE '"[a-z0-9][a-z0-9+.-]*"' |
      tr -d '"' |
      sort -u
  )

  [ "${#referenced[@]}" -gt 0 ] ||
    fail "could not statically extract any package name from $compose_nix's packages = [ ... ] lists — extraction pattern may have drifted from the source"

  for pkg in "${referenced[@]}"; do
    python3 - "$lockfile" "$pkg" <<'PYEOF' || fail "package '$pkg' referenced in $compose_nix is not pinned in $lockfile"
import json, sys
lockfile, pkg = sys.argv[1], sys.argv[2]
data = json.load(open(lockfile))
names = {p.get("name") for p in data.get("public", {}).get("packages", [])}
sys.exit(0 if pkg in names else 1)
PYEOF
  done

  # The two specific issue-#9 additions (documented in archive.lock.json's
  # own _comment fields) must be present by name, not just structurally.
  for pkg in tzdata squashfs-tools liblzo2-2; do
    printf '%s\n' "${referenced[@]}" | grep -qx "$pkg" ||
      fail "$compose_nix no longer references '$pkg', but archive.lock.json still carries it for issue #9 -- check both stay in sync"
  done
fi

# -- hardening / determinism markers ---------------------------------------
#
# The chroot hardening (issue #9's whole reason for existing, per
# nix/stdenv.nix's own HARDENING NOTE) and the R1 determinism normalizations
# this file's header documents must actually be present in the script text,
# not just described in comments.
grep -q -- '--user --map-root-user --mount --pid --fork' "$compose_nix" ||
  fail "$compose_nix does not construct the hardened unshare/chroot sandbox described in its own header"
grep -qE '\bchroot\b' "$compose_nix" ||
  fail "$compose_nix does not chroot into the composed tree"
grep -q 'dpkg --unpack' "$compose_nix" ||
  fail "$compose_nix does not dpkg --unpack declared packages"
grep -q 'dpkg --configure' "$compose_nix" ||
  fail "$compose_nix does not dpkg --configure the unpacked packages"
grep -q -- '-mkfs-time 0' "$compose_nix" ||
  fail "$compose_nix's squashfsImage does not normalize mkfs-time for determinism"
grep -q -- '-all-time 0' "$compose_nix" ||
  fail "$compose_nix's squashfsImage does not normalize all-time for determinism"
grep -q -- '-processors 1' "$compose_nix" ||
  fail "$compose_nix's squashfsImage does not pin mksquashfs to a single processor (documented determinism requirement)"
grep -q 'touch.*-d @0' "$compose_nix" ||
  fail "$compose_nix does not reset mtimes to the epoch for cross-build comparability"

# -- CI wiring ---------------------------------------------------------------
ci_yml=".github/workflows/ci.yml"
[ -f "$ci_yml" ] || fail "$ci_yml does not exist"
if [ -f "$ci_yml" ]; then
  for pkg in compose-proof compose-preseed-proof compose-image-proof; do
    grep -q "$pkg" "$ci_yml" ||
      fail "$ci_yml does not reference $pkg (the CI build/assert step is missing)"
  done
  grep -qi 'america/new_york' "$ci_yml" ||
    fail "$ci_yml does not assert the tzdata preseed effect (America/New_York)"
  grep -qiE 'dpkg.*(consisten|status)|status.*dpkg' "$ci_yml" ||
    fail "$ci_yml does not assert dpkg database consistency"
  grep -qiE -- '--rebuild|two-run|determinis' "$ci_yml" ||
    fail "$ci_yml does not run the two-run determinism comparison the issue requires"
  grep -q 'sandbox relaxed' "$ci_yml" ||
    fail "$ci_yml's compose job does not request --option sandbox relaxed (needed transitively via runInUbuntuBase, same as stdenv-proof/archive-fetch-proof)"
fi

# The purity guard must still hold with nix/compose.nix in the tree —
# mirrors tests/unit/030 and 041's own final check.
purity_test="tests/unit/021-flake-purity.sh"
if [ -x "$purity_test" ]; then
  "$purity_test" || fail "$purity_test no longer passes with nix/compose.nix in the tree"
else
  fail "$purity_test is missing or not executable"
fi

exit "$fails"
