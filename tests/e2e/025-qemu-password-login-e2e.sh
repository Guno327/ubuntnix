#!/usr/bin/env bash
# shellcheck disable=SC2317  # main()'s tail is intentionally unreachable
# today: an unconditional load-bearing skip (see main()) sits above the
# real qemu-launch/marker-grep body, which is kept verbatim as the shape a
# future nix/boot.nix login-marker driver fills in (GitHub issue #80 e2e
# follow-up). shellcheck's reachability analysis correctly flags it; the
# code is deliberate, so SC2317 is disabled file-wide here.
# tests/e2e/025-qemu-password-login-e2e.sh — QEMU end-to-end proof that a
# user declared with `hashedPasswordSecret` can log in with the
# corresponding password after `ubx rebuild switch` (SPEC.md §6, §8.1,
# §11 M4; GitHub issue #80, milestone M4, "password login from a
# secret-sourced hash"). Structural sibling of
# tests/e2e/020-qemu-switch-e2e.sh: same image-copy/multi-boot/serial-log
# machinery, same `qemu-system-x86_64`/`nix` availability contract, same
# `UBX-*-PASS`/`UBX-*-FAIL`/exit-77-skip posture.
#
# -- What this test asserts, once wired -------------------------------------
#
# Boots a disk image whose switch-loop driver (nix/boot.nix's
# `switchLoopDriverScript`, or a sibling of it) has, as part of its own
# guest-side phase machinery:
#   1. a declared `ubuntnix.users.<name>.hashedPasswordSecret` user, backed
#      by a real (fixture, non-production) secret materialized under
#      `/run/secrets/<name>` by the secrets domain (issue #78) BEFORE
#      `ubx rebuild switch` converges the users domain (issue #80's own
#      ordering requirement — see bin/ubx's own `execute_domains` header);
#   2. a guest-side login check (e.g. `su - <name> -c true` fed the known
#      plaintext password against the hash `apply-passwords` just wrote to
#      `/etc/shadow`, or an equivalent PAM-driven check) that prints
#      `UBX-M4-PW-PASS` on success, `UBX-M4-PW-FAIL: <reason>` on failure
#      -- exactly the `UBX-M2-Sn-PASS`/`-FAIL` convention
#      tests/e2e/020-qemu-switch-e2e.sh's own header documents, so this
#      harness can reuse that file's "trust only what the guest itself
#      asserted to serial" posture verbatim.
#
# -- Why this SKIPS unconditionally in EVERY environment today --------------
#
# Unlike tests/e2e/020 (whose `.#switch-loop-proof` image genuinely exists
# and exercises real M2 scenarios), nix/boot.nix's switch-loop-proof does
# NOT yet declare a `hashedPasswordSecret` user or emit the
# `UBX-M4-PW-PASS`/`-FAIL` marker this test looks for — wiring a real
# secret-backed guest account and a real login check into that (large,
# ~3000-line) driver script is tracked, real follow-up work this issue's
# own PM scoped separately from bin/ubx-users' own planner/executor (this
# repo's dev harness has neither `nix` nor `qemu-system-x86_64` to build or
# run that image against in the first place, so nothing here could be
# validated even if the wiring existed — see tests/README.md's e2e
# contract, and tests/unit/106-ubx-users-password-secret.sh /
# tests/unit/10[789]-*.sh for the REAL, currently-exercised unit coverage
# of every piece this e2e proof would eventually assemble: manifest/plan
# purity, apply-passwords' real shadow convergence from a fixture
# `/run/secrets/<name>` file, the missing/unreferenced-secret error, and
# `ubx rebuild`'s own secrets-before-users ordering).
#
# This script is therefore written to the same shape/contract as its M2
# sibling (so a future PR that adds the guest-side wiring above only needs
# to change nix/boot.nix plus this file's own MARKERS array/--image
# resolution, not invent a new harness) but SKIPS (exit 77) immediately,
# unconditionally, with a message naming this exact gap — never silently
# "passing" a scenario nothing actually exercised, and never spuriously
# failing CI for a feature its own image doesn't build yet.
set -u

prog_name="025-qemu-password-login-e2e.sh"

usage() {
  cat <<USAGE
usage: 025-qemu-password-login-e2e.sh [options]

Would boot a ubuntnix disk image declaring a hashedPasswordSecret user and
assert a real password login succeeds after 'ubx rebuild switch' (serial
marker UBX-M4-PW-PASS) -- see this script's own header for exactly why it
currently SKIPS unconditionally (nix/boot.nix's switch-loop-proof does not
yet declare such a user or emit that marker; this is a tracked, documented
follow-up, not an oversight).

options:
  --image PATH        raw disk image to boot, OR a directory containing
                       disk.img. Default: \$UBX_PW_LOGIN_IMAGE if set, else
                       built on the fly via \`nix build\` if \`nix\` is on
                       PATH (once a real target exists -- see this script's
                       header).
  --timeout SECONDS    hard wall-clock timeout PER BOOT (default: 240).
  --keep-log FILE      also copy the full serial console log here.
  -h, --help           show this message

Exit codes: 0 pass, 1 fail, 2 bad arguments, 77 skip (this dev harness has
neither \`qemu-system-x86_64\` nor \`nix\`, AND/OR -- unconditionally, today
-- nix/boot.nix has no hashedPasswordSecret-login-checking image target
yet; see this script's own header).
USAGE
}

die() {
  echo "$prog_name: $*" >&2
  exit 1
}

skip() {
  echo "$prog_name: SKIP: $*" >&2
  exit 77
}

# The marker a real guest-side login-check phase would print -- kept here,
# unused today, so a future implementation's own grep target is already
# named and documented in exactly one place.
readonly MARKERS=(UBX-M4-PW-PASS)

main() {
  local image="" timeout=240 keep_log=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --image)
        [ $# -ge 2 ] || die "--image requires an argument"
        image="$2"
        shift 2
        ;;
      --timeout)
        [ $# -ge 2 ] || die "--timeout requires an argument"
        timeout="$2"
        shift 2
        ;;
      --keep-log)
        [ $# -ge 2 ] || die "--keep-log requires an argument"
        keep_log="$2"
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        echo "$prog_name: unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  [[ "$timeout" =~ ^[0-9]+$ ]] || die "--timeout must be a non-negative integer, got: $timeout"
  # keep_log accepted for CLI-shape parity with 020's own flag set, but this
  # script never reaches a real boot to populate it -- see this file's
  # header for why.
  : "$keep_log"

  # This is the load-bearing skip: see this script's own header,
  # "Why this SKIPS unconditionally in EVERY environment today". Checked
  # BEFORE the qemu/image resolution below (which 020's own SKIP checks
  # come first for) so a caller sees the REAL blocker (no image/marker
  # wiring exists yet) rather than a misleading "qemu not found" message
  # on a machine that actually has qemu installed.
  skip "nix/boot.nix has no hashedPasswordSecret-declaring, UBX-M4-PW-PASS-emitting image target yet (GitHub issue #80's own e2e half is tracked, documented follow-up -- see this script's header; tests/unit/106-ubx-users-password-secret.sh and tests/unit/10[789]-*.sh already exercise every piece this proof would assemble, at the unit level, in this same change)"

  # -- unreachable today (see the unconditional skip above), kept as the
  # real shape a future implementation fills in -- mirrors
  # tests/e2e/020-qemu-switch-e2e.sh's own image-resolution/qemu-launch/
  # marker-grep structure so that future change is a small diff, not a
  # rewrite.
  command -v qemu-system-x86_64 > /dev/null 2>&1 ||
    skip "qemu-system-x86_64 not found on PATH -- install qemu-system-x86 (apt) or run this on a host that has it"

  if [ -z "$image" ]; then
    image="${UBX_PW_LOGIN_IMAGE:-}"
  fi
  [ -n "$image" ] || skip "no --image/\$UBX_PW_LOGIN_IMAGE given, and no real nix build target exists yet for this proof"

  if [ -d "$image" ]; then
    image="$image/disk.img"
  fi
  [ -f "$image" ] || die "disk image does not exist: $image"

  echo "$prog_name: would now boot $image and grep for ${MARKERS[*]} (timeout=${timeout}s) -- this code path is currently unreachable, see this script's header" >&2
  exit 1
}

main "$@"
