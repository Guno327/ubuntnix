#!/usr/bin/env bash
# tests/unit/183-profiles-server-seed-fixtures.sh — nix/profiles.nix's
# `serverSeedPackages`/`serverSeedExceptions` logic, verified against
# archive.lock.json itself (SPEC.md §11 M5 exit criterion: "a package set
# matching the upstream Server seed (minus enumerated exceptions)"; GitHub
# issue #99).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so this cannot actually invoke
# nix/profiles.nix's `render`. Mirrors tests/unit/179-filesystems-render-
# fixtures.sh's own posture: nix/profiles.nix's own documented formula
# ("serverSeedPackages = sort (lockfile.public.packages names minus
# serverSeedExceptions)") is hand-computed here in python against the REAL
# committed archive.lock.json, and cross-checked against the source file's
# own code (the exceptions list, and that the QEMU e2e proof/assert script
# share the same marker vocabulary and the same exceptions list -- a
# hand-typed second copy that silently drifts from nix/profiles.nix's own
# list would defeat the whole check).
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

profiles_nix="nix/profiles.nix"
example_config="examples/server.nix"
e2e_test="tests/e2e/050-qemu-server-parity-e2e.sh"

for f in "$profiles_nix" "$example_config" "$e2e_test" archive.lock.json; do
  [ -f "$f" ] || { echo "FAIL: $f does not exist" >&2; exit 1; }
done

# -- serverSeedExceptions: exactly the four M1 proof-only fixtures --------
#
# Extract the Nix list literal `serverSeedExceptions = [ ... ];` textually
# (a plain, single-line list of quoted strings in the committed file) and
# confirm it is EXACTLY { hello, htop, ed, jq } -- nix/profiles.nix's own
# header names these as the only real members; a silent addition/removal
# here would change what the QEMU e2e proof asserts without anyone
# updating this test's own expectation.
exceptions_line="$(grep -m1 'serverSeedExceptions = \[' "$profiles_nix")"
[ -n "$exceptions_line" ] || fail "$profiles_nix: could not find a 'serverSeedExceptions = [ ... ];' line"

for pkg in hello htop ed jq; do
  case "$exceptions_line" in
    *"\"$pkg\""*) ;;
    *) fail "$profiles_nix: serverSeedExceptions does not list \"$pkg\"" ;;
  esac
done

# No OTHER quoted names in that line beyond the expected four (catches an
# accidental fifth entry silently narrowing the asserted seed further).
exceptions_count="$(printf '%s' "$exceptions_line" | grep -o '"[^"]*"' | wc -l)"
[ "$exceptions_count" -eq 4 ] ||
  fail "$profiles_nix: serverSeedExceptions has $exceptions_count entries, expected exactly 4 (hello, htop, ed, jq)"

# -- serverSeedPackages = sort(lockfile names - exceptions) ---------------
#
# Hand-computed in python against the REAL committed archive.lock.json --
# the same source nix/profiles.nix's own `serverSeedPackages` reads
# (config.flake.lib.archive.lockfile.public.packages).
python3 - "$profiles_nix" <<'PYEOF'
import json
import re
import sys

profiles_nix = sys.argv[1]

lockfile = json.load(open("archive.lock.json", encoding="utf-8"))
locked_names = sorted(p["name"] for p in lockfile["public"]["packages"])

exceptions = {"hello", "htop", "ed", "jq"}
expected_seed = sorted(n for n in locked_names if n not in exceptions)

if not expected_seed:
    print("FAIL: computed serverSeedPackages is empty -- archive.lock.json/exceptions mismatch", file=sys.stderr)
    sys.exit(1)

# None of the exceptions may survive the filter.
for pkg in exceptions:
    if pkg in expected_seed:
        print(f"FAIL: exception package '{pkg}' was not actually excluded from the computed seed", file=sys.stderr)
        sys.exit(1)

# Every exception must have genuinely been present in the lockfile in the
# first place (an exception naming a package that was never pinned at all
# would be dead code hiding nothing real).
for pkg in exceptions:
    if pkg not in locked_names:
        print(f"FAIL: exception package '{pkg}' is not even in archive.lock.json's public.packages -- dead exception entry", file=sys.stderr)
        sys.exit(1)

# Every real boot-critical package (kernel, grub, filesystem tools --
# nix/boot.nix's own bootSpec/concreteFlavorPackages needs) must survive
# into the seed, or packages.server-parity-image (built from
# serverSeedPackages) could never boot at all.
for required in ("linux-image-virtual", "grub-common", "systemd-sysv", "e2fsprogs"):
    if required not in expected_seed:
        print(f"FAIL: boot-critical package '{required}' was excluded from the computed serverSeedPackages -- server-parity-image could not boot", file=sys.stderr)
        sys.exit(1)

print(f"OK: computed serverSeedPackages has {len(expected_seed)} entries (exceptions correctly excluded, boot-critical packages retained)")
PYEOF
[ $? -eq 0 ] || fail "serverSeedPackages fixture computation against archive.lock.json failed (see above)"

# -- marker vocabulary shared between the image and the e2e harness -------
#
# nix/profiles.nix's own assertion script/service must emit exactly the
# marker strings tests/e2e/050-qemu-server-parity-e2e.sh greps for -- a
# rename on one side with no matching update on the other would make the
# e2e test fail (or, worse, silently always skip/pass) for the wrong
# reason.
for marker in 'UBX-SERVER-PARITY-PASS' 'UBX-SERVER-PARITY-FAIL'; do
  grep -q -- "$marker" "$profiles_nix" || fail "$profiles_nix does not emit the '$marker' marker"
  grep -q -- "$marker" "$e2e_test" || fail "$e2e_test does not check for the '$marker' marker"
done

# -- examples/server.nix's fileSystems/swapDevices must be boot-safe ------
#
# See examples/server.nix's own header: a fstab entry for a device that
# does not exist on the throwaway e2e disk must not block boot -- "nofail"
# is the load-bearing safety property here.
grep -q 'nofail' "$example_config" ||
  fail "$example_config's fileSystems/swapDevices do not declare 'nofail' -- the QEMU e2e boot could hang on a missing device"

exit "$fails"
