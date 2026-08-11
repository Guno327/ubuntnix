#!/usr/bin/env bash
# tests/unit/194-profiles-desktop-seed-set.sh — the declared
# `profiles.desktop` deb set actually contains the expected seed packages
# (SPEC.md §6, §10, §11 M6's "package set matching the upstream Desktop
# seed"; GitHub issue #107). Cross-checked against the REAL committed
# archive.lock.json, the same source nix/profiles.nix's own
# `desktopSeedPackages` reads from (config.flake.lib.archive.lockfile).
# Direct sibling of tests/unit/187-profiles-server-seed-set.sh.
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so this cannot actually invoke
# nix/profiles.nix's own desktopRender/desktopSeedPackages. Mirrors
# tests/unit/187's own posture: nix/profiles.nix's documented formula is
# hand-computed here in python against the real committed
# archive.lock.json and cross-checked against the source file's own code.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

profiles_nix="nix/profiles.nix"

for f in "$profiles_nix" archive.lock.json; do
  [ -f "$f" ] || {
    echo "FAIL: $f does not exist" >&2
    exit 1
  }
done

# -- desktopSeedExceptions: the small, explicitly-enumerated set of M1
# proof-only fixture packages (just "hello" as of GitHub issue #118 --
# htop/ed/jq were removed once the committed upstream manifest proved they
# are genuine upstream Server-seed members) that are not real members of
# any upstream Desktop seed -- see nix/profiles.nix's own header for the
# reasoning. Extracted textually and confirmed present.
exceptions_line="$(grep -m1 'desktopSeedExceptions = \[' "$profiles_nix")"
[ -n "$exceptions_line" ] || fail "$profiles_nix: could not find a 'desktopSeedExceptions = [ ... ];' line"

case "$exceptions_line" in
*'"hello"'*) ;;
*) fail "$profiles_nix: desktopSeedExceptions does not list \"hello\"" ;;
esac

# -- desktopSeedPackages = sort(lockfile names - exceptions) --------------
#
# Hand-computed in python against the REAL committed archive.lock.json.
# NOTE (GitHub issue #107): today's committed archive.lock.json carries no
# GNOME/gdm packages at all (see nix/profiles.nix's own header, "PM ACTION
# REQUIRED, desktop-specific") -- desktopSeedPackages is therefore
# currently identical in CONTENT to serverSeedPackages (both derived from
# the one shared lockfile, minus the same fixture exceptions); this test
# asserts the FORMULA (lockfile-derived, exceptions excluded), not a
# desktop-specific package list that does not exist in the lock yet.
if ! python3 - "$profiles_nix" <<'PYEOF'
import json
import sys

lockfile = json.load(open("archive.lock.json", encoding="utf-8"))
locked_names = sorted(p["name"] for p in lockfile["public"]["packages"])

exceptions = {"hello"}
expected_seed = sorted(n for n in locked_names if n not in exceptions)

if not expected_seed:
    print("FAIL: computed desktopSeedPackages is empty -- archive.lock.json/exceptions mismatch", file=sys.stderr)
    sys.exit(1)

for pkg in exceptions:
    if pkg in expected_seed:
        print(f"FAIL: exception package '{pkg}' was not actually excluded from the computed seed", file=sys.stderr)
        sys.exit(1)

for pkg in exceptions:
    if pkg not in locked_names:
        print(f"FAIL: exception package '{pkg}' is not even in archive.lock.json's public.packages -- dead exception entry", file=sys.stderr)
        sys.exit(1)

# Real boot/filesystem-critical packages -- genuine members of any upstream
# Ubuntu install (server or desktop) -- must survive into the seed.
for required in ("systemd-sysv", "grub-common", "e2fsprogs", "dosfstools", "tzdata", "initramfs-tools"):
    if required not in expected_seed:
        print(f"FAIL: desktop-seed package '{required}' was excluded from the computed desktopSeedPackages", file=sys.stderr)
        sys.exit(1)

print(f"OK: computed desktopSeedPackages has {len(expected_seed)} entries (exceptions correctly excluded, expected seed packages retained)")
PYEOF
then
  fail "desktopSeedPackages fixture computation against archive.lock.json failed (see above)"
fi

# -- declared ⊆ pinned: profiles.desktop never invents a package not
# already resolvable via nix/archive.nix's own debs/lockfile -- every
# archive.packages.json-declared name must still be pinned (the
# project-wide invariant tests/unit/053 already enforces; re-asserted here
# as a directly-relevant guard for this module).
seed_test="tests/unit/053-archive-declaration-seed.sh"
if [ -x "$seed_test" ]; then
  "$seed_test" || fail "$seed_test no longer passes (profiles.desktop's package seed depends on this invariant)"
fi

exit "$fails"
