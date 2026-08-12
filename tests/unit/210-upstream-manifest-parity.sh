#!/usr/bin/env bash
# tests/unit/210-upstream-manifest-parity.sh — diff ubuntnix's declared
# seed closure against the REAL upstream Ubuntu release manifests
# (SPEC.md §12 R11, §11 M7; GitHub issue #118).
#
# -- These are LIVE-ISO manifests, and R11's target is NOT gap == 0 --------
#
# tests/fixtures/upstream-manifests/*.manifest are `*-live-server-*` /
# `*-desktop-*` filenames because that is the ONLY installed-package
# inventory Canonical publishes for a 24.04.x point release: the PM checked
# both releases.ubuntu.com/24.04.3/ and the cdimage daily-live tree for
# 24.04.3 and found no installed-system manifest at all — only
# live-server/desktop/wsl `.manifest` files, which enumerate what the LIVE
# BOOT MEDIUM carries (installer + live session), not what ends up on the
# disk after `install` finishes. GitHub issue #143 traced two classes of
# package that are consequently permanently, legitimately absent from any
# installed ubuntnix system's effective package set while still showing up
# in these fixtures, which the gap-classification block below (search
# "issue #143") enumerates and nets out explicitly, each with its own
# justification, rather than leaving them to silently inflate the "missing"
# count forever. Given that, the honest R11 exit criterion for this metric
# is gap ⊆ {live-only, kernel-ABI-skew} — i.e. the RESIDUAL after netting
# both classes reaches 0 — never that the raw gap against these live-ISO
# fixtures reaches 0, because a subset of what they list can never be
# installed. See tests/fixtures/upstream-manifests/README.md for the same
# point stated for humans browsing that directory, and
# tests/unit/214-live-iso-gap-classification.sh for the pinned regression
# test on the classification logic itself.
#
# -- The ratchet (GitHub issue #146) ----------------------------------------
#
# Everything from here up through the "Gap classification" block below is
# purely INFORMATIONAL reporting — as the comment right above the residual
# print loop used to say verbatim, "it never sets `rc`; a growing gap is
# expected." That was true of the raw/base-adjusted GAP (see issue #140:
# the seed is deliberately still growing toward the full upstream task-set,
# so THAT number regressing on every single PR is expected and correct).
# But the fully-netted RESIDUAL computed at the bottom of the classification
# block — genuinely-missing packages, net of both #140's base-layer
# accounting and #143's live-ISO/kernel-ABI netting — is a different
# animal: every package left in it is either a real, permanent divergence
# (should shrink toward the exception/addition lists as it's investigated)
# or a real, temporary gap the seed-growth work is meant to close (should
# shrink as SPEC.md sec11's M5 work lands). It should never silently GROW,
# and until issue #146 nothing here checked that — the residual could
# regress every single PR and CI would stay green forever, because (per the
# same comment) the whole block "never sets rc." tests/fixtures/upstream-
# manifests/parity-ratchet-baseline.json pins the residual this test
# actually measured against the fixtures committed alongside it (see that
# file's own "_provenance" field for the exact commit and issue trail), and
# ratchet_check() below (search that name) asserts the live residual never
# exceeds it. Residual BELOW baseline still passes — improvement is always
# welcome — but prints a "ratchet may be tightened" line rather than
# silently absorbing the improvement, so tightening the pinned baseline is
# always a deliberate, reviewable PR, not something that just happens.
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
# archive.lock.json". This test asserts the direction of R11 that holds at
# every point along the way: every package ubuntnix declares must be a
# genuine member of an upstream release — with the sole, explicitly-
# enumerated exception of ubuntnix's own additions (the `nix` closure and
# build/image tooling, which by design are not in stock Ubuntu). Any
# declared package that is neither in the upstream manifest nor in that
# documented additions list is an unexplained divergence and fails CI.
#
# NOTE (issue #118): this header used to say the locked closure was a
# minimal 171-package base that was deliberately NOT the upstream task-set,
# and that extending it was owner-gated. That is no longer accurate. SPEC
# §10 ("same software set" as upstream) and §11's M5 exit criterion MANDATE
# the full upstream Server seed, so the seed is being grown toward it one
# task-set metapackage per PR (ubuntu-minimal, ubuntu-standard,
# ubuntu-server-minimal, ubuntu-server, linux-generic). The subset
# direction asserted here stays correct and useful throughout that growth —
# it is what catches an unexplained package appearing in our closure — but
# it is a floor, not a statement that upstream ⊆ ours is out of scope.
#
# -- The base layer (GitHub issue #140) -------------------------------------
#
# The coverage GAP this test reports (how much of upstream we do NOT yet
# have) used to be measured as upstream minus the locked closure alone. That
# overstated the gap: a composed ubuntnix system is not just the locked
# closure. `nix/compose.nix`'s `composeRootfs` unpacks the `ubuntu-base`
# tarball FIRST and layers the locked closure on top of it (see that file's
# "ubuntu-base plus every declared package" language at its composeRootfs
# header and implementation) — `nix/stdenv.nix` pins exactly which tarball.
# Packages that ship inside ubuntu-base itself (`bash`, `dash`, `grep`,
# `gzip`, `util-linux`, `base-files`, `login`, and so on — 15 of them
# against the Server manifest as of this writing) are present on every real
# composed system whether or not `archive.lock.json` lists them too, so the
# honest "how much of upstream does a composed system actually have"
# question has to compute against base ∪ closure, not closure alone. The
# base layer's own package inventory is committed as
# tests/fixtures/upstream-manifests/ubuntu-base-24.04.4-base-amd64.packages
# (see that directory's README for how it was derived and how it stays
# pinned to the exact tarball nix/stdenv.nix fetches — tests/unit/213-
# ubuntu-base-fixture-pin.sh is the tripwire for that). This CHANGES ONLY
# THE COVERAGE/GAP REPORTING below (an informational OK-line, not an
# assertion); it does not touch the "declared ⊆ upstream + additions"
# subset check above, which stays exactly as it was — the base layer isn't
# something we "declare," so it has no bearing on whether OUR declarations
# are honest.
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
base_packages="$fixtures_dir/ubuntu-base-24.04.4-base-amd64.packages"
profiles_nix="nix/profiles.nix"
# GitHub issue #146: the pinned residual-count ratchet baseline. Overridable
# via UBX_PARITY_RATCHET_BASELINE_FILE — unset on every real invocation (so
# $ratchet_baseline_file resolves to this real, committed file exactly as if
# the override didn't exist), following the same "env var overrides a
# real-by-default path" seam tests/lib/ubx-installer-parity-assert.sh uses
# for UBX_PARITY_ROOT. tests/unit/215-parity-ratchet.sh, this test's sibling,
# does not actually need the override (it drives the pure ratchet_check()
# function directly with synthetic in-memory inputs — see that file's own
# header for why that seam was preferred over faking a whole baseline file
# here) but the override is left in place as the same defensive seam every
# other fixture-path constant in this file already gets, in case a future
# test wants to point this whole script at a synthetic baseline wholesale.
ratchet_baseline_file="${UBX_PARITY_RATCHET_BASELINE_FILE:-$fixtures_dir/parity-ratchet-baseline.json}"

for f in "$server_manifest" "$desktop_manifest" "$base_packages" "$ratchet_baseline_file" archive.lock.json "$profiles_nix"; do
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

if ! python3 - "$server_manifest" "$desktop_manifest" "$base_packages" "$ratchet_baseline_file" <<'PYEOF'
import hashlib
import json
import re
import sys

server_manifest, desktop_manifest, base_packages, ratchet_baseline_file = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4],
)

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


def base_layer_names(path):
    """Parse the ubuntu-base package-list fixture (GitHub issue #140): one
    package name per line, `#`-prefixed provenance comments and blank lines
    ignored. See tests/fixtures/upstream-manifests/README.md's "ubuntu-base
    base-layer package list" section for what this file is and how it is
    derived; tests/unit/213-ubuntu-base-fixture-pin.sh is what keeps it
    honest against nix/stdenv.nix's live tarball pin — this function just
    reads it."""
    names = set()
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            names.add(line)
    return names


# -- ubuntnix-specific additions: packages ubuntnix declares that are, by
#    design, NOT part of a stock Ubuntu release and so legitimately absent
#    from the upstream manifest. Enumerated explicitly so any *new*, un-
#    accounted-for divergence fails instead of hiding here. Categories:
#      * the `nix` runtime itself and its transitive C/Perl deps
#      * fakeroot + initramfs/image build tooling
#    Kernel packages are pinned to a concrete ABI (e.g.
#    linux-image-6.8.0-134-generic) that never equals upstream's metapackage
#    name, so they are matched by prefix rather than exact name. The
#    linux-headers- prefix joins them with the linux-generic metapackage
#    (GitHub issue #118): upstream's own manifest carries
#    linux-headers-6.8.0-71{,-generic}, i.e. these ARE real upstream
#    packages — they simply pin a different ABI than the snapshot we
#    resolve against, which is exactly the linux-image-/linux-modules-
#    situation and not a genuine ubuntnix-only divergence.
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
ADDITIONS_PREFIX = ("linux-image-", "linux-modules-", "linux-headers-")


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

# -- Coverage/gap reporting: base ∪ closure, not closure alone (issue #140) -
#
# The above proves declared ⊆ upstream and stops there — it never asked how
# much of upstream we're still MISSING. This section answers that, purely
# informationally (it never sets `rc`; a growing gap is expected and tracked
# by SPEC.md §11's M5 seed-growth work, not a per-PR CI failure). The
# effective package set a real composed system has is base ∪ closure (see
# this file's header and nix/compose.nix's composeRootfs): the ubuntu-base
# tarball nix/stdenv.nix pins, layered under whatever the locked closure
# adds. Reporting the gap against the closure alone — as this test did
# before issue #140 — overstated it by counting packages like `bash` and
# `grep` as "missing" when every composed system already has them via
# ubuntu-base.
base_names = base_layer_names(base_packages)
effective_system = set(declared_seed) | base_names

for lbl, upstream in variants.items():
    gap_closure_only = upstream - set(declared_seed)
    gap_with_base = upstream - effective_system
    closed_by_base = gap_closure_only - gap_with_base
    print(
        f"OK: {lbl} upstream-coverage gap — {len(gap_closure_only)} packages "
        f"uncovered by the locked closure alone; {len(gap_with_base)} "
        f"uncovered once the ubuntu-base layer ({len(base_names)} packages) "
        f"is also counted ({len(closed_by_base)} closed by the base layer)."
    )

# -- Gap classification: live-ISO false positives (GitHub issue #143) ------
#
# The gap figures printed just above are computed against
# tests/fixtures/upstream-manifests/*.manifest, and — as this file's header
# now explains — those are LIVE-ISO manifests (the boot medium's own
# package set), not installed-system manifests, because Canonical publishes
# no installed-system equivalent for 24.04.x. That means a fixed, knowable
# subset of "missing" packages can NEVER be closed no matter how complete
# ubuntnix's seed grows, because they only ever exist in the live
# environment that installs a system, not on the system it installs. Two
# such classes were identified by inspecting the actual gap set:
#
#   1. LIVE-ONLY packages: components of the live-boot/installer stack
#      itself (casper's live-session machinery, subiquity/di-live's
#      first-user and locale-prompt data, and the installer's own
#      snapd-managed snaps). Enumerated by exact name below, each with its
#      own why-this-one justification — mirroring how ADDITIONS_EXACT
#      above documents ubuntnix's own by-design divergences instead of
#      silently allow-listing them.
#
#   2. KERNEL-ABI-SKEW packages: upstream 24.04.3's live media was built
#      against a specific kernel ABI build (Server: 6.8.0-71; Desktop's HWE
#      track: 6.14.0-27) baked directly into these packages' NAMES
#      (linux-image-6.8.0-71-generic and so on), while the snapshot
#      archive.lock.json resolves against pins a different, newer ABI build
#      of the SAME source (6.8.0-134 as of this writing — see
#      linux-image-6.8.0-134-generic already declared). This is the exact
#      mirror image of ADDITIONS_PREFIX above, which excuses OUR
#      ABI-specific package names from looking like unexplained additions
#      when diffed against upstream; this direction excuses upstream's
#      ABI-specific names from looking like permanently-missing packages
#      when they are, in substance, the same linux-generic/-hwe metapackage
#      family we already ship. Because the concrete ABI number will change
#      every time these fixtures are refreshed for a newer point release
#      (unlike ADDITIONS_PREFIX, which only needs a literal prefix because
#      OUR pin is a fixed constant at any given commit), this class is
#      matched by a REGEX PATTERN on the kernel-version shape
#      (`\d+\.\d+\.\d+-\d+`) rather than a hardcoded ABI string, so it
#      survives a fixture refresh without edits here. The pattern is
#      deliberately narrow — prefix + exact kernel-version-number shape +
#      optional literal "-generic" suffix, nothing else — so it does NOT
#      swallow a genuinely different, genuinely missing kernel package: for
#      example "linux-tools-common" (versioned but carries no ABI number in
#      its name) and Desktop's "linux-headers-generic-hwe-24.04" /
#      "linux-image-generic-hwe-24.04" (real, distinctly-named HWE-track
#      metapackages ubuntnix does not currently declare at all, not a mere
#      ABI-pin mismatch of a package we do declare) both fail to match and
#      correctly fall through to the "genuinely missing" residual instead
#      of being netted out here.
LIVE_ONLY_EXCLUSIONS = {
    "casper": (
        "the live-boot squashfs/initrd system that boots and drives the "
        "live session itself; it unmounts/is discarded once the target "
        "system is installed and rebooted, so it is never a member of an "
        "installed system's package set by design."
    ),
    "user-setup": (
        "the subiquity/di-live component that interactively creates the "
        "first user account DURING install; it and its prompts run only in "
        "the live installer environment and are not carried onto the "
        "target system's disk."
    ),
    "localechooser-data": (
        "data backing the live installer's locale-selection prompts shown "
        "before/during install; consumed entirely within the live session, "
        "never copied to the installed target."
    ),
    "snap": (
        "the upstream_names() parser strips a `:arch`-shaped suffix off "
        "every package name, which collapses every `snap:<name>` line in "
        "these live manifests (snapd itself, core22, subiquity, and on "
        "Desktop firefox/gnome-42-2204/gtk-common-themes/etc.) down to the "
        "single bare name \"snap\". Those are snaps pre-seeded into the "
        "live squashfs for the installer's own use (or, on Desktop, "
        "default post-install snap seeds installed by subiquity/ubiquity "
        "AFTER the deb-based rootfs this test models is already assembled) "
        "— snapd manages them in its own separate namespace outside dpkg, "
        "so they were never going to be members of the dpkg-based "
        "effective_system this test computes, live manifest or not."
    ),
}

_ABI_SKEW_RE = re.compile(
    r"^linux-(headers|image|modules-extra|modules|tools)-"
    r"\d+\.\d+\.\d+-\d+(-generic)?$"
)


def abi_skew(name):
    return bool(_ABI_SKEW_RE.match(name))


# -- The ratchet itself (GitHub issue #146) ---------------------------------
#
# ratchet_check() is deliberately a PURE function: no file I/O, no `problem`/
# `rc` global, nothing but its four arguments in and a plain result dict out.
# That is the injection seam tests/unit/215-parity-ratchet.sh (this test's
# sibling, written first per the issue's "tests first" instruction) relies
# on: it cannot make the REAL residual numbers below regress on demand to
# exercise the rise/fall/equal cases, so instead of driving this whole
# 400+-line script end to end it sed-extracts just this function (the same
# "extract 210's own source rather than hand-duplicate a second copy that
# could drift" technique tests/unit/214-live-iso-gap-classification.sh
# already uses for LIVE_ONLY_EXCLUSIONS/_ABI_SKEW_RE, applied here to a
# function instead of a data literal) and calls it directly with synthetic
# residual sets / baseline entries. Keeping every dependency as an explicit
# parameter — rather than reading `baseline` or `problem()` off the module
# namespace the way the rest of this script freely does — is what makes
# that extraction safe: the function behaves identically whether it is
# called from the real loop below or from a 20-line synthetic harness that
# never runs any of the surrounding fixture-parsing code at all.
def ratchet_check(label, baseline_count, baseline_packages, residual_names):
    """Compare a live residual against its pinned ratchet baseline.

    `baseline_count`/`baseline_packages` come from tests/fixtures/upstream-
    manifests/parity-ratchet-baseline.json (see that file's own
    "_provenance" field for exactly what was measured, against what
    fixtures, at what commit, per issues #140/#143). `residual_names` is
    the live, freshly-computed residual set for this run.

    Returns {"status": "regression" | "tightened" | "steady", "message":
    str | None}:
      * "regression" — the live residual is BIGGER than the pinned
        baseline. This is the case that must fail the build: parity quietly
        getting worse, with no CI signal, is exactly what issue #146 exists
        to stop. The message names the SPECIFIC packages that are in the
        live residual but not in the pinned baseline package list — not
        just the count — so a reviewer sees exactly what regressed instead
        of having to go re-derive it by hand.
      * "tightened" — the live residual is SMALLER than the pinned
        baseline. This always PASSES (an improvement is never a failure)
        but is not allowed to pass silently either: the message says
        explicitly that the baseline could now be lowered, so a real
        improvement gets banked as a deliberate follow-up PR instead of
        just quietly making next run's slack bigger.
      * "steady" — live residual == baseline exactly, today's steady state
        for both variants. Passes with no message at all, per the issue's
        explicit "equal ⇒ passes quietly" requirement — this is the
        expected, common case and should not add noise to green CI output.
    """
    residual_names = set(residual_names)
    baseline_packages = set(baseline_packages)
    n = len(residual_names)

    if n > baseline_count:
        newly_entered = sorted(residual_names - baseline_packages)
        if newly_entered:
            detail = ", ".join(newly_entered)
        else:
            # The count rose but every live-residual name is already in the
            # pinned baseline list — impossible unless the baseline package
            # list and baseline count have drifted apart (e.g. hand-edited
            # inconsistently). Still a real regression against the pinned
            # count; say so rather than printing an empty, useless list.
            detail = (
                "(no individual package names differ from the pinned "
                "baseline list, but the count still exceeds it — the "
                "baseline file's residual_count/residual_packages have "
                "drifted out of sync with each other; treat as a "
                "regression and re-derive the baseline file)"
            )
        return {
            "status": "regression",
            "message": (
                f"{label} parity ratchet (GitHub issue #146): residual "
                f"{n} exceeds the pinned baseline of {baseline_count} — "
                f"newly entered the residual: {detail}"
            ),
        }

    if n < baseline_count:
        return {
            "status": "tightened",
            "message": (
                f"{label} parity ratchet (GitHub issue #146): residual "
                f"{n} is below the pinned baseline of {baseline_count} — "
                f"ratchet may be tightened to {n}. Lower "
                "residual_count/residual_packages for this variant in "
                "tests/fixtures/upstream-manifests/parity-ratchet-"
                "baseline.json in a deliberate follow-up PR once this is "
                "confirmed stable; do not let the slack just sit there."
            ),
        }

    return {"status": "steady", "message": None}


ratchet_baseline = json.load(open(ratchet_baseline_file, encoding="utf-8"))

for lbl, upstream in variants.items():
    gap_with_base = upstream - effective_system
    live_only_hits = {n for n in gap_with_base if n in LIVE_ONLY_EXCLUSIONS}
    abi_skew_hits = {n for n in gap_with_base if abi_skew(n)}
    residual = gap_with_base - live_only_hits - abi_skew_hits
    print(
        f"OK: {lbl} gap classification (issue #143, live-ISO manifests) — "
        f"raw gap {len(gap_with_base)}; net of {len(live_only_hits)} "
        f"live-only package(s) = {len(gap_with_base) - len(live_only_hits)}; "
        f"net of {len(abi_skew_hits)} kernel-ABI-skew package(s) = "
        f"{len(gap_with_base) - len(abi_skew_hits)}; residual (net of both) "
        f"= {len(residual)} genuinely missing."
    )

    if lbl not in ratchet_baseline:
        problem(
            f"{ratchet_baseline_file} has no entry for variant {lbl!r} — "
            "add one (see the file's _provenance field for how existing "
            "entries were derived) before this variant's residual can be "
            "ratcheted"
        )
        continue

    baseline_entry = ratchet_baseline[lbl]
    result = ratchet_check(
        lbl,
        baseline_entry["residual_count"],
        baseline_entry["residual_packages"],
        residual,
    )
    if result["status"] == "regression":
        problem(result["message"])
    elif result["status"] == "tightened":
        print(f"OK: {result['message']}")
    # "steady": intentionally silent — see ratchet_check()'s docstring.

sys.exit(rc)
PYEOF
then
  fail "upstream-manifest parity check failed (see above)"
fi

exit "$fails"
