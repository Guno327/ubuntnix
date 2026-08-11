#!/usr/bin/env bash
# tests/unit/210-upstream-manifest-parity.sh — diff ubuntnix's declared
# seed closure against the REAL upstream Ubuntu release manifests
# (SPEC.md §12 R11, §11 M7; GitHub issue #118).
#
# The M1–M6 parity harnesses (050/070 e2e, 187/194 seed-set) verify our
# seed against the project's OWN committed archive.lock.json and a small
# hand-typed list of boot-critical "required" names, because — as every one
# of their headers notes — the dev/CI sandbox had "no network access to
# fetch a live upstream Ubuntu ISO manifest." That gap is now closed: the
# authoritative upstream package inventories are committed verbatim under
# tests/fixtures/upstream-manifests/ (Canonical's published `.manifest`
# files, SHA-256-pinned; see that dir's README). This test diffs our
# declared seed against them — reproducibly, with no network dependency.
#
# -- What relationship is checked, and why it is a SUBSET check ------------
#
# nix/profiles.nix's own header establishes the contract "declared ⊆
# archive.lock.json": our locked closure is the minimal, mutually-proven
# base set (171 pkgs) plus a few stdenv/tooling fixtures — it is NOT the
# full upstream Server/Desktop task-set. Extending the profiles to the full
# upstream seed (so that upstream ⊆ ours) is a product-scope decision that
# is deliberately owner-gated (#118). What this test CAN assert without
# that decision, and what R11 fundamentally requires, is the OTHER
# direction: every package ubuntnix declares must be a genuine member of
# the upstream release — with the sole, explicitly-enumerated exception of
# ubuntnix's own additions (the `nix` closure and build/image tooling,
# which by design are not in stock Ubuntu). Any declared package that is
# neither in the upstream manifest nor in that documented additions list is
# an unexplained divergence and fails CI.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

fixtures_dir="tests/fixtures/upstream-manifests"
server_manifest="$fixtures_dir/ubuntu-24.04.3-live-server-amd64.manifest"
desktop_manifest="$fixtures_dir/ubuntu-24.04.3-desktop-amd64.manifest"
profiles_nix="nix/profiles.nix"

for f in "$server_manifest" "$desktop_manifest" archive.lock.json "$profiles_nix"; do
  [ -f "$f" ] || {
    echo "FAIL: required input '$f' does not exist" >&2
    exit 1
  }
done

# The exception set is hand-mirrored from nix/profiles.nix's
# serverSeedExceptions/desktopSeedExceptions (identical: [hello] — this
# used to also include htop/ed/jq, but GitHub issue #118's reconciliation
# against the very upstream manifests this test reads proved those three
# ARE real upstream Server-seed members, and excluding "ed" was actively
# breaking ubuntu-standard's dpkg configuration once that metapackage was
# declared, so nix/profiles.nix dropped them from both exception lists).
# Confirm the source still agrees so this test can't silently drift from it.
for excl_var in serverSeedExceptions desktopSeedExceptions; do
  line="$(grep -m1 "$excl_var = \[" "$profiles_nix")" || true
  [ -n "$line" ] || fail "$profiles_nix: could not find '$excl_var = [ ... ];'"
  case "$line" in
  *'"hello"'*) ;;
  *) fail "$profiles_nix: $excl_var no longer lists \"hello\" — update this test's exception set to match" ;;
  esac
  case "$line" in
  *htop* | *'"ed"'* | *'"jq"'*)
    fail "$profiles_nix: $excl_var still lists htop/ed/jq — update this test's exception set to match (they are real upstream packages per GitHub issue #118, not exceptions)"
    ;;
  esac
done

if ! python3 - "$server_manifest" "$desktop_manifest" <<'PYEOF'
import hashlib
import json
import sys

server_manifest, desktop_manifest = sys.argv[1], sys.argv[2]

rc = 0


def problem(msg):
    global rc
    print(f"FAIL: {msg}", file=sys.stderr)
    rc = 1


# -- 1. Fixture integrity: the committed manifests must be byte-for-byte the
#       pinned upstream artifacts. A drifted/edited fixture invalidates every
#       parity claim below, so it is a hard failure (see the fixtures README).
PINS = {
    server_manifest: "a530142e61ad1cc73b3845d20ed65bdb8d0ff2ca18b71a6250d10981069a5c67",
    desktop_manifest: "d4265ebd3bd7d2679ef050761d0fa60b3f77e1e1e7d809ab01c8c190c742ed0b",
}
for path, want in PINS.items():
    with open(path, "rb") as fh:
        got = hashlib.sha256(fh.read()).hexdigest()
    if got != want:
        problem(f"{path}: SHA-256 {got} != pinned {want} (fixture drift)")


def upstream_names(path):
    """Parse an Ubuntu `.manifest` (`<pkg>\\t<version>` lines) into the set of
    binary package names, stripping any `:arch` multiarch suffix."""
    names = set()
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line:
                continue
            name = line.split("\t", 1)[0].split(":", 1)[0]
            if name:
                names.add(name)
    return names


# -- ubuntnix-specific additions: packages ubuntnix declares that are, by
#    design, NOT part of a stock Ubuntu release and so legitimately absent
#    from the upstream manifest. Enumerated explicitly so any *new*, un-
#    accounted-for divergence fails instead of hiding here. Categories:
#      * the `nix` runtime itself and its transitive C/Perl deps
#      * fakeroot + initramfs/image build tooling
#    Kernel packages are pinned to a concrete ABI (e.g.
#    linux-image-6.8.0-134-generic) that never equals upstream's metapackage
#    name, so they are matched by prefix rather than exact name.
ADDITIONS_EXACT = {
    # nix runtime + its closure's transitive deps
    "nix-bin",
    "libboost-context1.83.0",
    "libcpuid16",
    "libdbd-sqlite3-perl",
    "libdbi-perl",
    "libgc1",
    "liblowdown1",
    "libwww-curl-perl",
    # build / initramfs / image tooling
    "fakeroot",
    "libfakeroot",
    "bash-static",
    "bzip2",
    "mtools",
}
ADDITIONS_PREFIX = ("linux-image-", "linux-modules-")


def is_addition(name):
    return name in ADDITIONS_EXACT or name.startswith(ADDITIONS_PREFIX)


# -- declared seed = sorted(lockfile public package names) - exceptions,
#    exactly as nix/profiles.nix computes serverSeedPackages/desktopSeedPackages.
lockfile = json.load(open("archive.lock.json", encoding="utf-8"))
locked_names = sorted(p["name"] for p in lockfile["public"]["packages"])
EXCEPTIONS = {"hello"}
declared_seed = [n for n in locked_names if n not in EXCEPTIONS]

if not declared_seed:
    problem("computed declared seed is empty — archive.lock.json/exceptions mismatch")

# -- 4. Exceptions must be real: excluding a package that isn't even locked
#       is a dead entry.
for pkg in EXCEPTIONS:
    if pkg not in locked_names:
        problem(f"exception '{pkg}' is not in archive.lock.json public.packages — dead exception entry")

# -- 2 & 3. Parity: ubuntnix ships ONE shared locked closure that both the
#    server and desktop profiles draw from (serverSeedPackages ==
#    desktopSeedPackages by construction). So the honest R11 relationship is
#    that every declared package is a genuine member of at least one official
#    upstream Ubuntu release image — the Server ∪ Desktop manifest union — OR
#    a documented ubuntnix addition. (A strict per-variant subset would be
#    wrong: e.g. curl and lsb-base are real Ubuntu packages seeded on the
#    Server image but not the Desktop live image; our shared minimal base
#    legitimately carries them.) This proves ubuntnix invents/renames no
#    packages: everything it ships is real upstream Ubuntu bar the additions.
variants = {
    "Server": upstream_names(server_manifest),
    "Desktop": upstream_names(desktop_manifest),
}
upstream_union = set().union(*variants.values())

divergent = [n for n in declared_seed if n not in upstream_union and not is_addition(n)]
if divergent:
    problem(
        f"parity: {len(divergent)} declared package(s) are in NEITHER upstream "
        f"manifest (Server ∪ Desktop) nor the ubuntnix-additions allow-list: "
        + ", ".join(divergent)
        + " — if genuinely ubuntnix-specific, add to ADDITIONS_EXACT/PREFIX with a "
        "rationale; otherwise it is an unexplained upstream divergence."
    )
else:
    additions = sum(1 for n in declared_seed if is_addition(n))
    in_union = len(declared_seed) - additions
    per_variant = ", ".join(
        f"{lbl} {sum(1 for n in declared_seed if n in names)}"
        for lbl, names in variants.items()
    )
    print(
        f"OK: parity — all {len(declared_seed)} declared seed packages accounted for "
        f"({in_union} in upstream Server∪Desktop, {additions} documented ubuntnix "
        f"additions). Per-variant upstream coverage: {per_variant}."
    )

sys.exit(rc)
PYEOF
then
  fail "upstream-manifest parity check failed (see above)"
fi

exit "$fails"
