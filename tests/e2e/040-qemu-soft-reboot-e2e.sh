#!/usr/bin/env bash
# tests/e2e/040-qemu-soft-reboot-e2e.sh — QEMU end-to-end REAL soft-reboot
# re-exec test (GitHub issue #59, a follow-up to #55/#58: the M2
# switch-loop-proof's own scenario 2 already stages a real `/run/nextroot`
# via a real `mount -t squashfs -o ro`, but still fires the actual guest
# reboot through a marker-dropping stub, `ubx-soft-reboot-stub`, because a
# REAL `systemctl soft-reboot` re-exec needs a full second bootable
# userspace already staged there -- see nix/boot.nix's switch-loop-proof
# section header for exactly why that gap was left open, and its
# soft-reboot-proof section for how THIS proof closes it).
#
# Boots `.#soft-reboot-proof`'s raw disk image (nix/boot.nix's `diskImage`,
# same two-partition FAT+squashfs layout as `.#boot-image-proof`) in
# qemu-system-x86_64, headless, serial console captured to a log file,
# under a hard timeout, in a SINGLE qemu launch (unlike
# tests/e2e/020-qemu-switch-e2e.sh's multiple relaunches over one
# persistent disk -- a soft-reboot RE-EXECS userspace within the SAME
# running kernel/qemu process; it never makes qemu exit, so there is only
# ever one qemu launch to wait on here).
#
# The guest's own driver (nix/boot.nix's `softRebootDriverScript`, baked in
# as ubx-soft-reboot-driver.service) does ALL of the real work and reports
# back over serial with a small, deliberate marker scheme:
#
#   UBX-SR-PRE-PASS       staged a genuinely bootable /run/nextroot (a
#                         fresh second mount of this guest's own root
#                         device plus a small overlay carrying a fresh
#                         per-boot generation tag), about to soft-reboot.
#   UBX-SR-BOOTID-PASS    /proc/sys/kernel/random/boot_id is UNCHANGED
#                         across the soft-reboot -- proves no full/kernel
#                         reboot happened, only a userspace re-exec.
#   UBX-SR-POST-PASS      post-re-exec live /etc carries the NEW
#                         generation's tag -- proves userspace actually
#                         came up from the newly-staged /run/nextroot, not
#                         the old root still running in place.
#   UBX-SR-NOTE: <reason>  a clean, diagnosable skip of the real re-exec
#                         (systemd too old, this boot judged too slow to
#                         safely attempt within the harness timeout, or
#                         the staged tree could not be verified bootable)
#                         -- NOT a failure; the guest still cleanly powers
#                         off.
#   UBX-SR-FAIL: <reason>  a real failure.
#
# This harness's PASS condition (see `main` below) is deliberately an OR:
# either BOTH UBX-SR-BOOTID-PASS and UBX-SR-POST-PASS appear (a real
# re-exec happened and both assertions held), OR exactly a UBX-SR-NOTE
# appears with no FAIL (the guest legitimately judged a real re-exec unsafe
# to attempt here and cleanly declined -- see nix/boot.nix's own header for
# the exact conditions). A FAIL, a timeout, or a PRE-PASS with neither
# BOOTID-PASS nor POST-PASS following (the re-exec silently didn't land --
# a hang the harness's own --timeout would otherwise have to catch) all
# fail the run — this host side never inspects the guest directly, exactly
# like tests/e2e/010-qemu-boot-e2e.sh/020-qemu-switch-e2e.sh; it only
# trusts what the guest itself asserted and printed to serial.
#
# -- Why this can legitimately SKIP (exit 77) -------------------------------
#
# Identical contract to tests/e2e/010-qemu-boot-e2e.sh/020-qemu-switch-
# e2e.sh / tests/README.md's own e2e rule: this dev harness has neither
# `nix` nor `qemu-system-x86_64`, so this script is EXPECTED to skip here --
# tests/unit/154-soft-reboot-proof-wiring.sh and a dedicated CLI unit test
# exercise the parts of this script's own surface that don't need either
# tool. CI's "soft-reboot" job (.github/workflows/ci.yml) builds
# `.#soft-reboot-proof` and installs qemu for real, with KVM available on
# GitHub's ubuntu-24.04 runners (falling back to TCG otherwise -- in which
# case the guest's own uptime heuristic is expected to emit UBX-SR-NOTE
# rather than risk the real re-exec blowing this harness's own --timeout).
set -u

prog_name="040-qemu-soft-reboot-e2e.sh"

usage() {
  cat <<USAGE
usage: 040-qemu-soft-reboot-e2e.sh [options]

Boots a ubuntnix soft-reboot-proof disk image in QEMU and asserts either a
real \`systemctl soft-reboot\` re-exec succeeded (UBX-SR-BOOTID-PASS AND
UBX-SR-POST-PASS both on the serial console) or the guest cleanly declined
to attempt one (a single UBX-SR-NOTE, no UBX-SR-FAIL) -- GitHub issue #59.

options:
  --image PATH        raw disk image to boot, OR a directory containing
                       disk.img (e.g. a \`nix build\` result symlink).
                       Default: \$UBX_SOFT_REBOOT_IMAGE if set, else built
                       on the fly via \`nix build .#soft-reboot-proof\` if
                       \`nix\` is on PATH.
  --timeout SECONDS    hard wall-clock timeout for the whole boot (default:
                       240). qemu is killed if this elapses -- a
                       hung/looping boot must never hang the test suite.
  --no-kvm             force software emulation (TCG) even if /dev/kvm is
                       usable. Default: use KVM when available, fall back
                       to TCG automatically otherwise.
  --keep-log FILE      also copy the captured serial console log here
                       (useful for debugging a CI failure) after the run.
  -h, --help           show this message

Exit codes: 0 pass (real re-exec succeeded, or a clean NOTE decline), 1
fail (a real failure, a timeout, or a re-exec that silently didn't land),
2 bad arguments, 77 skip (qemu-system-x86_64 not on PATH, or no image
could be resolved and none could be built -- see tests/README.md's e2e
contract).
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
  local image="" timeout=240 use_kvm=1 keep_log=""

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

  # -- resolve the image path (identical shape to 010's/020's own) --------
  if [ -z "$image" ]; then
    image="${UBX_SOFT_REBOOT_IMAGE:-}"
  fi

  local built_dir=""
  if [ -z "$image" ]; then
    if command -v nix > /dev/null 2>&1; then
      built_dir="$(mktemp -d)"
      echo "$prog_name: no --image/\$UBX_SOFT_REBOOT_IMAGE given; building .#soft-reboot-proof via nix..." >&2
      if ! nix --extra-experimental-features 'nix-command flakes' build .#soft-reboot-proof -o "$built_dir/result" -L; then
        rm -rf "$built_dir"
        die "nix build .#soft-reboot-proof failed -- see output above"
      fi
      image="$built_dir/result"
    else
      skip "no --image/\$UBX_SOFT_REBOOT_IMAGE given, and no 'nix' on PATH to build .#soft-reboot-proof -- this dev harness cannot exercise the e2e soft-reboot (see tests/README.md's e2e contract)"
    fi
  fi

  if [ -d "$image" ]; then
    image="$image/disk.img"
  fi
  [ -f "$image" ] || die "disk image does not exist: $image"

  # -- KVM vs. TCG (identical logic to 010/020) --------------------------
  local accel="tcg" cpu="max"
  if [ "$use_kvm" -eq 1 ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    accel="kvm"
    cpu="host"
  else
    [ "$use_kvm" -eq 1 ] &&
      echo "$prog_name: /dev/kvm not usable -- falling back to TCG (software emulation, slower; the guest's own uptime heuristic may decline the real soft-reboot re-exec in this case -- see nix/boot.nix's soft-reboot-proof header)" >&2
  fi

  local log
  log="$(mktemp)"

  # A soft-reboot re-execs userspace WITHOUT making qemu exit or reboot the
  # virtual machine (see this script's own header) -- -no-reboot only
  # guards against a genuinely unexpected full/kernel reboot, exactly as
  # in 010/020. -drive snapshot=on: this is a single, throwaway boot (no
  # state needs to persist past this one qemu process -- the guest's own
  # /run persistence carries state across the soft-reboot re-exec itself,
  # entirely inside this one launch), and the image is typically a Nix
  # store output (read-only) -- see 010's identical comment for why
  # snapshot=on is the correct, non-mutating choice here.
  echo "$prog_name: booting $image (accel=$accel, timeout=${timeout}s)..." >&2
  local rc=0
  timeout -k 10 "${timeout}s" \
    qemu-system-x86_64 \
    -machine pc \
    -accel "$accel" \
    -cpu "$cpu" \
    -m 1024 \
    -smp 2 \
    -drive "file=$image,format=raw,if=virtio,snapshot=on" \
    -serial "file:$log" \
    -display none \
    -no-reboot \
    || rc=$?

  [ -z "$built_dir" ] || rm -rf "$built_dir"
  [ -z "$keep_log" ] || cp "$log" "$keep_log"

  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    echo "$prog_name: FAIL: qemu did not exit within ${timeout}s (killed by timeout) -- last 60 lines of the serial log:" >&2
    tail -n 60 "$log" >&2
    rm -f "$log"
    exit 1
  fi

  if grep -qE 'UBX-SR-FAIL:' "$log"; then
    echo "$prog_name: FAIL: guest reported a real failure: $(grep -m1 -E 'UBX-SR-FAIL:' "$log")" >&2
    echo "$prog_name: last 60 lines of the serial log:" >&2
    tail -n 60 "$log" >&2
    rm -f "$log"
    exit 1
  fi

  local saw_bootid=0 saw_post=0 saw_note=0
  grep -q 'UBX-SR-BOOTID-PASS' "$log" && saw_bootid=1
  grep -q 'UBX-SR-POST-PASS' "$log" && saw_post=1
  grep -qE 'UBX-SR-NOTE:' "$log" && saw_note=1

  if [ "$saw_bootid" -eq 1 ] && [ "$saw_post" -eq 1 ]; then
    echo "$prog_name: PASS: real soft-reboot re-exec succeeded (UBX-SR-BOOTID-PASS + UBX-SR-POST-PASS found)" >&2
    rm -f "$log"
    exit 0
  fi

  if [ "$saw_note" -eq 1 ]; then
    echo "$prog_name: PASS: guest cleanly declined the real soft-reboot re-exec: $(grep -m1 -E 'UBX-SR-NOTE:' "$log")" >&2
    rm -f "$log"
    exit 0
  fi

  echo "$prog_name: FAIL: neither a full re-exec pass (UBX-SR-BOOTID-PASS + UBX-SR-POST-PASS) nor a clean UBX-SR-NOTE decline was found in the serial console log (qemu exit code $rc) -- last 60 lines:" >&2
  tail -n 60 "$log" >&2
  rm -f "$log"
  exit 1
}

main "$@"
