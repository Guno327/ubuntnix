#!/usr/bin/env bash
# tests/unit/061-compose-preseed-rendering.sh — debconf preseed rendering,
# static logic checks (SPEC.md §6 `ubuntnix.debconf`; GitHub issue #9).
#
# This harness has no `nix` binary, so `renderPreseed`/the in-chroot
# 3-field-to-4-field expansion can't be exercised end-to-end here (that's
# CI-only: the "compose" job in .github/workflows/ci.yml builds
# `.#compose-preseed-proof` and asserts its real effect on
# /etc/timezone + /etc/localtime). This test instead statically re-derives,
# from nix/compose.nix's own documented format, what a *correct*
# implementation must do, and checks the source text actually does it:
#
#   - renderPreseed's own eval-time guards (reject tab/newline in a value,
#     and in a package/question name) must exist, or a malformed preseed
#     would silently corrupt the one-record-per-line format instead of
#     failing loudly;
#   - the emitted record shape must be exactly the documented 3-field
#     tab-separated "pkg<TAB>question<TAB>value" (NOT the 4-field
#     debconf-set-selections form -- that conversion is documented to
#     happen later, inside the chroot, once each package's own .templates
#     file exists);
#   - the in-chroot awk conversion must actually read Type from each
#     package's own registered template (not hardcode a type, except as an
#     explicit fallback) and default to "string" for an unregistered
#     question, matching debconf's own fallback behavior;
#   - `debconf-set-selections` must actually be invoked with the expanded
#     4-field output, and only if the 3-field input is non-empty;
#   - packages must be dpkg --unpack'd (registering their templates)
#     strictly BEFORE the preseed is applied, and dpkg --configure must run
#     strictly AFTER -- get this ordering backwards and preseeding is a
#     silent no-op.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

compose_nix="nix/compose.nix"
[ -f "$compose_nix" ] || {
  echo "FAIL: $compose_nix does not exist" >&2
  exit 1
}

# -- renderPreseed's eval-time guards ---------------------------------------
grep -q 'renderPreseed = preseed:' "$compose_nix" ||
  fail "$compose_nix does not define renderPreseed = preseed: ..."

# Note: greps below use fixed strings (-F) copied verbatim from
# nix/compose.nix's own source, rather than -E regexes with escaped
# backslash-tab/backslash-n sequences — a literal backslash in an -E
# pattern needs care (a doubled backslash matches ONE literal backslash;
# getting this wrong makes the check silently unmatchable), and -F sidesteps
# the whole class of mistake for these exact-text checks.
grep -qF 'lib.hasInfix "\t" v || lib.hasInfix "\n" v' "$compose_nix" ||
  fail "$compose_nix's renderPreseed does not reject a literal tab or newline in a preseed value"

grep -qF 'lib.hasInfix "\t" pkg || lib.hasInfix "\t" q' "$compose_nix" ||
  fail "$compose_nix's renderPreseed does not reject a literal tab in a package/question name"

grep -q 'must be a string value, got' "$compose_nix" ||
  fail "$compose_nix's renderPreseed does not reject a non-string preseed value"

# -- the emitted record shape -----------------------------------------------
#
# Exactly the documented 3-field tab-separated record: pkg, a literal tab,
# question, a literal tab, value -- as a single interpolated Nix string.
# shellcheck disable=SC2016 # single-quoted on purpose: matching literal
# Nix ${...} interpolation syntax in the source text, not shell expansion.
grep -qF '"${pkg}\t${q}\t${v}"' "$compose_nix" ||
  fail "$compose_nix's renderPreseed does not emit the documented 3-field tab-separated record (pkg<TAB>question<TAB>value)"

# Records are joined one-per-line (concatStringsSep "\n"), not some other
# separator that would break the downstream `awk -F'\t'` line-oriented
# parser.
grep -qF 'concatStringsSep "\n"' "$compose_nix" ||
  fail "$compose_nix's renderPreseed does not join records one-per-line"

# -- ordering: unpack (registers templates) BEFORE preseed BEFORE configure --
#
# Extract the in-chroot configure.sh body: the text between the line that
# opens the `<<'UBX_INNER_EOF'` heredoc and the first subsequent line that
# is its closing delimiter. Both lines carry the SAME leading whitespace as
# every other line in this script's enclosing Nix `''...''` string (Nix's
# indented-string dedent later strips that common prefix from all of them
# uniformly, including the delimiter itself, which is what makes an
# indented-looking heredoc terminator actually flush-left, and thus valid,
# once Nix evaluates it) — so this extraction does not anchor `^` on the
# closing delimiter, only `$` (end of line), matching either marker line
# regardless of its shared leading indentation.
configure_sh="$(mktemp)"
trap 'rm -f "$configure_sh"' EXIT
sed -n "/<<'UBX_INNER_EOF'\$/,/UBX_INNER_EOF\$/p" "$compose_nix" | sed '1d;$d' > "$configure_sh"

[ -s "$configure_sh" ] ||
  fail "could not statically extract the UBX_INNER_EOF heredoc body from $compose_nix — its shape may have changed"

# Match the actual invocation lines only (exact argument text), not any of
# the surrounding comments that also happen to mention these command names
# in prose (e.g. "... the template file dpkg --unpack just registered") —
# a bare `grep 'dpkg --unpack'` would find the comment first and report a
# too-early line number, defeating the ordering check entirely.
#
# Since GitHub issue #22 (R1 determinism), the unpack step is no longer a
# literal `for deb in *.deb; do dpkg --unpack "$deb"; done` glob loop
# inline in this heredoc — it's the single interpolated placeholder
# `${unpackLines}`, a Nix `let` binding (defined alongside `debCopyLines`
# in nix/compose.nix, exercised separately in tests/unit/062) that
# expands, at EVAL time, to one explicit `dpkg --unpack ".../N.deb"` line
# per declared package in declaration order — see that file's own inline
# R1 comment for why (pinning unpack order off Nix's own list, not shell/
# filesystem glob-matching behavior). This static extraction only ever
# sees the un-evaluated Nix source text, so it must look for the
# placeholder itself, not its expansion.
# shellcheck disable=SC2016 # single-quoted on purpose: matching a literal
# Nix ${...} interpolation substring in the extracted script text, not
# expanding it in THIS (the test's own) shell.
unpack_line=$(grep -n '\${unpackLines}' "$configure_sh" | head -1 | cut -d: -f1)
selections_line=$(grep -n 'debconf-set-selections /.ubx-compose/preseed.selections' "$configure_sh" | head -1 | cut -d: -f1)
# Anchored on end-of-line ($): nix/compose.nix's own R1 comment (issue
# #22) now mentions "dpkg --configure -a" in PROSE too (of the ldconfig
# re-run's rationale) — an unanchored match would find that comment first
# and report a too-early line number, same class of bug this whole block
# already guards the unpack/selections lines against.
configure_line=$(grep -n 'dpkg --configure -a$' "$configure_sh" | head -1 | cut -d: -f1)

if [ -z "$unpack_line" ] || [ -z "$selections_line" ] || [ -z "$configure_line" ]; then
  fail "$compose_nix's in-chroot script is missing one of: \${unpackLines}, debconf-set-selections, dpkg --configure"
else
  [ "$unpack_line" -lt "$selections_line" ] ||
    fail "$compose_nix does not dpkg --unpack (line $unpack_line) BEFORE debconf-set-selections (line $selections_line) — preseeding would run before any package's templates are registered"
  [ "$selections_line" -lt "$configure_line" ] ||
    fail "$compose_nix does not debconf-set-selections (line $selections_line) BEFORE dpkg --configure (line $configure_line) — preseed answers would not be in place before maintainer scripts run"
fi

# debconf-set-selections must be guarded on the 3-field input containing
# real (non-whitespace) content -- NOT merely `[ -s ]`: the staging heredoc
# writes a trailing newline even for an empty preseed set, so a size check
# alone let compose-proof's blank line reach the awk expansion and produce
# a degenerate record debconf-set-selections rejects (CI run 29785981711,
# "parse error on line 1").
grep -q "if grep -q '\[\^\[:space:\]\]' /.ubx-compose/preseed.txt" "$configure_sh" ||
  fail "$compose_nix does not guard debconf-set-selections on non-whitespace preseed.txt content"

# ... and the awk expansion itself must skip blank lines for the same
# reason (stray blank lines between records).
grep -q '/\^\[\[:space:\]\]\*\$/ { next }' "$configure_sh" ||
  fail "$compose_nix's preseed awk expansion does not skip blank lines"

# -- 3-field -> 4-field expansion: real Type lookup, string fallback -------
grep -q 'templates' "$configure_sh" ||
  fail "$compose_nix's in-chroot script does not read each package's own .templates file for the preseed Type"

grep -qE 'type = "string"' "$configure_sh" ||
  fail "$compose_nix's in-chroot script does not default an unregistered question's type to \"string\" (debconf's own fallback behavior)"

grep -q 'Type: ' "$configure_sh" ||
  fail "$compose_nix's in-chroot script does not parse a 'Type: ' field out of the package's .templates file"

# -- compose-preseed-proof's own preseed must exercise all of the above -----
#
# tzdata's real postinst effect: SPEC.md §6 preseed reaching a maintainer
# script, not a fixed default (see nix/compose.nix's own comment on why
# America/New_York, not Etc/UTC).
grep -q '"tzdata/Areas" = "America"' "$compose_nix" ||
  fail "$compose_nix's compose-preseed-proof does not set tzdata/Areas"
grep -q '"tzdata/Zones/America" = "New_York"' "$compose_nix" ||
  fail "$compose_nix's compose-preseed-proof does not set tzdata/Zones/America"

# compose-proof (no preseed) must stay preseed-free, so it stays the narrow
# "mechanism only" proof its own comment says it is, not accidentally
# growing a preseed of its own that would blur the two proofs' distinct
# jobs.
# NOTE: `[ \t]` not `\s` in the exit pattern below — mawk (Ubuntu's default
# /usr/bin/awk, and this harness's) does not understand the GNU/PCRE `\s`
# shorthand, so a `\s`-based pattern here would silently never match and
# this extraction would run away to end-of-file.
compose_proof_block=$(awk '/composeProof = composeRootfs \{/{p=1} p{print} p && /^[ \t]*\};[ \t]*$/{exit}' "$compose_nix")
if echo "$compose_proof_block" | grep -q 'preseed ='; then
  fail "compose-proof (issue #9's no-preseed mechanism proof) unexpectedly sets its own preseed"
fi

exit "$fails"
