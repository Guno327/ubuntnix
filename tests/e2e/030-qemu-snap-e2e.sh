#!/usr/bin/env bash
# tests/e2e/030-qemu-snap-e2e.sh — QEMU end-to-end SNAP-CONVERGENCE test
# (SPEC.md §11 M3 exit criterion: "declared snap set converged live + drift
# purge"; GitHub issue #64). Modeled directly on
# tests/e2e/020-qemu-switch-e2e.sh's own harness shape (same CLI surface,
# same KVM/TCG detection, same "only trust markers the guest itself printed
# to serial" posture) -- see that script's header for the fuller discussion
# of the general technique this one reuses without repeating verbatim.
#
# Boots `.#snap-converge-proof`'s raw disk image (nix/boot.nix's
# `snapConvergeDiskImageDrv`, built via the plain M1 `diskImage`) in
# qemu-system-x86_64, headless, serial console captured to a log file, under
# a hard per-boot timeout, and asserts the serial log contains THREE
# distinct markers, in order:
#   UBX-M3-S1-PASS  declared snap set converged LIVE from vendored payloads
#                   (ack+install+connect+set+hold, all via a real
#                   `ubx rebuild switch --apply`)
#   UBX-M3-S2-PASS  interactive `snap install` blocked by the drift guard,
#                   AND a simulated undeclared snap purged on reconverge
#   UBX-M3-S3-PASS  a further reconverge with NO manifest change re-sideloads
#                   nothing (diff-driven no-op)
# (All three land in the guest's single boot -- unlike M2's switch-loop
# proof, this proof's own exit criterion needs no reboot-survival claim, so
# this harness boots exactly once; see nix/boot.nix's snap-converge-proof
# section header for the full scenario-by-scenario design and its own
# "What's real vs. simulated" scope note.) On any scenario failure the
# guest instead prints `UBX-M3-Sn-FAIL: <reason>` and powers off; this
# harness treats that exactly like a missing marker (a real convergence
# failure, not a hang).
#
# -- Why this can legitimately SKIP (exit 77) -------------------------------
#
# Identical contract to tests/e2e/010-qemu-boot-e2e.sh / 020-qemu-switch-
# e2e.sh / tests/README.md's "E2E tests may require KVM and declare it by
# exiting 77 (skip) when unavailable": this dev harness has neither `nix`
# nor `qemu-system-x86_64`, so this script is EXPECTED to skip here --
# tests/unit/151-qemu-snap-e2e-cli.sh exercises exactly that path. CI's
# "snap-convergence" job (.github/workflows/ci.yml) builds
# `.#snap-converge-proof` and installs qemu for real.
set -u

prog_name="030-qemu-snap-e2e.sh"

usage() {
  cat <<USAGE
usage: 030-qemu-snap-e2e.sh [options]

Boots a ubuntnix snap-converge-proof disk image in QEMU and asserts all
three of SPEC.md §11's M3 snap-convergence scenarios pass (UBX-M3-S1-PASS
through UBX-M3-S3-PASS on the serial console -- see this script's own
header).

options:
  --image PATH        raw disk image to boot, OR a directory containing
                       disk.img (e.g. a \`nix build\` result symlink).
                       Default: \$UBX_SNAP_CONVERGE_IMAGE if set, else built
                       on the fly via \`nix build .#snap-converge-proof\` if
                       \`nix\` is on PATH.
  --timeout SECONDS    hard wall-clock timeout for the whole boot (default:
                       240). qemu is killed if this elapses -- a hung/
                       looping boot must never hang the test suite.
  --no-kvm             force software emulation (TCG) even if /dev/kvm is
                       usable. Default: use KVM when available, fall back
                       to TCG automatically otherwise.
  --keep-log FILE      also copy the captured serial console log here
                       (useful for debugging a CI failure) after the run.
  -h, --help           show this message

Exit codes: 0 pass, 1 fail (a scenario FAILed, or not all markers appeared),
2 bad arguments, 77 skip (qemu-system-x86_64 not on PATH, or no image could
be resolved and none could be built -- see tests/README.md's e2e contract).
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

# The three markers, in the order nix/boot.nix's snapConvergeDriverScript
# emits them.
readonly MARKERS=(UBX-M3-S1-PASS UBX-M3-S2-PASS UBX-M3-S3-PASS)

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
    image="${UBX_SNAP_CONVERGE_IMAGE:-}"
  fi

  local built_dir=""
  if [ -z "$image" ]; then
    if command -v nix > /dev/null 2>&1; then
      built_dir="$(mktemp -d)"
      echo "$prog_name: no --image/\$UBX_SNAP_CONVERGE_IMAGE given; building .#snap-converge-proof via nix..." >&2
      if ! nix --extra-experimental-features 'nix-command flakes' build .#snap-converge-proof -o "$built_dir/result" -L; then
        rm -rf "$built_dir"
        die "nix build .#snap-converge-proof failed -- see output above"
      fi
      image="$built_dir/result"
    else
      skip "no --image/\$UBX_SNAP_CONVERGE_IMAGE given, and no 'nix' on PATH to build .#snap-converge-proof -- this dev harness cannot exercise the e2e snap convergence (see tests/README.md's e2e contract)"
    fi
  fi

  if [ -d "$image" ]; then
    image="$image/disk.img"
  fi
  [ -f "$image" ] || die "disk image does not exist: $image"

  # -- KVM vs. TCG (identical logic to 010/020) ---------------------------
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

  # -no-reboot: a guest-initiated reboot the driver never intends (a crash,
  # a kernel panic) makes QEMU EXIT instead of looping forever -- belt and
  # suspenders alongside the hard `timeout` below. The driver itself never
  # calls `systemctl reboot` (unlike the M2 switch-loop proof) -- this
  # proof's own exit criterion needs only one boot, see nix/boot.nix's
  # snap-converge-proof header.
  # -drive snapshot=on: exactly 010's own reasoning -- the image is
  # typically a read-only Nix store output, and this harness's own guest
  # writes (the simulated snapd state, the generations root) need not
  # survive past this one boot at all.
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

  local saw_fail
  saw_fail="$(grep -m1 -E 'UBX-M3-S[0-9]+-FAIL' "$log" || true)"
  if [ -n "$saw_fail" ]; then
    echo "$prog_name: FAIL: guest reported a scenario failure: $saw_fail" >&2
    echo "$prog_name: last 60 lines of the serial log:" >&2
    tail -n 60 "$log" >&2
    rm -f "$log"
    exit 1
  fi

  local all_found=1 m
  for m in "${MARKERS[@]}"; do
    grep -q "$m" "$log" || all_found=0
  done

  if [ "$all_found" -eq 1 ]; then
    echo "$prog_name: PASS: all three M3 snap-convergence markers found (${MARKERS[*]})" >&2
    rm -f "$log"
    exit 0
  fi

  echo "$prog_name: FAIL: not all M3 snap-convergence markers appeared (qemu exit code $rc) -- found:" >&2
  for m in "${MARKERS[@]}"; do
    if grep -q "$m" "$log"; then
      echo "  [x] $m" >&2
    else
      echo "  [ ] $m" >&2
    fi
  done
  echo "$prog_name: last 60 lines of the serial log:" >&2
  tail -n 60 "$log" >&2
  rm -f "$log"
  exit 1
}

main "$@"
