#!/usr/bin/env bash
# tests/unit/062-compose-determinism.sh — R1 rootfs-compose determinism
# normalizations (SPEC.md §12 R1; GitHub issue #22, following up on
# issue #9's nix/compose.nix and .github/workflows/ci.yml's compose job).
#
# This harness has no `nix` binary, so whether two independent
# `.#compose-proof` builds actually come out byte-identical can only be
# proven by CI's own "Two-run determinism check" step (which now also
# captures and uploads a precise recursive diff on divergence — see that
# step's own comment in .github/workflows/ci.yml). What CAN be checked
# here, statically, straight from the issue's own suspect list:
#
#   - dpkg --unpack now runs in an EXPLICIT, Nix-generated order (the
#     `unpackLines` binding), not a shell glob over
#     `/.ubx-compose/debs/*.deb` — a glob is deterministic for a FIXED set
#     of filenames, but that's a needless dependency on filesystem/locale
#     globbing behavior for something Nix already knows the order of, and
#     issue #22 called out exactly this as a likely cause of dpkg status/
#     info-database divergence;
#   - PERL_HASH_SEED/PERL_PERTURB_KEYS are pinned in-chroot BEFORE any
#     package is unpacked or configured — Perl's default per-process hash
#     randomization is the leading suspect for debconf .dat record-order
#     divergence;
#   - a canonical final `ldconfig` re-run, plus deletion of the two pure
#     caches issue #22 called out (`/var/cache/ldconfig/aux-cache`,
#     `/var/cache/debconf/*.dat-old`) — all AFTER `dpkg --configure -a`
#     (so they see the fully-configured tree) and BEFORE the pre-existing
#     mtime-epoch-reset/unmount sequence at the end of configure.sh (so
#     whatever they touch/create still gets its mtime normalized, and so
#     ldconfig itself still has a working /proc + real chroot to run in).
#
# And on the CI side (.github/workflows/ci.yml's compose job):
#
#   - the determinism step is STRICT (flipped from warn-only after the
#     first verifiably clean two-run rebuild landed with PR #34 — issue
#     #22's own exit condition): a clean rebuild exits 0, a divergence
#     captures its diff artifacts and then fails the job;
#   - it now captures a recursive diff of the two build outputs on
#     divergence and uploads it as a named CI artifact, via
#     actions/upload-artifact@v4, alongside determinism.log itself.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

compose_nix="nix/compose.nix"
ci_yml=".github/workflows/ci.yml"
for f in "$compose_nix" "$ci_yml"; do
  [ -f "$f" ] || {
    echo "FAIL: $f does not exist" >&2
    exit 1
  }
done

# -- extract the in-chroot configure.sh body (same technique as
# tests/unit/061-compose-preseed-rendering.sh — see that file's own
# comment on why `$` alone, not `^...$`, anchors the heredoc markers).
configure_sh="$(mktemp)"
trap 'rm -f "$configure_sh"' EXIT
sed -n "/<<'UBX_INNER_EOF'\$/,/UBX_INNER_EOF\$/p" "$compose_nix" | sed '1d;$d' > "$configure_sh"

[ -s "$configure_sh" ] ||
  fail "could not statically extract the UBX_INNER_EOF heredoc body from $compose_nix — its shape may have changed"

# -- unpackLines: defined in the Nix `let` block, index-based, one line
# per declared package, joined one-per-line (mirrors debCopyLines exactly
# — same shape, same reasoning, see nix/compose.nix's own comment). -----
grep -q 'unpackLines = builtins.concatStringsSep "\\n"' "$compose_nix" ||
  fail "$compose_nix does not define unpackLines = builtins.concatStringsSep \"\\n\" (...)"

# shellcheck disable=SC2016 # single-quoted on purpose: matching literal
# Nix ${...} interpolation syntax in the source text, not shell expansion.
# `--force-depends` (PR #36): unpack-time Pre-Depends checks run against
# the TRANSIENT mid-sequence state (ubuntu-base's own versions mixed with
# already-unpacked pinned ones) and can fail spuriously on strictly-
# versioned Pre-Depends; the debootstrap idiom forces past that while
# `dpkg --configure -a` (no force flag) still strictly verifies the final
# tree — see nix/compose.nix's unpackLines comment.
grep -qF 'dpkg --unpack --force-depends "/.ubx-compose/debs/${toString i}.deb"' "$compose_nix" ||
  fail "$compose_nix's unpackLines does not emit an index-named absolute dpkg --unpack --force-depends line per package"

# The in-chroot script must actually splice unpackLines in — and must NOT
# still contain the old glob loop (a leftover/duplicate would either
# double-unpack every package or silently make unpackLines dead code).
# shellcheck disable=SC2016 # single-quoted on purpose: matching literal
# Nix ${...} interpolation syntax in the source text, not shell expansion.
grep -qF '${unpackLines}' "$configure_sh" ||
  fail "$configure_sh does not splice \${unpackLines} into the in-chroot unpack step"

if grep -qE 'for +deb +in +/\.ubx-compose/debs/\*\.deb' "$configure_sh"; then
  fail "$configure_sh still contains the old 'for deb in .../*.deb' glob loop alongside \${unpackLines} — should have been replaced, not duplicated"
fi

# -- PERL_HASH_SEED / PERL_PERTURB_KEYS pinned, before any package is
# touched (dpkg --unpack via ${unpackLines}) -----------------------------
grep -qE 'export PERL_HASH_SEED=0[[:space:]]+PERL_PERTURB_KEYS=0' "$configure_sh" ||
  fail "$configure_sh does not export PERL_HASH_SEED=0 PERL_PERTURB_KEYS=0"

perl_seed_line=$(grep -n 'export PERL_HASH_SEED=0' "$configure_sh" | head -1 | cut -d: -f1)
# shellcheck disable=SC2016 # single-quoted on purpose: matching literal
# Nix ${...} interpolation syntax in the source text, not shell expansion.
unpack_line=$(grep -n '\${unpackLines}' "$configure_sh" | head -1 | cut -d: -f1)
if [ -n "$perl_seed_line" ] && [ -n "$unpack_line" ]; then
  [ "$perl_seed_line" -lt "$unpack_line" ] ||
    fail "$configure_sh does not export PERL_HASH_SEED (line $perl_seed_line) BEFORE unpacking packages (line $unpack_line) — any Perl code a preinst/postinst runs during unpack would run unseeded"
fi

# -- ldconfig re-run + the two cache deletions issue #22 calls out, all
# AFTER dpkg --configure -a and BEFORE the pre-existing mtime-reset/
# unmount sequence --------------------------------------------------------
configure_a_line=$(grep -n 'dpkg --configure -a$' "$configure_sh" | head -1 | cut -d: -f1)
ldconfig_line=$(grep -n 'ldconfig$' "$configure_sh" | head -1 | cut -d: -f1)
aux_cache_line=$(grep -n 'rm -f /var/cache/ldconfig/aux-cache' "$configure_sh" | head -1 | cut -d: -f1)
dat_old_line=$(grep -n 'rm -f /var/cache/debconf/\*\.dat-old' "$configure_sh" | head -1 | cut -d: -f1)
# The pre-existing R1 mtime-reset sequence: dev/proc unmount immediately
# followed by the epoch `find / -exec touch` (both already present before
# this issue; only their relative position to the new lines above is
# being checked here).
touch_line=$(grep -n 'find / -exec touch -h -d @0 {} +' "$configure_sh" | head -1 | cut -d: -f1)

for pair_name in "configure_a_line:dpkg --configure -a" "ldconfig_line:ldconfig re-run" "aux_cache_line:aux-cache deletion" "dat_old_line:debconf *.dat-old deletion" "touch_line:final epoch touch"; do
  var="${pair_name%%:*}"
  desc="${pair_name#*:}"
  eval "val=\$$var"
  [ -n "$val" ] || fail "$configure_sh is missing the expected '$desc' line"
done

if [ -n "$configure_a_line" ] && [ -n "$ldconfig_line" ] && [ -n "$aux_cache_line" ] && [ -n "$dat_old_line" ] && [ -n "$touch_line" ]; then
  [ "$configure_a_line" -lt "$ldconfig_line" ] ||
    fail "ldconfig re-run (line $ldconfig_line) does not come AFTER dpkg --configure -a (line $configure_a_line)"
  [ "$ldconfig_line" -lt "$touch_line" ] ||
    fail "ldconfig re-run (line $ldconfig_line) does not come BEFORE the final epoch mtime reset (line $touch_line)"
  [ "$aux_cache_line" -lt "$touch_line" ] ||
    fail "aux-cache deletion (line $aux_cache_line) does not come BEFORE the final epoch mtime reset (line $touch_line)"
  [ "$dat_old_line" -lt "$touch_line" ] ||
    fail "debconf *.dat-old deletion (line $dat_old_line) does not come BEFORE the final epoch mtime reset (line $touch_line)"
fi

# -- the live debconf *.dat files themselves must NOT be deleted or
# rewritten by this file — issue #22 explicitly allows "accepted
# divergence" for these, documented in nix/compose.nix's own header, and
# a normalization attempt here would be scope creep beyond what's been
# verified safe. -----------------------------------------------------------
if grep -qE "rm[^\\n]*/var/cache/debconf/(config|templates)\\.dat[^-]" "$configure_sh"; then
  fail "$configure_sh appears to delete/touch the live debconf config.dat/templates.dat — issue #22 documents these as accepted divergence, not something to delete"
fi

# -- the R1 header inventory comment was actually updated (not just the
# script) — spot-check for issue #22's own marker and the two documented
# "NOT normalized" residual risks. -----------------------------------------
grep -q 'issue #22' "$compose_nix" ||
  fail "$compose_nix's header comment does not mention issue #22"
grep -q '/etc/ld.so.cache' "$compose_nix" ||
  fail "$compose_nix's header comment does not document /etc/ld.so.cache's determinism status"

# -- .github/workflows/ci.yml: the determinism step captures a diff on
# divergence and uploads it, then fails the job (strict) -------------------
grep -qE -- '--keep-failed|-K\b' "$ci_yml" ||
  fail "$ci_yml's determinism step does not pass --keep-failed/-K to nix build --rebuild"

grep -qF '.check' "$ci_yml" ||
  fail "$ci_yml's determinism step does not account for Nix's documented '.check' kept-output path"

grep -qE 'diff -rq' "$ci_yml" ||
  fail "$ci_yml's determinism step does not run a file-level diff -rq summary"

grep -qE 'diff -r --no-dereference' "$ci_yml" ||
  fail "$ci_yml's determinism step does not run a full recursive diff -r --no-dereference"

grep -qF 'actions/upload-artifact@v4' "$ci_yml" ||
  fail "$ci_yml does not use actions/upload-artifact@v4 anywhere"

grep -qE 'name: determinism-log' "$ci_yml" ||
  fail "$ci_yml does not upload a determinism-log artifact"
grep -qE 'name: determinism-diff' "$ci_yml" ||
  fail "$ci_yml does not upload a determinism-diff artifact"

# Both upload steps must run unconditionally (the divergence files only
# exist SOMETIMES, and now that the determinism-check step FAILS the job
# on divergence, if: always() is what keeps the diagnosis artifacts
# flowing on exactly the runs that need them most).
determinism_log_block=$(awk '/- name: Upload determinism log/{p=1} p{print} p && /if-no-files-found:/{exit}' "$ci_yml")
echo "$determinism_log_block" | grep -q 'if: always()' ||
  fail "the 'Upload determinism log' step is not guarded with if: always()"
echo "$determinism_log_block" | grep -q 'if-no-files-found: ignore' ||
  fail "the 'Upload determinism log' step does not set if-no-files-found: ignore"

determinism_diff_block=$(awk '/- name: Upload determinism diff/{p=1} p{print} p && /if-no-files-found:/{exit}' "$ci_yml")
echo "$determinism_diff_block" | grep -q 'if: always()' ||
  fail "the 'Upload determinism diff' step is not guarded with if: always()"
echo "$determinism_diff_block" | grep -q 'if-no-files-found: ignore' ||
  fail "the 'Upload determinism diff' step does not set if-no-files-found: ignore"

# -- STRICT: the determinism-check step must exit 0 on the clean path AND
# exit non-zero on the divergence path (issue #22's exit condition: the
# step flipped from warn-only to failing once a clean two-run rebuild
# landed; a step that could no longer fail would silently regress R1
# coverage, and one that could no longer pass would block every PR). ------
determinism_step_block=$(awk '
  /- name: Two-run determinism check/ { p = 1 }
  p { print }
  p && /- name: Upload determinism log/ { exit }
' "$ci_yml")

echo "$determinism_step_block" | grep -qE '^\s*exit\s+[1-9]' ||
  fail "$ci_yml's determinism-check step never exits non-zero — divergence must fail the job (strict mode, issue #22)"

echo "$determinism_step_block" | grep -q 'exit 0' ||
  fail "$ci_yml's determinism-check step does not explicitly exit 0 on the clean path"

echo "$determinism_step_block" | grep -q '::error::' ||
  fail "$ci_yml's determinism-check step does not emit a ::error:: annotation on divergence"

exit "$fails"
