#!/usr/bin/env bash
# tests/unit/216-install-docs-consistency.sh -- pins docs/install.md's
# top-of-page admonition against reasserting "there is no installer" now
# that there IS one (GitHub issue #148).
#
# WHY THIS TEST EXISTS: before issue #148, docs/install.md opened with an
# admonition claiming "Nothing in this page exists yet. ubuntnix is
# pre-M1: there is no installer, no ISO, and no `/flake` bootstrap" --
# while M1 through M6 had already shipped (bootable-image, switch-loop,
# snap-convergence, home-activation, and server/desktop parity all green
# in CI) and two substantial, unit-tested installer components already
# existed in the tree: the answers->config compiler (nix/installer.nix,
# tests/unit/200-203) and the real `/flake` bootstrap
# (bin/ubx-flake-init, tests/unit/205) plus Ubuntu Pro token capture
# (bin/ubx-pro-token, tests/unit/206). The page even contradicted ITSELF
# within one screen: its own "Planned installer steps" section described
# ubx-flake-init and ubx-pro-token in the present tense and said outright
# "the flow itself is real and unit-tested."
#
# That kind of drift is easy to reintroduce silently -- e.g. a future
# editor "simplifying" the banner back to a blanket pre-M1 disclaimer, or
# reverting install.md while leaving the real bin/ scripts in place -- and
# nothing else in this suite would catch it, because docs/*.md is prose,
# not code any other test exercises. This test is the same
# self-consistency-enforcement pattern tests/unit/215-parity-ratchet.sh
# (issue #146) established for the parity residual: it doesn't test that
# the installer WORKS (200-206 and the e2e suite already do that); it
# tests that the DOCS don't lie about whether it exists, by cross-checking
# prose claims against the real tree the same test run has access to.
#
# The check is intentionally narrow and mechanical (grep for specific
# phrases, not a general "sounds pessimistic" heuristic) so it doesn't
# become a maintenance burden or block honest future rewording -- it only
# fires if BOTH of these are true at once:
#   (a) docs/install.md contains one of the exact false-again phrases
#       ("nothing in this page exists yet", "ubuntnix is pre-M1", "there
#       is no installer"), AND
#   (b) the real installer components those phrases contradict
#       (bin/ubx-flake-init, bin/ubx-pro-token) are actually present in
#       the tree.
# If a future milestone genuinely regresses and those scripts are removed
# again, condition (b) goes false and this test goes quiet on its own --
# it is checking for a CONTRADICTION, not asserting the scripts must exist
# forever.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

install_doc="docs/install.md"
[ -f "$install_doc" ] || {
  echo "FAIL: $install_doc does not exist" >&2
  exit 1
}

flake_init="bin/ubx-flake-init"
pro_token="bin/ubx-pro-token"

# -- Only meaningful once the components the banner would be contradicting
#    actually exist. If either is missing, the "pre-M1, no installer"
#    framing would be TRUE again, so there is nothing to catch here -- see
#    this file's header on why that makes the test go quiet, not fail.
if [ ! -e "$flake_init" ] || [ ! -e "$pro_token" ]; then
  echo "SKIP: $flake_init and/or $pro_token do not exist -- nothing to contradict" >&2
  exit 77
fi

# -- Case-insensitive, exact-phrase greps for the specific claims that were
#    false when this test was written. Matched one at a time (not as a
#    single alternation) so a failure message names exactly which stale
#    phrase came back.
stale_phrases=(
  "nothing in this page exists yet"
  "ubuntnix is pre-M1"
  "there is no installer"
)

for phrase in "${stale_phrases[@]}"; do
  if grep -qi -- "$phrase" "$install_doc"; then
    fail "$install_doc reasserts the stale claim '$phrase', but $flake_init and $pro_token both exist and are unit-tested (tests/unit/205, tests/unit/206) -- see this test's header for why that is a real contradiction, not a stylistic nit"
  fi
done

# -- Positive check, not just an absence check: the page must actually
#    NAME the real, implemented mechanisms it is describing, so a rewrite
#    that drops the stale phrases but goes vague instead (no script names,
#    no test references) doesn't silently satisfy this test while still
#    failing to inform a reader what is real today.
for needle in "ubx-flake-init" "ubx-pro-token" "nix/installer.nix"; do
  grep -q -- "$needle" "$install_doc" || {
    fail "$install_doc no longer names '$needle' -- it should say plainly which real, unit-tested mechanism backs each installer step"
  }
done

if [ "$fails" -eq 0 ]; then
  echo "OK: $install_doc does not reassert 'no installer'/'pre-M1' while $flake_init and $pro_token exist, and it names the real mechanisms it describes"
fi

exit "$fails"
