#!/usr/bin/env bash
# tests/unit/214-live-iso-gap-classification.sh — pin the live-ISO
# gap-classification logic tests/unit/210-upstream-manifest-parity.sh added
# for GitHub issue #143, against actual regressions in either direction.
#
# WHY THIS TEST EXISTS: 210's R11 coverage report nets the raw upstream gap
# down by two classes of package that can NEVER appear on an installed
# ubuntnix system because tests/fixtures/upstream-manifests/*.manifest are
# LIVE-ISO manifests, not installed-system manifests (see 210's header and
# tests/fixtures/upstream-manifests/README.md for why no installed-system
# equivalent exists to diff against instead) — live-only installer/live-boot
# packages (LIVE_ONLY_EXCLUSIONS) and upstream's kernel-ABI-specific package
# names (the _ABI_SKEW_RE pattern). Nothing else in this suite checks that
# logic for internal consistency: 210 itself only ever prints it as an
# informational OK-line (by design — the classification is not allowed to
# set `rc`, per issue #143's brief), so a dead exclusion entry (claiming to
# exclude a package that was never actually in the gap, e.g. after a
# fixture refresh changes what's missing) or a regex that quietly stops
# matching anything (e.g. a refactor that renames `_ABI_SKEW_RE` or narrows
# it into uselessness) would silently rot without ever failing CI. This
# test is the tripwire: it pulls the EXACT LIVE_ONLY_EXCLUSIONS dict and
# _ABI_SKEW_RE pattern out of 210's own source into a scratch file (rather
# than hand-copying a second version here that could itself drift out of
# sync with 210) and asserts, against the same committed fixtures 210
# reads:
#
#   1. every LIVE_ONLY_EXCLUSIONS entry is a real upstream package (present
#      in the Server or Desktop manifest) that is genuinely absent from the
#      effective system (base ∪ locked closure) — i.e. no dead entries
#      that exclude something that either isn't real or wasn't missing;
#   2. the ABI-skew regex is not a dead pattern — it matches at least one
#      real gap entry in at least one variant (it would be silently
#      matching nothing forever if e.g. a fixture refresh changed the
#      upstream ABI-string shape and nobody updated the pattern);
#   3. the regex stays TIGHT: known real, distinctly-named, genuinely-
#      missing kernel packages that must NOT be swallowed by ABI-skew
#      netting (Desktop's HWE metapackages, linux-tools-common) still fall
#      through to "genuinely missing" and are not misclassified; and
#   4. the residual arithmetic is self-consistent — for each variant, raw
#      gap == live-only hits + ABI-skew hits + residual, with the three
#      classes exactly partitioning the raw gap (no double-counted or
#      dropped package).
#
# Fully offline: reads already-committed fixtures and 210's own committed
# source, does string/set arithmetic in python3 (this machine has no `jq`;
# SPEC.md's stdlib choice for JSON/text munging in tests is python3, per
# the rest of this suite). No network, no nix evaluation, no qemu — always
# runs, every CI invocation, unconditionally.
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
parity_test="tests/unit/210-upstream-manifest-parity.sh"

for f in "$server_manifest" "$desktop_manifest" "$base_packages" archive.lock.json "$parity_test"; do
  [ -f "$f" ] || {
    echo "FAIL: required input '$f' does not exist" >&2
    exit 1
  }
done

# -- Extract the exact classification source out of 210, rather than
#    hand-duplicating a second copy here that could itself drift out of
#    sync with 210's real logic. The block runs from the
#    "LIVE_ONLY_EXCLUSIONS = {" assignment through the "_ABI_SKEW_RE ="
#    regex's closing ")" line — both are top-level (unindented) statements
#    in 210's embedded python heredoc, so a plain sed line-range keyed on
#    those two literal markers reliably isolates just the classification
#    data, with none of the surrounding parity-check or reporting code.
#    Written to a scratch file so the python3 invocation below can just
#    exec() it, sidestepping any shell-quoting hazard of inlining python
#    source (which itself contains quotes/backslashes) into a heredoc.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
classification_py="$scratch/extracted_classification.py"
sed -n '/^LIVE_ONLY_EXCLUSIONS = {/,/^)$/p' "$parity_test" >"$classification_py"

if ! grep -q '^LIVE_ONLY_EXCLUSIONS = {' "$classification_py" ||
  ! grep -q '^_ABI_SKEW_RE = re.compile(' "$classification_py"; then
  echo "FAIL: could not extract LIVE_ONLY_EXCLUSIONS/_ABI_SKEW_RE from $parity_test — has its structure changed? Update this test's sed markers to match." >&2
  exit 1
fi

if ! python3 - "$server_manifest" "$desktop_manifest" "$base_packages" archive.lock.json "$classification_py" <<'PYEOF'
import json
import re
import sys

server_manifest, desktop_manifest, base_packages, lockfile_path, classification_py = sys.argv[1:6]

rc = 0


def problem(msg):
    global rc
    print(f"FAIL: {msg}", file=sys.stderr)
    rc = 1


def upstream_names(path):
    """Parse an Ubuntu `.manifest` (`<pkg>\\t<version>` lines) into the set
    of binary package names, stripping any `:arch` multiarch suffix —
    identical logic to 210's own upstream_names(), duplicated here (rather
    than extracted) because it is generic manifest-parsing plumbing, not
    part of the issue #143 classification this test pins."""
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
    names = set()
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            names.add(line)
    return names


# -- Load the SAME classification data 210 actually uses, extracted
#    verbatim from its source into classification_py by the shell wrapper
#    above (see this file's header). A NameError/KeyError here means 210's
#    structure changed in a way that broke extraction, which is itself a
#    signal worth surfacing rather than swallowing.
namespace = {"re": re}
with open(classification_py, encoding="utf-8") as fh:
    exec(compile(fh.read(), classification_py, "exec"), namespace)
LIVE_ONLY_EXCLUSIONS = namespace["LIVE_ONLY_EXCLUSIONS"]
abi_skew_re = namespace["_ABI_SKEW_RE"]

if not LIVE_ONLY_EXCLUSIONS:
    problem("extracted LIVE_ONLY_EXCLUSIONS is empty — extraction is likely broken")

# -- Same effective-system computation 210 uses: base ∪ (locked closure -
#    the `hello` exception), per issue #140's "declared ⊆ base ∪ closure"
#    model. EXCEPTIONS is hardcoded here (not extracted) because 210 itself
#    hardcodes it too (only serverSeedExceptions/desktopSeedExceptions in
#    nix/profiles.nix are cross-checked against, via a separate grep this
#    test does not duplicate).
lockfile = json.load(open(lockfile_path, encoding="utf-8"))
locked_names = {p["name"] for p in lockfile["public"]["packages"]}
EXCEPTIONS = {"hello"}
declared_seed = locked_names - EXCEPTIONS
base_names = base_layer_names(base_packages)
effective_system = declared_seed | base_names

variants = {
    "Server": upstream_names(server_manifest),
    "Desktop": upstream_names(desktop_manifest),
}
upstream_union = set().union(*variants.values())

# -- 1. No dead LIVE_ONLY_EXCLUSIONS entries: each must be a real upstream
#       package that is genuinely missing from the effective system. An
#       entry failing either half would be excluding something that either
#       doesn't exist upstream (typo/renamed package) or was never in the
#       gap to begin with (netting nothing, silently inflating the "net of
#       live-only" count's apparent justification).
for name, reason in LIVE_ONLY_EXCLUSIONS.items():
    if not isinstance(reason, str) or len(reason) < 20:
        problem(f"LIVE_ONLY_EXCLUSIONS[{name!r}] has no substantive justification string")
    if name not in upstream_union:
        problem(
            f"LIVE_ONLY_EXCLUSIONS[{name!r}] is not a real package in either "
            "upstream manifest — dead exclusion entry"
        )
    if name in effective_system:
        problem(
            f"LIVE_ONLY_EXCLUSIONS[{name!r}] is already present in the effective "
            "system (base ∪ closure) — it was never in the gap, so excluding it "
            "nets out nothing; dead exclusion entry"
        )

# -- 2, 3 & 4: per-variant regex liveness/tightness + residual arithmetic --
#
# Known real, distinctly-named, genuinely-missing kernel packages that the
# regex must NOT swallow (see this file's header point 3): Desktop's
# HWE-track metapackages (whole different package family, not an ABI-pin
# mismatch of something we already declare) and linux-tools-common (a real
# versioned package that simply carries no ABI number in its name at all).
MUST_NOT_MATCH = {
    "linux-headers-generic-hwe-24.04",
    "linux-image-generic-hwe-24.04",
    "linux-tools-common",
}

any_abi_skew_hit = False
for lbl, upstream in variants.items():
    gap = upstream - effective_system
    live_only_hits = {n for n in gap if n in LIVE_ONLY_EXCLUSIONS}
    abi_skew_hits = {n for n in gap if abi_skew_re.match(n)}
    residual = gap - live_only_hits - abi_skew_hits
    any_abi_skew_hit = any_abi_skew_hit or bool(abi_skew_hits)

    # -- 4. Partition arithmetic: the three classes must exactly account
    #       for the raw gap, with no overlap (a package counted in two
    #       classes at once would double-subtract and corrupt the printed
    #       "net of" figures) and no leftover (every gap package must land
    #       in exactly one of the three buckets).
    overlap = live_only_hits & abi_skew_hits
    if overlap:
        problem(f"{lbl}: {sorted(overlap)} counted as BOTH live-only and ABI-skew")
    if len(live_only_hits) + len(abi_skew_hits) + len(residual) != len(gap):
        problem(
            f"{lbl}: partition arithmetic inconsistent — "
            f"{len(live_only_hits)} live-only + {len(abi_skew_hits)} abi-skew + "
            f"{len(residual)} residual != {len(gap)} raw gap"
        )

    # -- 3. Tightness: known genuinely-missing kernel packages present in
    #       this variant's gap must land in the residual, not be swallowed
    #       as ABI-skew.
    for name in MUST_NOT_MATCH & gap:
        if name in abi_skew_hits:
            problem(
                f"{lbl}: {name!r} is a genuinely-missing kernel package (not a mere "
                "ABI-pin mismatch) but the ABI-skew regex incorrectly matched it"
            )
        if name not in residual:
            problem(f"{lbl}: {name!r} expected in residual (genuinely missing) but is not")

if not any_abi_skew_hit:
    problem(
        "the ABI-skew regex matched zero packages across both variants' gaps — "
        "dead pattern (did an upstream fixture refresh change the ABI-string shape?)"
    )

if rc == 0:
    print(
        "OK: live-ISO gap classification (issue #143) — "
        f"{len(LIVE_ONLY_EXCLUSIONS)} live-only exclusion(s) all real and all "
        "genuinely missing; ABI-skew regex is live and does not swallow known "
        "genuinely-missing kernel packages; per-variant residual arithmetic is "
        "self-consistent."
    )

sys.exit(rc)
PYEOF
then
  fail "live-ISO gap classification check failed (see above)"
fi

exit "$fails"
