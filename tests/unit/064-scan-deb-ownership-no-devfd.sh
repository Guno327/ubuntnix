#!/usr/bin/env bash
# tests/unit/064-scan-deb-ownership-no-devfd.sh — static guard: bin/ubx-
# scan-deb-ownership must never require /dev/fd.
#
# GitHub issue #10 PR #36, CI run 29953677609: the "Rootfs composition" job
# died with
#
#   rootfs-compose-proof> /.ubx-compose/ubx-scan-deb-ownership: line 180:
#   /dev/fd/63: No such file or directory
#
# because that script's scan() loop read its `dpkg-deb --fsys-tarfile |
# tar -tv` listing via a `done < <(...)` process substitution, and process
# substitution is implemented by bash opening a /dev/fd/N path. nix/
# compose.nix's enter.sh runs this script inside a chroot whose only /dev
# entries are the explicit bind mounts it lists (null, zero, random,
# urandom, ...) plus a freshly mounted /proc — there is no /dev/fd and no
# /proc/self/fd symlink in there, so ANY construct that needs /dev/fd
# (process substitution `<(...)`/`>(...)`, or an explicit /dev/fd//
# /dev/stdin//dev/stdout//dev/stderr path) reliably kills the script
# inside the real compose sandbox, even though every one of those
# constructs works fine on an ordinary dev machine or CI runner outside a
# chroot — which is exactly why this had to be a real functional test
# fixture rather than something tests/unit/063-compose-ownership-scan.sh's
# behavioural coverage would ever catch: 063 runs the script directly on
# the host, where /dev/fd exists.
#
# This test is a plain source-text guard instead: it fails loudly if any
# /dev/fd-requiring construct is ever reintroduced into the script,
# without needing to actually reproduce the chroot. Here-strings (`<<<`)
# and here-docs (`<<EOF`) are NOT flagged — bash implements those with a
# temp file or an anonymous pipe, never /dev/fd — so this script's own
# `read -r mode owner rest <<<"$line"` (~line 194) is fine and deliberately
# left alone.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

scan="$UBX_REPO_ROOT/bin/ubx-scan-deb-ownership"
[ -f "$scan" ] || {
  echo "FAIL: $scan does not exist" >&2
  exit 1
}

# This script's own header/inline comments legitimately DISCUSS process
# substitution and /dev/fd in prose (explaining why they're forbidden —
# see scan()'s comment block above its temp-file setup), so a naive grep
# over the whole file would false-positive on the documentation itself.
# Strip full-line comments (lines whose first non-blank character is '#')
# before scanning, restricting the check to actual code.
code="$(grep -vE '^[[:space:]]*#' "$scan")"

# Process substitution: `<(...)` or `>(...)`. Matched as literal
# "<(" / ">(" — distinct from "<<<" (here-string) and "<<" (here-doc),
# neither of which contains a bare "(" right after the redirection
# operator.
if printf '%s\n' "$code" | grep -nE '(^|[^<])<\(|>\(' > /dev/null 2>&1; then
  fail "$scan contains a process-substitution construct ('<(' or '>(') — this needs /dev/fd, which does not exist inside nix/compose.nix's enter.sh chroot (CI run 29953677609)"
  printf '%s\n' "$code" | grep -nE '(^|[^<])<\(|>\(' >&2
fi

# Explicit /dev/fd, /dev/stdin, /dev/stdout, /dev/stderr paths: even
# without process substitution syntax, a script could reference one of
# these directly (e.g. `cat /dev/stdin`) and hit the exact same missing-
# path failure in the chroot.
if printf '%s\n' "$code" | grep -nE '/dev/(fd|stdin|stdout|stderr)\b' > /dev/null 2>&1; then
  fail "$scan references /dev/fd, /dev/stdin, /dev/stdout, or /dev/stderr directly — none of these exist inside nix/compose.nix's enter.sh chroot (CI run 29953677609)"
  printf '%s\n' "$code" | grep -nE '/dev/(fd|stdin|stdout|stderr)\b' >&2
fi

# The specific fix this test guards: the tar listing must be fed to the
# scan loop via an explicit temp file (`done < "$tmp"`, not
# `done < <(...)`) — assert the surviving form is actually present, so a
# future refactor that drops BOTH the process substitution AND the
# temp-file redirect (e.g. by moving the loop inside a `cmd | while read`
# pipeline, which would silently lose the loop body's variables to a
# subshell — see this script's own comment above scan()'s temp-file
# setup) is caught too, not just the reintroduction of `<(`.
# shellcheck disable=SC2016 # literal '$tmp' text in the script's source, not an expansion here
grep -nE 'done < "\$tmp"' "$scan" > /dev/null 2>&1 ||
  fail "$scan no longer feeds its scan loop from an explicit temp file ('done < \"\$tmp\"') — check it hasn't regressed to a /dev/fd-requiring or subshell-losing-variables construct"

exit "$fails"
