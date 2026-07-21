#!/usr/bin/env bash
# tests/e2e/010-qemu-boot-e2e.sh — QEMU end-to-end boot test (SPEC.md §11
# M1 exit criterion: "a flake-defined Ubuntu 24.04 image boots reproducibly
# [in QEMU]"; GitHub issue #10, milestone M1's e2e harness line item).
#
# Boots `.#boot-image-proof`'s raw disk image (nix/boot.nix's `diskImage`)
# in qemu-system-x86_64, headless, serial console captured to a log file,
# under a hard timeout, and asserts the log contains the distinctive
# UBX-E2E-PASS marker that image's own baked-in `ubx-e2e-assert.service`
# emits once it has confirmed, INSIDE the guest, that boot reached
# multi-user.target, a generation marker file exists, and /ubx/bin/ubx is
# present and runs (see nix/boot.nix's `bootRootfs` for that unit's exact
# script). This host-side harness never inspects the guest directly; it
# only trusts what the guest itself asserted and printed to serial.
#
# -- Why this can legitimately SKIP (exit 77) -------------------------------
#
# tests/README.md's own rule: "E2E tests may require KVM and declare it by
# exiting 77 (skip) when unavailable." This dev harness has neither `nix`
# nor `qemu-system-x86_64` (see CONTRIBUTING.md / this repo's own task
# notes on tool availability), so this script is EXPECTED to skip here —
# tests/unit/072-e2e-harness-cli.sh exercises exactly that path, alongside
# the parts of this script's own CLI surface that don't need either tool.
# CI (a new "boot" job, .github/workflows/ci.yml) has both: it builds the
# image with `nix build .#boot-image-proof` and installs qemu-system-x86_64
# via apt, then runs this script for real, with KVM available on GitHub's
# ubuntu-24.04 runners (falling back to TCG -- slower, still correct --
# wherever it isn't, e.g. this local dev harness if it ever DID have qemu).
set -u

prog_name="010-qemu-boot-e2e.sh"

usage() {
  cat <<USAGE
usage: 010-qemu-boot-e2e.sh [options]

Boots a ubuntnix disk image in QEMU and asserts it reaches multi-user.target
with a generation marker file present and ubx runnable (SPEC.md §11's M1
exit criterion).

options:
  --image PATH     raw disk image to boot, OR a directory containing
                    disk.img (e.g. a \`nix build\` result symlink). Default:
                    \$UBX_BOOT_IMAGE if set, else built on the fly via
                    \`nix build .#boot-image-proof\` if \`nix\` is on PATH.
  --timeout SECONDS  hard wall-clock timeout for the whole boot (default:
                      180). QEMU is killed if this elapses -- a hung/looping
                      boot must never hang the test suite.
  --no-kvm            force software emulation (TCG) even if /dev/kvm is
                       usable. Default: use KVM when available, fall back
                       to TCG automatically otherwise.
  --keep-log FILE      also copy the captured serial console log here
                       (useful for debugging a CI failure) after the run.
  -h, --help           show this message

Exit codes: 0 pass, 1 fail (boot did not reach the marker), 2 bad
arguments, 77 skip (qemu-system-x86_64 not on PATH, or no image could be
resolved and none could be built -- see tests/README.md's e2e contract).
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

  # -- resolve the image path ------------------------------------------
  if [ -z "$image" ]; then
    image="${UBX_BOOT_IMAGE:-}"
  fi

  local built_dir=""
  if [ -z "$image" ]; then
    if command -v nix > /dev/null 2>&1; then
      built_dir="$(mktemp -d)"
      echo "$prog_name: no --image/\$UBX_BOOT_IMAGE given; building .#boot-image-proof via nix..." >&2
      if ! nix --extra-experimental-features 'nix-command flakes' build .#boot-image-proof -o "$built_dir/result" -L; then
        rm -rf "$built_dir"
        die "nix build .#boot-image-proof failed -- see output above"
      fi
      image="$built_dir/result"
    else
      skip "no --image/\$UBX_BOOT_IMAGE given, and no 'nix' on PATH to build .#boot-image-proof -- this dev harness cannot exercise the e2e boot (see tests/README.md's e2e contract)"
    fi
  fi

  if [ -d "$image" ]; then
    image="$image/disk.img"
  fi
  [ -f "$image" ] || die "disk image does not exist: $image"

  # -- KVM vs. TCG (scope item 4: "KVM when available, fall back to TCG") --
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

  # -no-reboot: a guest-initiated reboot (e.g. a kernel panic configured to
  # reboot, or a systemd failure path that reboots instead of the expected
  # `systemctl poweroff`) makes QEMU EXIT instead of looping forever --
  # belt-and-suspenders alongside the hard `timeout` below, which is the
  # actual backstop for a boot that just hangs outright.
  # -serial file:$log + console=ttyS0 (baked into the image's kernel
  # command line, nix/boot.nix's proofGeneration) is how the guest's own
  # kernel/systemd/ubx-e2e-assert.service output reaches $log at all.
  echo "$prog_name: booting $image (accel=$accel, timeout=${timeout}s)..." >&2
  local rc=0
  timeout -k 10 "${timeout}s" \
    qemu-system-x86_64 \
    -machine pc \
    -accel "$accel" \
    -cpu "$cpu" \
    -m 1024 \
    -smp 2 \
    -drive "file=$image,format=raw,if=virtio" \
    -serial "file:$log" \
    -display none \
    -no-reboot \
    || rc=$?

  [ -z "$built_dir" ] || rm -rf "$built_dir"
  [ -z "$keep_log" ] || cp "$log" "$keep_log"

  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    echo "$prog_name: FAIL: qemu did not exit within ${timeout}s (killed by timeout) -- last 40 lines of the serial log:" >&2
    tail -n 40 "$log" >&2
    rm -f "$log"
    exit 1
  fi

  if grep -q 'UBX-E2E-PASS' "$log"; then
    echo "$prog_name: PASS: found UBX-E2E-PASS in the serial console log" >&2
    rm -f "$log"
    exit 0
  fi

  echo "$prog_name: FAIL: UBX-E2E-PASS not found in the serial console log (qemu exit code $rc) -- last 60 lines:" >&2
  tail -n 60 "$log" >&2
  rm -f "$log"
  exit 1
}

main "$@"
