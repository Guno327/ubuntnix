#!/usr/bin/env bash
# tests/unit/189-archive-components-flake-wiring.sh — the declarative
# restricted/multiverse component toggle (SPEC.md §5; GitHub issue #106),
# static wiring checks.
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so nothing here can actually evaluate
# nix/archive.nix's `componentToggleType`/`effectiveComponents` -- that's
# CI-only, via `flake check --no-build` forcing `packages.archive-
# components-proof` (mirrors nix/pro.nix's own `pro-manifest-proof` role;
# see tests/unit/170-pro-flake-wiring.sh for the identical pattern this
# file follows). This is a machine-checked textual guard instead: it
# confirms nix/archive.nix declares the toggle type with both components
# defaulting OFF, exposes a pure list-computing function in the fixed
# main/universe/restricted/multiverse order bin/ubx-resolve's own
# VALID_COMPONENTS listing uses, is wired to flake.lib.archive and a real
# per-system proof derivation, and that bin/ubx-resolve's/
# archive.packages.json's own comments were updated to point at it (no
# stale "not expressible" claim left behind) -- plus that docs/archive.md
# documents the toggle and its esm-apps caveat.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

archive_nix="nix/archive.nix"
resolve="bin/ubx-resolve"
docs="docs/archive.md"

for f in "$archive_nix" "$resolve" "$docs"; do
  [ -f "$f" ] || {
    echo "FAIL: $f does not exist" >&2
    exit 1
  }
done

# -- the toggle type must exist, be a real submodule, and default both
# fields to false (SPEC.md §5's "default off" posture).
grep -q 'componentToggleType' "$archive_nix" ||
  fail "$archive_nix does not define componentToggleType"
grep -qE 'componentToggleType\s*=\s*lib\.types\.submodule' "$archive_nix" ||
  fail "$archive_nix's componentToggleType is not a lib.types.submodule"

# Both restricted/multiverse options must default to false. Scan the
# submodule block for each option name immediately followed (within a few
# lines) by 'default = false;'.
python3 - "$archive_nix" <<'PYEOF'
import re
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()

m = re.search(r"componentToggleType\s*=\s*lib\.types\.submodule\s*\{(.*?)\n  \};", text, re.DOTALL)
if not m:
    print("FAIL: could not locate componentToggleType's submodule body")
    sys.exit(1)
body = m.group(1)

for name in ("restricted", "multiverse"):
    opt_m = re.search(rf"{name}\s*=\s*lib\.mkOption\s*\{{(.*?)\n      \}};", body, re.DOTALL)
    if not opt_m:
        print(f"FAIL: componentToggleType does not declare '{name}' as an mkOption")
        sys.exit(1)
    opt_body = opt_m.group(1)
    if not re.search(r"default\s*=\s*false\s*;", opt_body):
        print(f"FAIL: componentToggleType.{name} does not default to false")
        sys.exit(1)
    if "lib.types.bool" not in opt_body:
        print(f"FAIL: componentToggleType.{name} is not typed lib.types.bool")
        sys.exit(1)
sys.exit(0)
PYEOF
py_rc=$?
[ "$py_rc" -eq 0 ] || fail "componentToggleType default/type check failed (see output above)"

# -- effectiveComponents must exist and encode the fixed
# main/universe/restricted/multiverse order (bin/ubx-resolve's own
# VALID_COMPONENTS listing order), with main+universe unconditional and
# restricted/multiverse gated on the toggle.
grep -q 'effectiveComponents' "$archive_nix" ||
  fail "$archive_nix does not define effectiveComponents"
grep -qE '\[\s*"main"\s*"universe"\s*\]' "$archive_nix" ||
  fail "$archive_nix's effectiveComponents does not start from an unconditional [ \"main\" \"universe\" ]"
grep -q 'lib.optional toggle.restricted "restricted"' "$archive_nix" ||
  fail "$archive_nix's effectiveComponents does not gate \"restricted\" on toggle.restricted"
grep -q 'lib.optional toggle.multiverse "multiverse"' "$archive_nix" ||
  fail "$archive_nix's effectiveComponents does not gate \"multiverse\" on toggle.multiverse"

# -- evalComponentToggle must run the declared attrset through the real
# module system (lib.evalModules), mirroring nix/pro.nix's/
# nix/networking.nix's own evalDeclared shape, not a hand-rolled merge.
grep -q 'evalComponentToggle' "$archive_nix" ||
  fail "$archive_nix does not define evalComponentToggle"
grep -q 'lib.evalModules' "$archive_nix" ||
  fail "$archive_nix's evalComponentToggle does not use lib.evalModules"

# -- exposed under flake.lib.archive, alongside everything else that file
# contributes.
grep -qE 'inherit componentToggleType evalComponentToggle effectiveComponents' "$archive_nix" ||
  fail "$archive_nix does not expose componentToggleType/evalComponentToggle/effectiveComponents under flake.lib.archive"

# -- a real per-system proof derivation forces evaluation under CI's
# `flake check --no-build` (mirrors packages.pro-manifest-proof/
# packages.networking-proof).
grep -q 'packages.archive-components-proof' "$archive_nix" ||
  fail "$archive_nix does not declare packages.archive-components-proof"

# -- no forbidden nixpkgs-package-set patterns introduced by this addition
# (mirrors tests/unit/170's/tests/unit/180's own guard; word-boundary
# \bpkgs\. rather than tests/unit/041's older bare pkgs\.[a-zA-Z], which
# would false-positive on this file's now-legitimate `inputs.nixpkgs.lib`).
if grep -nE '\bpkgs\.|mkDerivation|buildInputs|fetchFromGitHub' "$archive_nix" >/dev/null 2>&1; then
  fail "$archive_nix references a forbidden nixpkgs-package-set pattern"
fi

# -- the function head must bring in `inputs` (needed for `inputs.nixpkgs.lib`
# -- componentToggleType/effectiveComponents both need `lib`, which this
# file did not import before issue #106).
grep -qE '^\{ config, inputs, \.\.\. \}:' "$archive_nix" ||
  fail "$archive_nix's function head does not destructure 'inputs' (needed for lib.types/lib.mkOption/lib.evalModules)"

# -- bin/ubx-resolve's/archive.packages.json's comments must no longer
# claim the toggle is "not expressible" -- that claim is now false.
if grep -q 'not expressible here yet' "$resolve"; then
  fail "$resolve still claims the restricted/multiverse toggle is 'not expressible here yet'"
fi
if grep -q 'not expressible here yet' archive.packages.json; then
  fail "archive.packages.json still claims the restricted/multiverse toggle is 'not expressible here yet'"
fi
grep -q 'issue #106' "$resolve" ||
  fail "$resolve's header does not reference GitHub issue #106"

# -- docs/archive.md documents the toggle and the esm-apps caveat (SPEC.md
# §5: esm-apps coverage does not extend to restricted/multiverse).
grep -qi 'restricted' "$docs" || fail "$docs does not mention 'restricted'"
grep -qi 'multiverse' "$docs" || fail "$docs does not mention 'multiverse'"
grep -qi 'esm-apps' "$docs" || fail "$docs does not mention esm-apps"
grep -qE 'ubuntnix\.archive\.components' "$docs" ||
  fail "$docs does not document the ubuntnix.archive.components option"

exit "$fails"
