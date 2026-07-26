#!/usr/bin/env bash
# tests/e2e/025-qemu-password-login-e2e.sh — QEMU end-to-end proof that a
# user declared with `hashedPasswordSecret` can log in with the
# corresponding password after `ubx rebuild switch` (SPEC.md §6, §8.1,
# §11 M4 exit criterion "password login from a secret-sourced hash works
# end-to-end"; GitHub issue #90, milestone M4). Structural sibling of
# tests/e2e/020-qemu-switch-e2e.sh: same image-copy/multi-boot/serial-log
# machinery, same `qemu-system-x86_64`/`nix` availability contract, same
# `UBX-*-PASS`/`UBX-*-FAIL`/exit-77-skip posture -- this script boots the
# SAME `.#switch-loop-proof` image 020 does (nix/boot.nix's
# `switchLoopDiskImage`/`switchLoopDriverScript`), since the M4 password-
# login phase this file greps for is now wired into that same driver's
# own phase machinery (see nix/boot.nix's switch-loop-proof section, the
# "M4: hashedPasswordSecret login proof" block near the end of its own
# phase 2), not a separate image.
#
# -- What this test asserts -------------------------------------------------
#
# The switch-loop-proof driver declares a `ubuntnix.users.<name>
# .hashedPasswordSecret` user (fixture name/plaintext/hash, never a real
# credential -- see nix/boot.nix's own `switchLoopPw*` constants), backed
# by a real secret materialized under `/run/secrets/<name>` by the REAL
# secrets domain (GitHub issue #78) BEFORE `ubx rebuild switch` converges
# the users domain's own `apply-passwords` step (GitHub issue #80's own
# ordering requirement -- see bin/ubx's own `execute_domains` header).
# That phase runs LAST, at the very end of the driver's own phase 2 (after
# every M2 switch-loop scenario has already asserted, deliberately -- see
# nix/boot.nix's own comment on why it cannot run any earlier without
# corrupting M2's hardcoded generation-number assertions), so reaching
# `UBX-M4-PW-PASS` requires the SAME multi-boot sequence
# tests/e2e/020-qemu-switch-e2e.sh already drives (up to three real,
# guest-initiated reboots over one persistent disk).
#
# A guest-side login check (feeding the known fixture plaintext through
# the same glibc crypt(3) machinery a real PAM/`su` login would use,
# Python's own `crypt` module) prints `UBX-M4-PW-PASS` on success,
# `UBX-M4-PW-FAIL: <reason>` on failure -- exactly the
# `UBX-M2-Sn-PASS`/`-FAIL` convention tests/e2e/020-qemu-switch-e2e.sh's
# own header documents, so this harness reuses that file's "trust only
# what the guest itself asserted to serial" posture verbatim: an
# `UBX-M2-Sn-FAIL` anywhere in the log (an earlier M2 scenario failing,
# which would prevent the driver from ever reaching its own M4 phase) is
# treated exactly like an `UBX-M4-PW-FAIL` -- a real failure, not a hang.
#
# -- Why this can legitimately SKIP (exit 77) -------------------------------
#
# Identical contract to tests/e2e/020-qemu-switch-e2e.sh / tests/README.md's
# "E2E tests may require KVM and declare it by exiting 77 (skip) when
# unavailable": this dev harness has neither `nix` nor
# `qemu-system-x86_64`, so this script is EXPECTED to skip here --
# tests/unit/1*-qemu-password-login-e2e-cli.sh exercises exactly that
# path.
set -u

prog_name="025-qemu-password-login-e2e.sh"

usage() {
  cat <<USAGE
usage: 025-qemu-password-login-e2e.sh [options]

Boots a ubuntnix switch-loop-proof disk image in QEMU, across multiple
guest-initiated reboots over one persistent disk (same image and boot
machinery as tests/e2e/020-qemu-switch-e2e.sh), and asserts a real password
login against a hashedPasswordSecret user's secret-sourced hash succeeds
(serial marker UBX-M4-PW-PASS) -- see this script's own header.

options:
  --image PATH        raw disk image to boot, OR a directory containing
                       disk.img (e.g. a \`nix build\` result symlink).
                       Default: \$UBX_PW_LOGIN_IMAGE if set, else
                       \$UBX_SWITCH_LOOP_IMAGE if set, else built on the fly
                       via \`nix build .#switch-loop-proof\` if \`nix\` is on
                       PATH (this test shares that same image with
                       tests/e2e/020-qemu-switch-e2e.sh -- see this
                       script's own header).
  --timeout SECONDS    hard wall-clock timeout PER BOOT (default: 240).
                       qemu is killed if a single boot elapses this --
                       a hung/looping boot must never hang the test suite.
  --max-boots N        maximum number of guest reboots this harness will
                       follow before giving up (default: 4 -- the M4 login
                       phase lands in the switch-loop driver's own third
                       boot, after every M2 scenario; one spare).
  --no-kvm             force software emulation (TCG) even if /dev/kvm is
                       usable. Default: use KVM when available, fall back
                       to TCG automatically otherwise.
  --keep-log FILE      also copy the full, concatenated serial console log
                       here (useful for debugging a CI failure) after the
                       run.
  -h, --help           show this message

Exit codes: 0 pass, 1 fail (a scenario FAILed, or UBX-M4-PW-PASS did not
appear within --max-boots), 2 bad arguments, 77 skip (qemu-system-x86_64
not on PATH, or no image could be resolved and none could be built -- see
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

# The marker this harness looks for -- see nix/boot.nix's switch-loop-proof
# section, the "M4: hashedPasswordSecret login proof" block near the end of
# switchLoopDriverScript's own phase 2.
readonly MARKERS=(UBX-M4-PW-PASS)

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

  # -- resolve the image path -- this test shares its image with
  #    tests/e2e/020-qemu-switch-e2e.sh (same nix/boot.nix
  #    switchLoopDriverScript, now with the M4 phase wired into its own
  #    phase 2), so honor $UBX_PW_LOGIN_IMAGE first (this test's own
  #    override) then fall back to $UBX_SWITCH_LOOP_IMAGE (020's own
  #    override, likely already set in a CI job that runs both) before
  #    building from scratch. --------------------------------------------
  if [ -z "$image" ]; then
    image="${UBX_PW_LOGIN_IMAGE:-}"
  fi
  if [ -z "$image" ]; then
    image="${UBX_SWITCH_LOOP_IMAGE:-}"
  fi

  local built_dir=""
  if [ -z "$image" ]; then
    if command -v nix > /dev/null 2>&1; then
      built_dir="$(mktemp -d)"
      echo "$prog_name: no --image/\$UBX_PW_LOGIN_IMAGE/\$UBX_SWITCH_LOOP_IMAGE given; building .#switch-loop-proof via nix..." >&2
      if ! nix --extra-experimental-features 'nix-command flakes' build .#switch-loop-proof -o "$built_dir/result" -L; then
        rm -rf "$built_dir"
        die "nix build .#switch-loop-proof failed -- see output above"
      fi
      image="$built_dir/result"
    else
      skip "no --image/\$UBX_PW_LOGIN_IMAGE/\$UBX_SWITCH_LOOP_IMAGE given, and no 'nix' on PATH to build .#switch-loop-proof -- this dev harness cannot exercise the e2e password-login proof (see tests/README.md's e2e contract)"
    fi
  fi

  if [ -d "$image" ]; then
    image="$image/disk.img"
  fi
  [ -f "$image" ] || die "disk image does not exist: $image"

  # -- KVM vs. TCG (identical logic to 020/010) --------------------------
  local accel="tcg" cpu="max"
  if [ "$use_kvm" -eq 1 ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    accel="kvm"
    cpu="host"
  else
    [ "$use_kvm" -eq 1 ] &&
      echo "$prog_name: /dev/kvm not usable -- falling back to TCG (software emulation, slower)" >&2
  fi

  # -- a private, WRITABLE copy of the disk (identical rationale to 020's
  #    own header, "Why this needs MULTIPLE qemu launches over ONE disk")
  local workdir disk master_log
  workdir="$(mktemp -d)"
  disk="$workdir/pw-login-disk.img"
  master_log="$workdir/serial-all.log"
  cp "$image" "$disk"
  chmod u+w "$disk"
  : > "$master_log"

  [ -z "$built_dir" ] || rm -rf "$built_dir"

  # shellcheck disable=SC2317,SC2329  # invoked indirectly via the `trap ... EXIT` below (SC2317 on <0.10, SC2329 on >=0.10)
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

    # A guest-reported scenario FAILure ends the run immediately --
    # UBX-M2-Sn-FAIL anywhere means the driver never reached its own M4
    # phase (see this script's own header); UBX-M4-PW-FAIL is the
    # password-login proof's own failure. Either way, no point relaunching
    # further boots once the guest itself has already said something is
    # broken.
    saw_fail="$(grep -m1 -E 'UBX-M2-S[0-9]+-FAIL|UBX-M4-PW-FAIL' "$master_log" || true)"
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
    echo "$prog_name: PASS: password login against the hashedPasswordSecret-derived hash succeeded (${MARKERS[*]}) across $boot_num boot(s)" >&2
    exit 0
  fi

  echo "$prog_name: FAIL: UBX-M4-PW-PASS did not appear within $max_boots boot(s)" >&2
  echo "$prog_name: last 60 lines of the combined serial log:" >&2
  tail -n 60 "$master_log" >&2
  exit 1
}

main "$@"
