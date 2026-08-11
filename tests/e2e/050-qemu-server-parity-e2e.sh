#!/usr/bin/env bash
# tests/e2e/050-qemu-server-parity-e2e.sh — QEMU end-to-end server-parity
# boot test (SPEC.md §11 M5 exit criterion: "the server parity config boots
# in QEMU with a package set matching the upstream Server seed (minus
# enumerated exceptions)"; GitHub issue #99).
#
# Boots `.#server-parity-image`'s raw disk image (nix/profiles.nix's
# `serverParityDiskImage`, built from examples/server.nix compiled through
# every landed M5 base module) in qemu-system-x86_64, headless, serial
# console captured to a log file, under a hard timeout, and asserts the log
# contains the distinctive UBX-SERVER-PARITY-PASS marker that image's own
# baked-in `ubx-server-parity-assert.service` emits once it has confirmed,
# INSIDE the guest, that: boot reached multi-user.target with a generation
# marker present and `/ubx/bin/ubx` runnable (the same baseline
# tests/e2e/010-qemu-boot-e2e.sh checks); the cloud-init disabled marker
# (SPEC.md §12 R12) exists; the rendered networking config (netplan +
# hostname) landed; and — the M5 exit criterion itself — every
# `profiles.server`-declared seed package is actually `dpkg`-installed and
# none of nix/profiles.nix's enumerated M1-fixture exceptions (just `hello`
# as of GitHub issue #118 -- htop/ed/jq were removed from the exception
# list once the committed upstream manifest proved they are real upstream
# Server packages) leaked in. See nix/profiles.nix's own header, "What 'the
# upstream Server seed' means in this repo", for why this is a subset/exclusion
# check rather than byte-for-byte equality against a live upstream Ubuntu
# Server ISO manifest — this sandboxed dev/CI environment has no network
# access to fetch one.
#
# This host-side harness never inspects the guest directly; it only trusts
# what the guest itself asserted and printed to serial — same posture as
# tests/e2e/010-qemu-boot-e2e.sh, which this script is a close sibling of.
#
# -- Why this can legitimately SKIP (exit 77) -------------------------------
#
# tests/README.md's own rule: "E2E tests may require KVM and declare it by
# exiting 77 (skip) when unavailable." This dev harness has neither `nix`
# nor `qemu-system-x86_64` — this script is EXPECTED to skip here.
# CI (a new "server-parity" job, .github/workflows/ci.yml) has both.
set -u

prog_name="050-qemu-server-parity-e2e.sh"

usage() {
  cat <<USAGE
usage: 050-qemu-server-parity-e2e.sh [options]

Boots a ubuntnix server-parity disk image in QEMU and asserts it reaches
multi-user.target with the server-seed package set present (minus
enumerated exceptions) and cloud-init present-but-inert (SPEC.md §11 M5
exit criterion, §12 R12).

options:
  --image PATH     raw disk image to boot, OR a directory containing
                    disk.img (e.g. a \`nix build\` result symlink). Default:
                    \$UBX_SERVER_PARITY_IMAGE if set, else built on the fly
                    via \`nix build .#server-parity-image\` if \`nix\` is on
                    PATH.
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
    image="${UBX_SERVER_PARITY_IMAGE:-}"
  fi

  local built_dir=""
  if [ -z "$image" ]; then
    if command -v nix > /dev/null 2>&1; then
      built_dir="$(mktemp -d)"
      echo "$prog_name: no --image/\$UBX_SERVER_PARITY_IMAGE given; building .#server-parity-image via nix..." >&2
      if ! nix --extra-experimental-features 'nix-command flakes' build .#server-parity-image -o "$built_dir/result" -L; then
        rm -rf "$built_dir"
        die "nix build .#server-parity-image failed -- see output above"
      fi
      image="$built_dir/result"
    else
      skip "no --image/\$UBX_SERVER_PARITY_IMAGE given, and no 'nix' on PATH to build .#server-parity-image -- this dev harness cannot exercise the e2e boot (see tests/README.md's e2e contract)"
    fi
  fi

  if [ -d "$image" ]; then
    image="$image/disk.img"
  fi
  [ -f "$image" ] || die "disk image does not exist: $image"

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

  # See tests/e2e/010-qemu-boot-e2e.sh's own header for why -no-reboot and
  # -drive snapshot=on are both required here too.
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
    echo "$prog_name: FAIL: qemu did not exit within ${timeout}s (killed by timeout) -- last 40 lines of the serial log:" >&2
    tail -n 40 "$log" >&2
    rm -f "$log"
    exit 1
  fi

  if grep -q 'UBX-SERVER-PARITY-FAIL' "$log"; then
    echo "$prog_name: FAIL: guest reported UBX-SERVER-PARITY-FAIL -- last 60 lines of the serial log:" >&2
    tail -n 60 "$log" >&2
    rm -f "$log"
    exit 1
  fi

  if grep -q 'UBX-SERVER-PARITY-PASS' "$log"; then
    echo "$prog_name: PASS: found UBX-SERVER-PARITY-PASS in the serial console log" >&2
    rm -f "$log"
    exit 0
  fi

  echo "$prog_name: FAIL: UBX-SERVER-PARITY-PASS not found in the serial console log (qemu exit code $rc) -- last 60 lines:" >&2
  tail -n 60 "$log" >&2
  rm -f "$log"
  exit 1
}

main "$@"
