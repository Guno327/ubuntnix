#!/bin/sh
# tests/lib/ubx-installer-parity-assert.sh -- the GUEST-SIDE assert
# script for the M7 installer-parity exit criterion (SPEC.md sec11; GitHub
# issue #119). This script is meant to run INSIDE a freshly-installed
# ubuntnix system, at the end of an unattended installer run, and print a
# single distinctive pass/fail marker to the console/serial the way
# nix/profiles.nix's `serverParityAssertScript` / `serverParityAssertUnit`
# already do for the non-installer server-parity image (see that file,
# roughly lines 460-540, for the sibling this mirrors almost check-for-
# check).
#
# -- Where this fits, and what issue #117 is expected to do with it --------
#
# Today (pre-#117) there is no bootable `.#installer-iso` flake output and
# no mechanism to bake anything into an installed system at all -- building
# that ISO, and wiring THIS script into it as a systemd oneshot unit (the
# same posture as `serverParityAssertUnit`: `Type=oneshot`,
# `After=multi-user.target`, `WantedBy=multi-user.target`,
# `StandardOutput=journal+console`), is explicitly issue #117's scope, not
# this one's. What issue #119 delivers NOW, ahead of the ISO, is this
# standalone, fully offline-testable script plus its fixture-based unit
# test (tests/unit/208-installer-parity-assert.sh) -- so the checks
# themselves are locked in and proven correct before there is anywhere to
# embed them. The eventual oneshot unit is expected to be a thin wrapper:
# source/copy this script to e.g. /usr/local/bin/ubx-installer-parity-
# assert, run it, and (unlike this script, which never does so itself)
# poweroff the guest on success -- the same division of responsibility
# `serverParityAssertScript` already has from `serverParityAssertUnit`.
#
# -- How this stays correct on a REAL system while being fixture-testable --
#
# Every filesystem path this script touches is prefixed with
# `R="${UBX_PARITY_ROOT:-}"`. On a real installed system `UBX_PARITY_ROOT`
# is unset, so `$R` is empty and every path resolves exactly as it would
# with a literal `/...` prefix (i.e. real root). tests/unit/208's fixture
# test instead points `UBX_PARITY_ROOT` at a `mktemp -d` tree it builds by
# hand, so every check below runs unmodified against synthetic fixture
# data -- no qemu, no nix, no network, no real root access required.
# Likewise, the two external command names this script shells out to
# (`dpkg`, `pro`) are each overridable via `UBX_DPKG` / `UBX_PRO`
# (default: the real `dpkg` / `pro` binaries), so the unit test can point
# them at tiny stub scripts instead of needing real dpkg/pro-client state.
#
# -- The checks, in order (each fails fast: prints
#    "UBX-INSTALLER-PARITY-FAIL: <reason>" and exits 1; ALL passing prints
#    "UBX-INSTALLER-PARITY-PASS" and exits 0) --------------------------------
#
#   1. generation marker:  $R/ubx/generations/current + .../<gen>/marker
#   2. ubx binary:         $R/ubx/bin/ubx is executable
#   3. /flake integrity:   directory, git repo, git-crypt configured, and a
#                          per-machine git-crypt GPG key present
#                          (SPEC.md sec9/sec10)
#   4. GRUB present:       $R/boot/grub/grub.cfg exists
#   5. package-set parity: dpkg -l (via $UBX_DPKG) against the seed/
#                          exception manifests under
#                          $R/ubx/generations/1/ -- the same subset check
#                          `serverParityAssertScript` makes, generalized to
#                          read its expected lists from files instead of
#                          Nix-interpolated constants (this script is not
#                          templated by Nix at all)
#   6. Ubuntu Pro attach:  GATED on UBX_PARITY_EXPECT_PRO=1 -- a no-token
#                          install is valid parity and this check is
#                          skipped entirely otherwise
#   7. `ubx rebuild test`  convergence no-op: proves the installer's
#                          compiled config already equals the running
#                          system, i.e. nothing left to converge
#
# This script does NOT poweroff on success or failure -- that is left to
# the eventual #117 oneshot-unit wrapper, exactly as instructed above.
set -u

R="${UBX_PARITY_ROOT:-}"
DPKG_CMD="${UBX_DPKG:-dpkg}"
PRO_CMD="${UBX_PRO:-pro}"

fail() {
  echo "UBX-INSTALLER-PARITY-FAIL: $1"
  exit 1
}

# -- 1. generation marker ---------------------------------------------------
current="$(cat "$R/ubx/generations/current" 2> /dev/null || true)"
if [ -z "$current" ] || [ ! -f "$R/ubx/generations/$current/marker" ]; then
  fail "generation marker file missing (current='$current')"
fi

# -- 2. ubx binary -----------------------------------------------------------
if [ ! -x "$R/ubx/bin/ubx" ]; then
  fail "$R/ubx/bin/ubx missing or not executable"
fi

# -- 3. /flake integrity (SPEC.md sec9/sec10) --------------------------------
if [ ! -d "$R/flake" ]; then
  fail "$R/flake is not a directory"
fi

if [ ! -e "$R/flake/.git" ]; then
  fail "$R/flake is not a git repository (.git missing)"
fi

if [ ! -f "$R/flake/.gitattributes" ]; then
  fail "$R/flake/.gitattributes missing (git-crypt not configured)"
fi

if ! grep -q 'filter=git-crypt' "$R/flake/.gitattributes"; then
  fail "$R/flake/.gitattributes has no filter=git-crypt line (git-crypt not configured)"
fi

keydir="$R/flake/.git/git-crypt/keys"
if [ ! -d "$keydir" ] || [ -z "$(ls -A "$keydir" 2> /dev/null)" ]; then
  fail "$keydir missing or empty (no per-machine git-crypt key present)"
fi

# -- 4. GRUB present -----------------------------------------------------------
if [ ! -f "$R/boot/grub/grub.cfg" ]; then
  fail "$R/boot/grub/grub.cfg missing"
fi

# -- 5. package-set parity ----------------------------------------------------
seed_file="$R/ubx/generations/1/seed-packages.txt"
if [ ! -f "$seed_file" ]; then
  fail "seed manifest missing ($seed_file)"
fi

exceptions_file="$R/ubx/generations/1/seed-exceptions.txt"

installed="$("$DPKG_CMD" -l | awk '/^ii/ {print $2}' | sed 's/:.*$//' | sort -u)"

missing=""
while IFS= read -r pkg; do
  [ -n "$pkg" ] || continue
  if ! printf '%s\n' "$installed" | grep -qx "$pkg"; then
    missing="$missing $pkg"
  fi
done < "$seed_file"

unexpected=""
if [ -f "$exceptions_file" ]; then
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    if printf '%s\n' "$installed" | grep -qx "$pkg"; then
      unexpected="$unexpected $pkg"
    fi
  done < "$exceptions_file"
fi

if [ -n "$missing" ] || [ -n "$unexpected" ]; then
  fail "missing-seed-packages=[$missing] unexpected-exception-packages=[$unexpected]"
fi

# -- 6. Ubuntu Pro attach (gated) ---------------------------------------------
if [ "${UBX_PARITY_EXPECT_PRO:-0}" = "1" ]; then
  pro_out="$("$PRO_CMD" status --format json 2> /dev/null || true)"
  case "$pro_out" in
    *'"attached": true'* | *'"attached":true'*) ;;
    *) fail "Ubuntu Pro not attached (UBX_PARITY_EXPECT_PRO=1 but 'pro status' did not report attached: true)" ;;
  esac
fi

# -- 7. `ubx rebuild test` convergence no-op ----------------------------------
rebuild_out="$("$R/ubx/bin/ubx" rebuild test 2>&1)"
rebuild_rc=$?
if [ "$rebuild_rc" -ne 0 ]; then
  fail "'ubx rebuild test' exited $rebuild_rc: $rebuild_out"
fi

case "$(printf '%s' "$rebuild_out" | tr '[:upper:]' '[:lower:]')" in
  *'no changes'* | *'no diff'* | *'nothing to do'*) ;;
  *) fail "'ubx rebuild test' did not report convergence (no-op) -- output: $rebuild_out" ;;
esac

echo "UBX-INSTALLER-PARITY-PASS"
exit 0
