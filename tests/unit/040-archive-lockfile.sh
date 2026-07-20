#!/usr/bin/env bash
# tests/unit/040-archive-lockfile.sh — archive.lock.json schema validation
# (SPEC.md §4.4; GitHub issue #7, milestone M1).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so nix/archive.nix's own
# `builtins.fromJSON` parse can't be exercised here — that's CI-only (the
# "flake" job in .github/workflows/ci.yml, which builds
# `.#archive-fetch-proof` / `.#archive-hash-mismatch-proof`). This test
# instead validates the lockfile's SHAPE directly with python3's `json`
# module, against the schema documented in nix/archive.nix's header
# comment — exactly as any other non-Nix tool (a future `ubx update`, docs
# tooling, CI) would read it. No network access happens here: the file is
# read from disk exactly as committed.
#
# The actual schema check lives in tests/lib/validate-archive-lockfile.py
# (extracted here, verbatim, in issue #8/M1) so bin/ubx-resolve's own
# output — tests/unit/051-archive-resolve-emit.sh, and CI's "resolve"
# job — is held to the exact same one definition of the schema, not a
# second copy that could quietly drift from this one.
set -u

cd "$UBX_REPO_ROOT" || exit 1

lockfile="archive.lock.json"

[ -f "$lockfile" ] || {
  echo "FAIL: $lockfile does not exist" >&2
  exit 1
}

python3 "$UBX_REPO_ROOT/tests/lib/validate-archive-lockfile.py" "$lockfile"
