#!/usr/bin/env bash
# tests/e2e/020-qemu-switch-e2e.sh — QEMU end-to-end SWITCH-LOOP test
# (SPEC.md §11 M2 exit criterion: "NixOS-parity switch loop for
# config/service/user domains; image swap via soft-reboot; `test` reverts
# on reboot; demonstrated offline rollback"; GitHub issue #32).
#
# Boots `.#switch-loop-proof`'s raw disk image (nix/boot.nix's
# `switchLoopDiskImage`) in qemu-system-x86_64, headless, serial console
# captured to a log file, under a hard per-boot timeout, and asserts the
# serial log contains FIVE distinct markers, in order:
#   UBX-M2-S1-PASS  config/service/user switch (`ubx rebuild switch`)
#   UBX-M2-S2-PASS  image-swap / soft-reboot activation
#   UBX-M2-S5-PASS  apt/dpkg/snap mutation guards
#   UBX-M2-S3-PASS  `ubx rebuild test` reverts on a real reboot
#   UBX-M2-S4-PASS  offline `ubx rollback`, surviving a real reboot
# (S1/S2/S5 land in the guest's FIRST boot; S3 needs the guest to reboot
# once first; S4 needs a SECOND guest reboot -- see nix/boot.nix's
# `switchLoopDriverScript` for the exact guest-side phase machinery that
# produces this ordering.) On any scenario failure the guest instead
# prints `UBX-M2-Sn-FAIL: <reason>` and powers off; this harness treats
# that exactly like a missing marker (a real activation failure, not a
# hang), the same "trust only what the guest itself asserted to serial"
# posture tests/e2e/010-qemu-boot-e2e.sh already documents.
#
# -- Why this needs MULTIPLE qemu launches over ONE disk ---------------------
#
# Unlike 010's throwaway, `-drive ...,snapshot=on` boot (guest writes
# discarded -- fine for a single boot-and-assert check), scenarios 3 and 4
# above are only meaningful if generation/rollback state SURVIVES a real
# guest-initiated reboot. This harness therefore:
#   1. copies the built image to a private, WRITABLE temp file (never
#      mutates the Nix store output or a caller-supplied --image path);
#   2. boots that temp file WITHOUT snapshot=on, so guest writes to its
#      persistent `/ubx/var` partition (see nix/boot.nix) really land on
#      disk;
#   3. relies on `-no-reboot` to make qemu EXIT (not loop) every time the
#      guest's own driver calls `systemctl reboot` to advance to its next
#      phase, or `systemctl poweroff` once every scenario has run;
#   4. re-launches qemu on the SAME temp disk file after each exit, up to
#      a small bounded number of boots, appending each boot's own serial
#      capture into one running log this script greps as a whole.
# This host side never inspects the guest directly (no mounting the disk,
# no reading files off it) -- exactly like 010, it only trusts markers the
# guest itself printed to the serial console it controls.
#
# -- Why this can legitimately SKIP (exit 77) -------------------------------
#
# Identical contract to tests/e2e/010-qemu-boot-e2e.sh / tests/README.md's
# "E2E tests may require KVM and declare it by exiting 77 (skip) when
# unavailable": this dev harness has neither `nix` nor
# `qemu-system-x86_64`, so this script is EXPECTED to skip here --
# tests/unit/136-qemu-switch-e2e-cli.sh exercises exactly that path. CI's
# "switch-loop" job (.github/workflows/ci.yml, sibling to M1's "boot" job)
# builds `.#switch-loop-proof` and installs qemu for real.
set -u

prog_name="020-qemu-switch-e2e.sh"

usage() {
  cat <<USAGE
usage: 020-qemu-switch-e2e.sh [options]

Boots a ubuntnix switch-loop-proof disk image in QEMU, across multiple
guest-initiated reboots over one persistent disk, and asserts all five of
SPEC.md §11's M2 switch-loop scenarios pass (UBX-M2-S1-PASS through
UBX-M2-S5-PASS on the serial console -- see this script's own header).

options:
  --image PATH        raw disk image to boot, OR a directory containing
                       disk.img (e.g. a \`nix build\` result symlink).
                       Default: \$UBX_SWITCH_LOOP_IMAGE if set, else built
                       on the fly via \`nix build .#switch-loop-proof\` if
                       \`nix\` is on PATH.
  --timeout SECONDS    hard wall-clock timeout PER BOOT (default: 240).
                       qemu is killed if a single boot elapses this --
                       a hung/looping boot must never hang the test suite.
  --max-boots N        maximum number of guest reboots this harness will
                       follow before giving up (default: 4 -- S1/S2/S5 in
                       boot 1, S3 in boot 2, S4 in boot 3; one spare).
  --no-kvm             force software emulation (TCG) even if /dev/kvm is
                       usable. Default: use KVM when available, fall back
                       to TCG automatically otherwise.
  --keep-log FILE      also copy the full, concatenated serial console log
                       here (useful for debugging a CI failure) after the
                       run.
  -h, --help           show this message

Exit codes: 0 pass, 1 fail (a scenario FAILed, or not all markers appeared
within --max-boots), 2 bad arguments, 77 skip (qemu-system-x86_64 not on
PATH, or no image could be resolved and none could be built -- see
tests/README.md's e2e contract).
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

# The five markers, in the order this harness expects the guest driver to
# emit them (see nix/boot.nix's switchLoopDriverScript's phase machinery).
readonly MARKERS=(UBX-M2-S1-PASS UBX-M2-S2-PASS UBX-M2-S5-PASS UBX-M2-S3-PASS UBX-M2-S4-PASS)

main() {
  local image="" timeout=240 use_kvm=1 keep_log="" max_boots=4

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
      --max-boots)
        [ $# -ge 2 ] || die "--max-boots requires an argument"
        max_boots="$2"
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
  [[ "$max_boots" =~ ^[0-9]+$ ]] || die "--max-boots must be a non-negative integer, got: $max_boots"
  [ "$max_boots" -ge 1 ] || die "--max-boots must be at least 1, got: $max_boots"

  command -v qemu-system-x86_64 > /dev/null 2>&1 ||
    skip "qemu-system-x86_64 not found on PATH -- install qemu-system-x86 (apt) or run this on a host that has it"

  # -- resolve the image path (identical shape to 010's own resolution) --
  if [ -z "$image" ]; then
    image="${UBX_SWITCH_LOOP_IMAGE:-}"
  fi

  local built_dir=""
  if [ -z "$image" ]; then
    if command -v nix > /dev/null 2>&1; then
      built_dir="$(mktemp -d)"
      echo "$prog_name: no --image/\$UBX_SWITCH_LOOP_IMAGE given; building .#switch-loop-proof via nix..." >&2
      if ! nix --extra-experimental-features 'nix-command flakes' build .#switch-loop-proof -o "$built_dir/result" -L; then
        rm -rf "$built_dir"
        die "nix build .#switch-loop-proof failed -- see output above"
      fi
      image="$built_dir/result"
    else
      skip "no --image/\$UBX_SWITCH_LOOP_IMAGE given, and no 'nix' on PATH to build .#switch-loop-proof -- this dev harness cannot exercise the e2e switch loop (see tests/README.md's e2e contract)"
    fi
  fi

  if [ -d "$image" ]; then
    image="$image/disk.img"
  fi
  [ -f "$image" ] || die "disk image does not exist: $image"

  # -- KVM vs. TCG (identical logic to 010) ------------------------------
  local accel="tcg" cpu="max"
  if [ "$use_kvm" -eq 1 ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    accel="kvm"
    cpu="host"
  else
    [ "$use_kvm" -eq 1 ] &&
      echo "$prog_name: /dev/kvm not usable -- falling back to TCG (software emulation, slower)" >&2
  fi

  # -- a private, WRITABLE copy of the disk: this harness's own writes
  #    (via the booted guest) must never touch the Nix store output or a
  #    caller-supplied --image path, but DO need to persist ACROSS the
  #    several qemu launches below (see this script's own header). ------
  local workdir disk master_log
  workdir="$(mktemp -d)"
  disk="$workdir/switch-loop-disk.img"
  master_log="$workdir/serial-all.log"
  cp "$image" "$disk"
  : > "$master_log"

  [ -z "$built_dir" ] || rm -rf "$built_dir"

  # shellcheck disable=SC2329  # invoked indirectly via the `trap ... EXIT` below
  cleanup() {
    [ -z "$keep_log" ] || cp "$master_log" "$keep_log" 2> /dev/null || true
    rm -rf "$workdir"
  }
  trap cleanup EXIT

  local boot_num=0 boot_log all_found=0 saw_fail=""
  while [ "$boot_num" -lt "$max_boots" ]; do
    boot_num=$((boot_num + 1))
    boot_log="$workdir/serial-boot$boot_num.log"

    echo "$prog_name: boot $boot_num/$max_boots (accel=$accel, timeout=${timeout}s)..." >&2
    local rc=0
    timeout -k 10 "${timeout}s" \
      qemu-system-x86_64 \
      -machine pc \
      -accel "$accel" \
      -cpu "$cpu" \
      -m 1024 \
      -smp 2 \
      -drive "file=$disk,format=raw,if=virtio" \
      -serial "file:$boot_log" \
      -display none \
      -no-reboot \
      || rc=$?

    [ -f "$boot_log" ] && cat "$boot_log" >> "$master_log"

    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
      echo "$prog_name: FAIL: qemu did not exit within ${timeout}s on boot $boot_num (killed by timeout) -- last 40 lines of that boot's serial log:" >&2
      tail -n 40 "$boot_log" 2> /dev/null >&2
      exit 1
    fi

    # A guest-reported scenario FAILure ends the run immediately -- no
    # point relaunching further boots once the guest itself has already
    # said a scenario is broken.
    saw_fail="$(grep -m1 -E 'UBX-M2-S[0-9]+-FAIL' "$master_log" || true)"
    if [ -n "$saw_fail" ]; then
      echo "$prog_name: FAIL: guest reported a scenario failure: $saw_fail" >&2
      echo "$prog_name: last 60 lines of the combined serial log:" >&2
      tail -n 60 "$master_log" >&2
      exit 1
    fi

    all_found=1
    local m
    for m in "${MARKERS[@]}"; do
      grep -q "$m" "$master_log" || {
        all_found=0
        break
      }
    done
    [ "$all_found" -eq 1 ] && break
  done

  if [ "$all_found" -eq 1 ]; then
    echo "$prog_name: PASS: all five M2 switch-loop markers found (${MARKERS[*]}) across $boot_num boot(s)" >&2
    exit 0
  fi

  echo "$prog_name: FAIL: not all M2 switch-loop markers appeared within $max_boots boot(s) -- found:" >&2
  local m
  for m in "${MARKERS[@]}"; do
    if grep -q "$m" "$master_log"; then
      echo "  [x] $m" >&2
    else
      echo "  [ ] $m" >&2
    fi
  done
  echo "$prog_name: last 60 lines of the combined serial log:" >&2
  tail -n 60 "$master_log" >&2
  exit 1
}

main "$@"
