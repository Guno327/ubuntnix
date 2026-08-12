#!/usr/bin/env bash
# tests/unit/215-parity-ratchet.sh -- pins the monotonic residual RATCHET
# tests/unit/210-upstream-manifest-parity.sh added for GitHub issue #146
# against regressions in either direction.
#
# WHY THIS TEST EXISTS: before issue #146, 210's entire gap-classification
# block -- up to and including the fully-netted "residual (net of both) = N
# genuinely missing" figure -- was, by 210's own header comment, purely
# informational: it "never sets `rc`." That meant the residual could grow
# every single PR forever and CI would stay green throughout, because
# nothing ever compared it to anything. 210 now pins that residual against
# tests/fixtures/upstream-manifests/parity-ratchet-baseline.json (measured,
# per that file's own "_provenance" field, on `main` @ bb3e6fb: Server 237,
# Desktop 1401) via a small pure function, ratchet_check(), added to 210's
# python heredoc right above the residual-computation loop. THIS test pins
# ratchet_check() itself: that it fails the rise case, passes-with-a-note
# the fall case, and passes silently the equal case, and that a regression
# message names the actual offending package names rather than just a
# count.
#
# -- Why synthetic inputs, and how they reach the real function ------------
#
# The acceptance criteria for issue #146 are explicit that this suite
# cannot depend on being able to make the REAL residual numbers regress (or
# improve) on demand just to exercise a test -- that would mean editing
# committed upstream fixtures or archive.lock.json, which is both out of
# scope for this issue and actively forbidden by it. So this test does not
# run 210 end to end at all. Instead it uses the exact same extraction
# technique tests/unit/214-live-iso-gap-classification.sh already
# established in this suite for LIVE_ONLY_EXCLUSIONS/_ABI_SKEW_RE (pull the
# real, currently-shipping definition out of 210's own source with a
# targeted sed line-range, rather than hand-copying a second definition
# here that could itself silently drift out of sync with 210's real logic)
# and applies it to a function instead of a data literal: it extracts
# ratchet_check() out of 210.py's heredoc and calls it directly with
# small, synthetic, in-memory residual sets and baseline entries covering
# the rise/fall/equal cases the issue calls out. ratchet_check() was
# written as a pure function (four parameters in, a plain result dict out;
# no file I/O, no shared `problem()`/`rc` globals) specifically so that
# extracting and calling it in isolation like this is safe and behaves
# identically to being called from inside 210's real loop -- see that
# function's own docstring in 210's source for the same point made there.
#
# Fully offline: reads only 210's own already-committed source and does
# string/set arithmetic in python3 (no jq on this machine; SPEC.md's stdlib
# choice for JSON/text munging in tests is python3, per the rest of this
# suite). No network, no nix evaluation, no qemu, no real upstream
# manifests or archive.lock.json touched at all.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

parity_test="tests/unit/210-upstream-manifest-parity.sh"
[ -f "$parity_test" ] || {
  echo "FAIL: required input '$parity_test' does not exist" >&2
  exit 1
}

# -- Extract the exact ratchet_check() definition out of 210, rather than
#    hand-duplicating a second copy here that could itself drift out of
#    sync with 210's real logic (same rationale, same technique, as
#    tests/unit/214-live-iso-gap-classification.sh's extraction of
#    LIVE_ONLY_EXCLUSIONS/_ABI_SKEW_RE -- see that file's header). The
#    function is a single top-level (unindented) `def ratchet_check(...):`
#    block in 210's embedded python heredoc, ending at the blank line
#    before the next top-level statement, so a plain sed line-range keyed
#    on those two markers reliably isolates just the function, with none
#    of the surrounding fixture-loading or loop code (which this test does
#    not want to run at all -- see this file's header).
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
ratchet_py="$scratch/extracted_ratchet_check.py"
sed -n '/^def ratchet_check(/,/^ratchet_baseline = json.load/p' "$parity_test" |
  sed '$d' >"$ratchet_py"

if ! grep -q '^def ratchet_check(' "$ratchet_py" ||
  ! grep -q 'return {"status": "steady"' "$ratchet_py"; then
  echo "FAIL: could not extract a complete ratchet_check() from $parity_test -- has its structure changed? Update this test's sed markers to match." >&2
  exit 1
fi

if ! python3 - "$ratchet_py" <<'PYEOF'
import sys

(ratchet_py,) = sys.argv[1:2]

rc = 0


def problem(msg):
    global rc
    print(f"FAIL: {msg}", file=sys.stderr)
    rc = 1


# -- Load the SAME ratchet_check() 210 actually uses, extracted verbatim
#    from its source into ratchet_py by the shell wrapper above (see this
#    file's header). A NameError/SyntaxError here means 210's structure
#    changed in a way that broke extraction, which is itself a signal
#    worth surfacing rather than swallowing.
namespace = {}
with open(ratchet_py, encoding="utf-8") as fh:
    exec(compile(fh.read(), ratchet_py, "exec"), namespace)
ratchet_check = namespace["ratchet_check"]

# -- Case 1: RISE -- live residual bigger than baseline must FAIL, and the
#    message must name the SPECIFIC newly-entered package(s), not just a
#    count (issue #146 acceptance criterion 2). "libfoo-new" is in the live
#    residual but not the baseline package list; "libfoo-old" is in both
#    (already-known, not newly entered) so it must NOT be named as new.
result = ratchet_check(
    "Synthetic",
    2,  # baseline_count
    {"libfoo-old", "libfoo-also-old"},  # baseline_packages
    {"libfoo-old", "libfoo-also-old", "libfoo-new"},  # residual_names (3 > 2)
)
if result["status"] != "regression":
    problem(f"rise case: expected status 'regression', got {result!r}")
elif "libfoo-new" not in result["message"]:
    problem(f"rise case: expected the newly-entered package 'libfoo-new' named in the message, got: {result['message']}")
elif "libfoo-old" in result["message"].split("newly entered the residual:", 1)[-1]:
    problem(
        "rise case: message names 'libfoo-old' as newly-entered, but it was "
        f"already in the baseline (not new): {result['message']}"
    )

# -- Case 1b: RISE where every live-residual name happens to already be in
#    the baseline package list (only possible if residual_count and
#    residual_packages have drifted out of sync with each other) --- must
#    still FAIL (the count is the source of truth for pass/fail), with a
#    message that says so rather than silently naming nothing.
result = ratchet_check(
    "Synthetic",
    1,  # baseline_count says 1 (drifted: too low for the package list below)
    {"libfoo-old", "libfoo-also-old"},  # but 2 packages are actually pinned
    {"libfoo-old", "libfoo-also-old"},  # residual_names (2 > baseline_count 1)
)
if result["status"] != "regression":
    problem(f"rise (drifted-baseline) case: expected status 'regression', got {result!r}")
elif not result["message"]:
    problem("rise (drifted-baseline) case: expected a non-empty message")

# -- Case 2: FALL -- live residual smaller than baseline must PASS, with a
#    visible "ratchet may be tightened" note naming the new, lower number
#    (issue #146 acceptance criterion 3) so an improvement is never just
#    silently absorbed.
result = ratchet_check(
    "Synthetic",
    5,  # baseline_count
    {"a", "b", "c", "d", "e"},  # baseline_packages
    {"a", "b", "c"},  # residual_names (3 < 5)
)
if result["status"] != "tightened":
    problem(f"fall case: expected status 'tightened', got {result!r}")
elif "tighten" not in (result["message"] or "").lower():
    problem(f"fall case: expected the message to mention tightening, got: {result['message']}")
elif "3" not in (result["message"] or ""):
    problem(f"fall case: expected the new lower number (3) mentioned in the message, got: {result['message']}")

# -- Case 3: EQUAL -- live residual exactly matching baseline must PASS
#    SILENTLY: no message at all (issue #146 acceptance criterion 4 -- this
#    is today's actual steady state for both real variants, and must not
#    add noise to green CI output).
result = ratchet_check(
    "Synthetic",
    3,  # baseline_count
    {"a", "b", "c"},  # baseline_packages
    {"a", "b", "c"},  # residual_names (3 == 3)
)
if result["status"] != "steady":
    problem(f"equal case: expected status 'steady', got {result!r}")
elif result["message"] is not None:
    problem(f"equal case: expected a silent (None) message, got: {result['message']}")

# -- Case 3b: EQUAL in size but with a different package SET at the same
#    count -- must still be "steady" (the ratchet enforces the COUNT, per
#    issue #146's brief; a same-size membership churn where the packages
#    swap identity but the total doesn't grow is not a regression).
result = ratchet_check(
    "Synthetic",
    3,
    {"a", "b", "c"},
    {"a", "b", "z"},  # "z" replaces "c", still 3 total
)
if result["status"] != "steady":
    problem(f"equal-different-membership case: expected status 'steady', got {result!r}")

if rc == 0:
    print(
        "OK: parity ratchet (issue #146) -- ratchet_check() extracted from "
        "210's live source: rise fails and names the specific newly-entered "
        "package(s); fall passes with a 'may be tightened' note naming the "
        "new lower count; equal (by count, regardless of membership churn) "
        "passes silently."
    )

sys.exit(rc)
PYEOF
then
  fail "parity ratchet check failed (see above)"
fi

exit "$fails"
