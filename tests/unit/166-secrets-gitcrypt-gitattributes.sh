#!/usr/bin/env bash
# tests/unit/166-secrets-gitcrypt-gitattributes.sh — secrets/.gitattributes
# (SPEC.md §8.1 "`/flake/secrets/` is a git-crypt-encrypted folder ... via
# `.gitattributes` patterns"; GitHub issue #79, milestone M4 groundwork).
# Static checks only -- no git/git-crypt/gpg binary required, so this test
# always runs (never skips): it asserts the SHAPE of the encryption
# boundary this issue's own design decision produces, independent of
# whether any external tool is installed on this dev box.
#
#   1. secrets/.gitattributes exists and opts everything under secrets/
#      into the git-crypt filter by default.
#   2. Exactly two paths are carved back OUT of that default (left clear):
#      .gitattributes itself (git-crypt's own documented convention -- an
#      encrypted .gitattributes is a chicken-and-egg deadlock for a fresh
#      clone) and index.nix (this issue's own decision -- see
#      secrets/.gitattributes' own comment and docs/secrets.md's "Why
#      index.nix is left clear" for the full rationale).
#   3. secrets/index.nix itself exists, is a template matching SPEC.md
#      §8.1's own declared-index shape, and -- since it is deliberately
#      left CLEAR -- never contains anything that looks like real secret
#      material (only `src = ./filename;` references, exactly
#      nix/secrets.nix's own "THE ABSOLUTE INVARIANT" already requires of
#      every consumer of this shape).
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

attrs="secrets/.gitattributes"
[ -f "$attrs" ] || {
  echo "FAIL: $attrs does not exist" >&2
  exit 1
}

# -- (1) everything defaults to git-crypt-encrypted -------------------------
grep -qE '^\*[[:space:]]+filter=git-crypt[[:space:]]+diff=git-crypt[[:space:]]*$' "$attrs" ||
  fail "$attrs does not opt every path in by default with a bare '* filter=git-crypt diff=git-crypt' rule"

# -- (2) exactly .gitattributes and index.nix are carved back out -----------
grep -qE '^\.gitattributes[[:space:]]+!filter[[:space:]]+!diff[[:space:]]*$' "$attrs" ||
  fail "$attrs does not leave .gitattributes itself unencrypted (!filter !diff) -- required so a fresh clone can read it at all"

grep -qE '^index\.nix[[:space:]]+!filter[[:space:]]+!diff[[:space:]]*$' "$attrs" ||
  fail "$attrs does not leave index.nix unencrypted (!filter !diff) -- this issue's own decision (references only, no material -- see docs/secrets.md)"

# No OTHER bare-path exception lines beyond those two (a stray extra
# carve-out would silently widen what ships in cleartext).
exception_lines="$(grep -cE '!filter[[:space:]]+!diff' "$attrs")"
[ "$exception_lines" -eq 2 ] ||
  fail "$attrs has $exception_lines '!filter !diff' exception line(s), expected exactly 2 (.gitattributes, index.nix)"

# -- (3) secrets/index.nix: exists, template shape, no material -------------
index="secrets/index.nix"
[ -f "$index" ] || {
  echo "FAIL: $index does not exist" >&2
  exit 1
}

grep -qE '^\s*src = \./' "$index" ||
  fail "$index does not declare at least one secret via 'src = ./<file>;' (SPEC.md §8.1's own index shape)"

# Never a raw material-looking value: no long base64/hex blob, no
# "-----BEGIN" PGP/PEM marker, nothing assigned to anything but a `src`
# path / plain identifier / short string field value.
if grep -qE -- '-----BEGIN' "$index"; then
  fail "$index contains what looks like real embedded key/cert material (a '-----BEGIN' marker) -- index.nix must carry references only"
fi

# -- docs wiring: index.md's toctree references a secrets page --------------
grep -qE '^secrets$' docs/index.md ||
  fail "docs/index.md's toctree does not list 'secrets' -- docs/secrets.md must be wired in"

grep -qF "{doc}\`secrets\`" docs/index.md ||
  fail "docs/index.md's Guides list does not link {doc}\`secrets\`"

[ -f docs/secrets.md ] || {
  echo "FAIL: docs/secrets.md does not exist" >&2
  exit 1
}

exit "$fails"
