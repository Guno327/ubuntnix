#!/usr/bin/env bash
# tests/unit/213-ubuntu-base-fixture-pin.sh — the ubuntu-base package-list
# fixture (tests/fixtures/upstream-manifests/ubuntu-base-24.04.4-base-
# amd64.packages) must never silently drift from the actual `ubuntu-base`
# tarball nix/stdenv.nix fetches (GitHub issue #140; SPEC.md §12 R11, §11
# M7).
#
# WHY THIS TEST EXISTS: tests/unit/210-upstream-manifest-parity.sh's R11
# coverage report (issue #140) now unions this fixture's package list with
# the locked closure before diffing against upstream, on the premise that
# `nix/compose.nix`'s composeRootfs unpacks the SAME ubuntu-base tarball
# nix/stdenv.nix pins underneath every declared package (see that file's
# "ubuntu-base plus every declared package" language). That premise only
# holds if the fixture really was derived from the exact tarball spin the
# build actually fetches. If nix/stdenv.nix's pin is ever bumped to a new
# `ubuntu-base` point release (e.g. 24.04.4 -> 24.04.5) without also
# regenerating this fixture, 210's "closed by base layer" accounting would
# silently start reporting packages from a tarball that no longer matches
# what actually gets composed — a correctness regression that would not be
# caught by anything else, since nothing else cross-references the two.
# This test is the tripwire: it parses nix/stdenv.nix's live pin and the
# fixture's own recorded provenance SHA-256 and fails loudly the moment
# they disagree, plus a handful of basic fixture-hygiene invariants (non-
# empty, sorted, duplicate-free) that a hand-edit could otherwise violate
# unnoticed.
#
# Fully offline: reads two already-committed text files and does string/
# hash arithmetic in python3 (this machine has no `jq`; SPEC.md's stdlib
# choice for JSON/text munging in tests is python3, per the other unit
# tests in this suite). No network, no nix evaluation, no qemu — always
# runs, every CI invocation, unconditionally.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

stdenv_nix="nix/stdenv.nix"
fixture="tests/fixtures/upstream-manifests/ubuntu-base-24.04.4-base-amd64.packages"

for f in "$stdenv_nix" "$fixture"; do
  [ -f "$f" ] || {
    echo "FAIL: required input '$f' does not exist" >&2
    exit 1
  }
done

if ! python3 - "$stdenv_nix" "$fixture" <<'PYEOF'
import re
import sys

stdenv_nix, fixture = sys.argv[1], sys.argv[2]

rc = 0


def problem(msg):
    global rc
    print(f"FAIL: {msg}", file=sys.stderr)
    rc = 1


# -- 1. Parse nix/stdenv.nix's live pin ------------------------------------
#
# The authoritative value is the `sha256 = "...";` Nix attribute that
# nix/stdenv.nix's `ubuntuBase.sha256` assigns (line 97 as of this writing)
# -- that is what `builtins.fetchurl` actually verifies
# on every fetch, per that file's own "Trust root" comment ("That
# independently reproduced digest is `sha256` below, and it is what Nix
# actually verifies on every fetch — the published SHA256SUMS file is only
# corroborating evidence"). A comment quoting the published SHA256SUMS line
# also appears earlier in the file for human cross-checking, but the code
# assignment is the ground truth this test pins against.
with open(stdenv_nix, encoding="utf-8") as fh:
    stdenv_src = fh.read()

m = re.search(r'sha256\s*=\s*"([0-9a-f]{64})"\s*;', stdenv_src)
if not m:
    problem(f"{stdenv_nix}: could not find a `sha256 = \"<64-hex>\";` pin")
    pin = None
else:
    pin = m.group(1)

# -- 2. Parse the fixture's own recorded provenance SHA-256 ---------------
#
# The fixture's header comment records the tarball digest it was derived
# from under a `#   Tarball SHA-256: <hex>` line (see that file's own
# header for the full provenance block). Extract it the same way 210
# extracts pins from its own fixtures: a plain regex over the committed
# text, not a hand-maintained duplicate constant in this script, so the
# fixture file itself stays the single source of truth for its provenance.
with open(fixture, encoding="utf-8") as fh:
    fixture_lines = fh.readlines()

fm = re.search(
    r"Tarball SHA-256:\s*([0-9a-f]{64})", "".join(fixture_lines)
)
if not fm:
    problem(f"{fixture}: could not find a '# Tarball SHA-256: <64-hex>' provenance line")
    fixture_sha = None
else:
    fixture_sha = fm.group(1)

# -- 3. The two must agree --------------------------------------------------
if pin is not None and fixture_sha is not None and pin != fixture_sha:
    problem(
        f"{fixture}: recorded provenance SHA-256 {fixture_sha} != "
        f"{stdenv_nix}'s live ubuntu-base pin {pin} (fixture drift — "
        "regenerate the fixture from the newly-pinned tarball; see the "
        "fixtures README's 'ubuntu-base base-layer package list' section)"
    )

# -- 4. Fixture hygiene: the package list itself (non-comment, non-blank
#    lines) must be non-empty, strictly sorted, and duplicate-free. A
#    hand-edit that appends out of order or repeats a name would silently
#    corrupt 210's base-union accounting without any of the checks above
#    catching it.
names = [
    line.strip()
    for line in fixture_lines
    if line.strip() and not line.lstrip().startswith("#")
]

if not names:
    problem(f"{fixture}: no package names found (only comments/blank lines)")
else:
    if names != sorted(names):
        problem(f"{fixture}: package list is not sorted")
    if len(names) != len(set(names)):
        dupes = sorted({n for n in names if names.count(n) > 1})
        problem(f"{fixture}: duplicate package name(s): {', '.join(dupes)}")

if rc == 0:
    print(
        f"OK: ubuntu-base fixture pin — {len(names)} package names, sorted, "
        f"duplicate-free, provenance SHA-256 matches {stdenv_nix}'s live pin "
        f"({pin})."
    )

sys.exit(rc)
PYEOF
then
  fail "ubuntu-base fixture pin check failed (see above)"
fi

exit "$fails"
