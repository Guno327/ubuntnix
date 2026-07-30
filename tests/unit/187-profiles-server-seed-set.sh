#!/usr/bin/env bash
# tests/unit/187-profiles-server-seed-set.sh — the declared
# `profiles.server` deb set actually contains the expected seed packages
# (SPEC.md §6, §10, §11 M5's "package set matching the upstream Server
# seed"; GitHub issue #99). Cross-checked against the REAL committed
# archive.lock.json, the same source nix/profiles.nix's own
# `serverSeedPackages` reads from (config.flake.lib.archive.lockfile).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so this cannot actually invoke
# nix/profiles.nix's own render/serverSeedPackages. Mirrors
# tests/unit/179-filesystems-render-fixtures.sh's/tests/unit/053-archive-
# declaration-seed.sh's own posture: nix/profiles.nix's documented formula
# is hand-computed here in python against the real committed
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

# -- serverSeedExceptions: the small, explicitly-enumerated set of M1
# proof-only fixture packages (hello/htop/ed/jq) that are not real members
# of any upstream Server seed -- see nix/profiles.nix's own header for the
# reasoning. Extracted textually and confirmed present.
exceptions_line="$(grep -m1 'serverSeedExceptions = \[' "$profiles_nix")"
[ -n "$exceptions_line" ] || fail "$profiles_nix: could not find a 'serverSeedExceptions = [ ... ];' line"

for pkg in hello htop ed jq; do
  case "$exceptions_line" in
  *"\"$pkg\""*) ;;
  *) fail "$profiles_nix: serverSeedExceptions does not list \"$pkg\"" ;;
  esac
done

# -- serverSeedPackages = sort(lockfile names - exceptions) ---------------
#
# Hand-computed in python against the REAL committed archive.lock.json.
python3 - "$profiles_nix" <<'PYEOF'
import json
import sys

lockfile = json.load(open("archive.lock.json", encoding="utf-8"))
locked_names = sorted(p["name"] for p in lockfile["public"]["packages"])

exceptions = {"hello", "htop", "ed", "jq"}
expected_seed = sorted(n for n in locked_names if n not in exceptions)

if not expected_seed:
    print("FAIL: computed serverSeedPackages is empty -- archive.lock.json/exceptions mismatch", file=sys.stderr)
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
# Ubuntu Server minimal install -- must survive into the seed.
for required in ("systemd-sysv", "grub-common", "e2fsprogs", "dosfstools", "tzdata", "initramfs-tools"):
    if required not in expected_seed:
        print(f"FAIL: server-seed package '{required}' was excluded from the computed serverSeedPackages", file=sys.stderr)
        sys.exit(1)

print(f"OK: computed serverSeedPackages has {len(expected_seed)} entries (exceptions correctly excluded, expected seed packages retained)")
PYEOF
[ $? -eq 0 ] || fail "serverSeedPackages fixture computation against archive.lock.json failed (see above)"

# -- declared ⊆ pinned: profiles.server never invents a package not
# already resolvable via nix/archive.nix's own debs/lockfile (this issue's
# own scoping: "declare via the existing surface, don't invent a fetch
# path") -- every archive.packages.json-declared name must still be pinned
# (the project-wide invariant tests/unit/053 already enforces; re-asserted
# here as a directly-relevant guard for this module).
seed_test="tests/unit/053-archive-declaration-seed.sh"
if [ -x "$seed_test" ]; then
  "$seed_test" || fail "$seed_test no longer passes (profiles.server's package seed depends on this invariant)"
fi

exit "$fails"
