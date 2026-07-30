#!/usr/bin/env bash
# tests/e2e/080-qemu-installer-parity-e2e.sh — QEMU end-to-end
# installer-parity boot test (SPEC.md §11 M7 exit criterion: "USB-booted
# physical install [proven in CI as] ISO -> USB -> installer -> system ≡
# upstream Desktop/Server install"; GitHub issue #119).
#
# -- What the EVENTUAL full proof asserts ------------------------------------
#
# Once issue #117 lands a real bootable ubuntnix installer ISO (`.#installer-
# iso`, currently absent from flake.nix's `packages` — that ISO build is
# owner-blocked work, out of scope for this harness), this script's full
# proof is meant to:
#
#   1. Boot the installer ISO in QEMU with a blank target disk attached.
#   2. Drive the installer non-interactively through a compiled set of
#      installer answers (nix/installer.nix's `compileAnswers`, issue #113)
#      — i.e. an autoinstall-style unattended run, not a human clicking
#      through subiquity.
#   3. Power off/reboot out of the installer and boot the FRESHLY INSTALLED
#      system off the target disk (no more -cdrom).
#   4. Assert, from what the installed guest itself prints to serial (this
#      harness never inspects the guest filesystem directly — same posture
#      as every other tests/e2e/*.sh in this suite):
#        - package-set parity against the upstream Desktop/Server seed,
#          minus the enumerated nix/profiles.nix exceptions (SPEC.md §11 R11,
#          issue #118 — the same parity check tests/e2e/050 and 070 already
#          make for the non-installer parity images, now proven end-to-end
#          from a real installer run instead of a pre-baked image);
#        - `/flake` exists, is a git repository, is git-crypt-protected, and
#          contains the machine's own generated GPG key (SPEC.md §10's "the
#          installer generates a machine identity" / §9's per-machine key
#          model);
#        - Ubuntu Pro attach succeeded if a token was supplied to the
#          compiled answers (SPEC.md §10);
#        - a generation marker and GRUB configuration are present (the same
#          baseline tests/e2e/010-qemu-boot-e2e.sh checks for a non-installer
#          image, now checked on installer OUTPUT instead of a pre-built
#          image);
#        - `ubx rebuild switch` run again on the freshly installed system
#          converges cleanly (no diff / a clean no-op switch), proving the
#          installer's compiled config and the running system agree.
#      The distinctive marker for that eventual full pass is
#      UBX-INSTALLER-PARITY-PASS, emitted by an in-guest assert service the
#      way UBX-DESKTOP-PARITY-PASS/UBX-SERVER-PARITY-PASS are today.
#
# -- What this script actually is, TODAY -------------------------------------
#
# None of the above exists yet. There is no `.#installer-iso` build target,
# no autoinstall answers wiring, and — CRITICALLY — no in-ISO guest-side
# assert service to emit UBX-INSTALLER-PARITY-PASS: building that service is
# explicitly deferred to issue #117 alongside the ISO itself, exactly as
# #117's scope says, and is NOT this harness's job. This script exists now,
# ahead of the ISO, so that:
#   (a) the CLI surface, skip contract, and CI wiring are locked in and
#       tested BEFORE the ISO lands (tests-first, per CONTRIBUTING.md);
#   (b) the moment #117 lands a real `.#installer-iso` and its own assert
#       service starts emitting UBX-INSTALLER-PARITY-PASS, this harness
#       starts passing for real with no changes needed beyond removing this
#       paragraph.
# This host-side harness, like its 010/050/070 siblings, only ever trusts
# what the guest prints to serial — it is not, and will never be, the thing
# that decides parity; the in-ISO assert service is.
#
# -- Why this can legitimately SKIP (exit 77), and why that is EXPECTED -----
#
# tests/README.md's own rule: "E2E tests may require KVM and declare it by
# exiting 77 (skip) when unavailable." That contract, applied here, means
# skip whenever no bootable installer ISO can be resolved at all — which,
# until #117 lands, is EVERYWHERE (there is no `.#installer-iso` flake
# output to build). Resolution order, mirroring 050/070's --image/env/on-
# the-fly-nix-build pattern exactly:
#   1. --image PATH
#   2. $UBX_INSTALLER_ISO
#   3. `nix build .#installer-iso` on the fly, IF `nix` is on PATH.
# Unlike 050/070, a failed on-the-fly build here is NOT treated as a hard
# failure (die) — it is treated as a clean SKIP, because `.#installer-iso`
# not existing yet is the expected, documented state of the world pre-#117,
# not a bug in this harness. `qemu-system-x86_64` missing is also a skip,
# same as every sibling. This dev harness has neither `nix` output for that
# attr nor (typically) qemu — this script is EXPECTED to skip here, and is
# EXPECTED TO KEEP SKIPPING IN CI too until #117 lands a real ISO; see
# .github/workflows/ci.yml's "installer-parity" job for how CI treats that
# skip as a pass, not a failure.
set -u

prog_name="080-qemu-installer-parity-e2e.sh"

usage() {
  cat <<USAGE
usage: 080-qemu-installer-parity-e2e.sh [options]

Boots a ubuntnix installer ISO in QEMU against a blank target disk and
(eventually, once issue #117 lands the ISO and its in-guest assert service)
asserts the freshly-installed system reaches parity with an upstream
Desktop/Server install (SPEC.md §11 M7 exit criterion, issue #119). Until
then this harness SKIPS everywhere, since no \`.#installer-iso\` build
target exists yet -- see this script's own header comment.

options:
  --image PATH     installer ISO to boot, OR a directory containing
                    installer.iso (e.g. a \`nix build\` result symlink).
                    Default: \$UBX_INSTALLER_ISO if set, else built on the
                    fly via \`nix build .#installer-iso\` if \`nix\` is on
                    PATH -- a failed/absent build is treated as a SKIP, not
                    a failure, since that attribute does not exist until
                    issue #117 lands.
  --timeout SECONDS  hard wall-clock timeout for the whole boot (default:
                      180). QEMU is killed if this elapses -- a hung/looping
                      boot must never hang the test suite.
  --no-kvm             force software emulation (TCG) even if /dev/kvm is
                        usable. Default: use KVM when available, fall back
                        to TCG automatically otherwise.
  --keep-log FILE       also copy the captured serial console log here
                        (useful for debugging a CI failure) after the run.
  -h, --help            show this message

Exit codes: 0 pass, 1 fail (boot did not reach the marker), 2 bad
arguments, 77 skip (qemu-system-x86_64 not on PATH, or no installer ISO
could be resolved and none could be built -- see tests/README.md's e2e
contract, and this script's own header for why a failed on-the-fly
\`.#installer-iso\` build is a skip here rather than a die).
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

main() {
  local image="" timeout=180 use_kvm=1 keep_log=""

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
      --no-kvm)
        use_kvm=0
        shift
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

  command -v qemu-system-x86_64 > /dev/null 2>&1 ||
    skip "qemu-system-x86_64 not found on PATH -- install qemu-system-x86 (apt) or run this on a host that has it"

  # -- resolve the installer ISO path --------------------------------------
  local image_explicit=1
  if [ -z "$image" ]; then
    image="${UBX_INSTALLER_ISO:-}"
    [ -n "$image" ] || image_explicit=0
  fi

  local built_dir=""
  if [ -z "$image" ]; then
    if command -v nix > /dev/null 2>&1; then
      built_dir="$(mktemp -d)"
      echo "$prog_name: no --image/\$UBX_INSTALLER_ISO given; attempting to build .#installer-iso via nix..." >&2
      # Unlike 050/070's equivalent build step, a failure here is NOT a
      # `die` -- `.#installer-iso` does not exist as a flake output until
      # issue #117 lands the real ISO build, so failing (or the attribute
      # simply not existing) is the expected state of the world today, not
      # a bug in this harness. Treat it as a clean skip.
      if ! nix --extra-experimental-features 'nix-command flakes' build .#installer-iso -o "$built_dir/result" -L; then
        rm -rf "$built_dir"
        skip "nix build .#installer-iso failed or the attribute does not exist yet -- expected until issue #117 lands the installer ISO; this harness cannot exercise the e2e install (see tests/README.md's e2e contract and this script's own header)"
      fi
      image="$built_dir/result"
    else
      skip "no --image/\$UBX_INSTALLER_ISO given, and no 'nix' on PATH to build .#installer-iso -- this dev harness cannot exercise the e2e install (see tests/README.md's e2e contract)"
    fi
  fi

  if [ -d "$image" ]; then
    image="$image/installer.iso"
  fi
  if [ ! -f "$image" ]; then
    if [ "$image_explicit" -eq 1 ]; then
      # An explicitly-given --image (or $UBX_INSTALLER_ISO) that does not
      # exist is a real ERROR, not a skip -- same distinction 050/070 draw:
      # "this environment cannot run e2e at all" (skip) vs. "you gave me a
      # bad argument" (a real failure).
      die "installer ISO does not exist: $image"
    fi
    skip "installer ISO does not exist: $image -- expected until issue #117 lands the installer ISO"
  fi

  # -- KVM vs. TCG --------------------------------------------------------
  local accel="tcg" cpu="max"
  if [ "$use_kvm" -eq 1 ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    accel="kvm"
    cpu="host"
  else
    [ "$use_kvm" -eq 1 ] &&
      echo "$prog_name: /dev/kvm not usable -- falling back to TCG (software emulation, slower)" >&2
  fi

  local log
  log="$(mktemp)"

  # -- the blank target disk -----------------------------------------------
  #
  # Unlike 050/070 (which boot a pre-built raw disk image directly with
  # `-drive ...,if=virtio`), the installer-parity flow boots the ISO as the
  # primary boot device (`-cdrom`) against a SEPARATE, freshly-created blank
  # virtio disk that the (eventual) autoinstall run partitions and installs
  # onto -- the same guided/LVM/LUKS storage flows nix/installer.nix's
  # `answers.storage.mode` documents. `qemu-img create` here mirrors how a
  # real USB-boot install targets a blank physical disk; `snapshot=on`
  # still applies so repeated CI runs never mutate a shared file. The
  # target disk is deliberately small (8G) -- big enough for a minimal
  # parity install, small enough to create instantly and not bloat CI.
  local target_disk
  target_disk="$(mktemp -u)"
  if ! command -v qemu-img > /dev/null 2>&1; then
    rm -f "$log"
    [ -z "$built_dir" ] || rm -rf "$built_dir"
    skip "qemu-img not found on PATH -- needed to create the blank target disk for the installer to install onto"
  fi
  if ! qemu-img create -f raw "$target_disk" 8G > /dev/null 2>&1; then
    rm -f "$log"
    [ -z "$built_dir" ] || rm -rf "$built_dir"
    die "qemu-img create failed to allocate the blank target disk"
  fi

  # See tests/e2e/010-qemu-boot-e2e.sh's own header for why -no-reboot and
  # -drive snapshot=on are both required here too. -boot d forces booting
  # from the ISO (the CD-ROM), not the blank target disk, on this first
  # (and today, only) boot -- an eventual full proof that reboots into the
  # freshly-installed system would need a second qemu invocation without
  # -cdrom/-boot d, off the same target_disk file, the way
  # tests/e2e/020-qemu-switch-e2e.sh chains multiple boots over one
  # persistent disk.
  echo "$prog_name: booting installer ISO $image against a blank target disk (accel=$accel, timeout=${timeout}s)..." >&2
  local rc=0
  timeout -k 10 "${timeout}s" \
    qemu-system-x86_64 \
    -machine pc \
    -accel "$accel" \
    -cpu "$cpu" \
    -m 2048 \
    -smp 2 \
    -cdrom "$image" \
    -boot d \
    -drive "file=$target_disk,format=raw,if=virtio,snapshot=on" \
    -serial "file:$log" \
    -display none \
    -no-reboot \
    || rc=$?

  [ -z "$built_dir" ] || rm -rf "$built_dir"
  rm -f "$target_disk"
  [ -z "$keep_log" ] || cp "$log" "$keep_log"

  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    echo "$prog_name: FAIL: qemu did not exit within ${timeout}s (killed by timeout) -- last 40 lines of the serial log:" >&2
    tail -n 40 "$log" >&2
    rm -f "$log"
    exit 1
  fi

  if grep -q 'UBX-INSTALLER-PARITY-FAIL' "$log"; then
    echo "$prog_name: FAIL: guest reported UBX-INSTALLER-PARITY-FAIL -- last 60 lines of the serial log:" >&2
    tail -n 60 "$log" >&2
    rm -f "$log"
    exit 1
  fi

  if grep -q 'UBX-INSTALLER-PARITY-PASS' "$log"; then
    echo "$prog_name: PASS: found UBX-INSTALLER-PARITY-PASS in the serial console log" >&2
    rm -f "$log"
    exit 0
  fi

  echo "$prog_name: FAIL: UBX-INSTALLER-PARITY-PASS not found in the serial console log (qemu exit code $rc) -- last 60 lines:" >&2
  tail -n 60 "$log" >&2
  rm -f "$log"
  exit 1
}

main "$@"
