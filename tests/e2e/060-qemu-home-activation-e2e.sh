#!/usr/bin/env bash
# tests/e2e/060-qemu-home-activation-e2e.sh — QEMU end-to-end proof that
# `ubx rebuild switch --apply` really activates the per-user home domain
# on a booted image (SPEC.md §9, §11 M5; GitHub issue #105 -- a live-QEMU
# follow-up to #98, which landed the home surface itself -- nix/home.nix,
# bin/ubx-home, bin/ubx-home-apply -- plus only a build-time,
# non-booting `.#home-proof` fixture render).
#
# Boots `.#home-activation-proof`'s raw disk image (nix/boot.nix's
# `homeActivationDiskImageDrv`, built from the same generic
# `switchLoopVarImage`/`switchLoopDiskImage` three-partition machinery
# tests/e2e/020-qemu-switch-e2e.sh's own image uses, just with the third,
# ext4 partition mounted at `/home` instead of `/ubx/var` -- see
# nix/boot.nix's own "home-activation-proof" section header for the full
# design and why) in qemu-system-x86_64, headless, serial console captured
# to a log file, under a hard per-boot timeout. Structural sibling of
# tests/e2e/020-qemu-switch-e2e.sh: same private-writable-disk-copy /
# multi-launch / `-no-reboot` / concatenated-serial-log machinery (this
# proof needs exactly TWO boots -- one real, guest-initiated reboot, to
# prove `loginctl enable-linger` really makes an enabled user service
# auto-start -- see nix/boot.nix's own driver header), same
# `UBX-*-PASS`/`UBX-*-FAIL`/exit-77-skip posture.
#
# -- What this test asserts -------------------------------------------------
#
# The guest driver (nix/boot.nix's `homeActivationDriverScript`) prints
# FIVE markers, in order, across its one boot-then-reboot run:
#   UBX-HOME-USER-PASS    the declared fixture user exists for real
#                         (`useradd -m` via a real `ubx rebuild switch
#                         --apply` users-domain activation script, landing
#                         on the persistent /home ext4 partition)
#   UBX-HOME-LINGER-PASS  `loginctl enable-linger` + a reachable per-user
#     or                  `systemctl --user` bus (`user@<uid>.service`
#   UBX-HOME-LINGER-NOTE  active, `/run/user/<uid>/bus` present) -- or a
#                         documented, non-fatal NOTE if that bus could not
#                         be reached within 30s (this project's own locked
#                         archive carries no dbus/dbus-user-session
#                         package -- see nix/boot.nix's own section header,
#                         "The systemctl --user / linger question", for the
#                         full reasoning and exactly what gets skipped when
#                         this happens)
#   UBX-HOME-GEN1-PASS    first real `ubx rebuild switch --apply
#                         --home-manifest` activation: a declared file's
#                         content+mode+ownership landed correctly, and (bus
#                         permitting) both declared user services are
#                         enabled+active
#   UBX-HOME-GEN2-PASS    a SECOND generation: the same file's content
#                         changed, a SECOND file's declaration never
#                         changed and its mtime+inode are asserted
#                         UNCHANGED (a real diff-driven "not rewritten"
#                         proof, not just "content still matches"), and
#                         (bus permitting) one service is now disabled+
#                         inactive while the other is untouched
#   UBX-HOME-REBOOT-PASS  after a REAL guest-initiated reboot: gen2's file
#                         content survived, and (bus permitting) the
#                         still-enabled user service auto-started with NO
#                         explicit start call this boot -- the actual
#                         linger/auto-start proof this issue calls for
# `UBX-HOME-FAIL: <reason>` on any real failure -- this harness treats
# that exactly like a missing marker (a real activation failure, not a
# hang), the same "trust only what the guest itself asserted to serial"
# posture every sibling e2e script in this directory already documents.
#
# -- Why this can legitimately SKIP (exit 77) -------------------------------
#
# Identical contract to tests/e2e/020-qemu-switch-e2e.sh / tests/README.md's
# "E2E tests may require KVM and declare it by exiting 77 (skip) when
# unavailable": this dev harness has neither `nix` nor
# `qemu-system-x86_64`, so this script is EXPECTED to skip here.
set -u

prog_name="060-qemu-home-activation-e2e.sh"

usage() {
  cat <<USAGE
usage: 060-qemu-home-activation-e2e.sh [options]

Boots a ubuntnix home-activation-proof disk image in QEMU, across one
real guest-initiated reboot, and asserts a real, live \`ubx rebuild switch
--apply\` home-domain activation (files + a per-user systemd --user
service, across two generations and a reboot -- see this script's own
header for the exact marker set).

options:
  --image PATH        raw disk image to boot, OR a directory containing
                       disk.img (e.g. a \`nix build\` result symlink).
                       Default: \$UBX_HOME_ACTIVATION_IMAGE if set, else
                       built on the fly via
                       \`nix build .#home-activation-proof\` if \`nix\` is
                       on PATH.
  --timeout SECONDS    hard wall-clock timeout PER BOOT (default: 240).
                       qemu is killed if a single boot elapses this --
                       a hung/looping boot must never hang the test suite.
  --max-boots N        maximum number of guest reboots this harness will
                       follow before giving up (default: 3 -- everything
                       through UBX-HOME-GEN2-PASS lands in boot 1,
                       UBX-HOME-REBOOT-PASS needs boot 2; one spare).
  --no-kvm             force software emulation (TCG) even if /dev/kvm is
                       usable. Default: use KVM when available, fall back
                       to TCG automatically otherwise.
  --keep-log FILE      also copy the full, concatenated serial console log
                       here (useful for debugging a CI failure) after the
                       run.
  -h, --help           show this message

Exit codes: 0 pass, 1 fail (a FAIL marker appeared, or not every PASS
marker appeared within --max-boots), 2 bad arguments, 77 skip
(qemu-system-x86_64 not on PATH, or no image could be resolved and none
could be built -- see tests/README.md's e2e contract).
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

# The five markers, in the order nix/boot.nix's homeActivationDriverScript
# emits them (see this script's own header). UBX-HOME-LINGER-PASS is
# deliberately NOT in this list -- see below, immediately before the
# marker loop -- since a documented UBX-HOME-LINGER-NOTE is an equally
# valid, non-fatal outcome for that one line only.
readonly REQUIRED_MARKERS=(UBX-HOME-USER-PASS UBX-HOME-GEN1-PASS UBX-HOME-GEN2-PASS UBX-HOME-REBOOT-PASS)

main() {
  local image="" timeout=240 use_kvm=1 keep_log="" max_boots=3

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

  # -- resolve the image path (identical shape to 020's own resolution) --
  if [ -z "$image" ]; then
    image="${UBX_HOME_ACTIVATION_IMAGE:-}"
  fi

  local built_dir=""
  if [ -z "$image" ]; then
    if command -v nix > /dev/null 2>&1; then
      built_dir="$(mktemp -d)"
      echo "$prog_name: no --image/\$UBX_HOME_ACTIVATION_IMAGE given; building .#home-activation-proof via nix..." >&2
      if ! nix --extra-experimental-features 'nix-command flakes' build .#home-activation-proof -o "$built_dir/result" -L; then
        rm -rf "$built_dir"
        die "nix build .#home-activation-proof failed -- see output above"
      fi
      image="$built_dir/result"
    else
      skip "no --image/\$UBX_HOME_ACTIVATION_IMAGE given, and no 'nix' on PATH to build .#home-activation-proof -- this dev harness cannot exercise the e2e home-activation proof (see tests/README.md's e2e contract)"
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

  # -- a private, WRITABLE copy of the disk: this proof's real reboot
  #    needs its own writes (declared user, home content, linger state) to
  #    persist ACROSS qemu launches -- identical rationale to 020's own
  #    header, "Why this needs MULTIPLE qemu launches over ONE disk". ----
  local workdir disk master_log
  workdir="$(mktemp -d)"
  disk="$workdir/home-activation-disk.img"
  master_log="$workdir/serial-all.log"
  cp "$image" "$disk"
  # The source image typically comes from a `nix build` result (read-only,
  # mode 0444 in the Nix store); the copy inherits that mode, so QEMU cannot
  # open it read-write (if=virtio, no readonly=on) and each boot dies with
  # "Could not open ...: Permission denied". Restore write permission.
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

    # A guest-reported FAILure ends the run immediately -- no point
    # relaunching further boots once the guest itself has already said
    # something is broken (identical posture to every sibling e2e script
    # in this directory).
    saw_fail="$(grep -m1 -E 'UBX-HOME-FAIL' "$master_log" || true)"
    if [ -n "$saw_fail" ]; then
      echo "$prog_name: FAIL: guest reported a failure: $saw_fail" >&2
      echo "$prog_name: last 60 lines of the combined serial log:" >&2
      tail -n 60 "$master_log" >&2
      exit 1
    fi

    all_found=1
    local m
    for m in "${REQUIRED_MARKERS[@]}"; do
      grep -q "$m" "$master_log" || {
        all_found=0
        break
      }
    done
    [ "$all_found" -eq 1 ] && break
  done

  if [ "$all_found" -eq 1 ]; then
    # UBX-HOME-LINGER-PASS vs. UBX-HOME-LINGER-NOTE is informational only
    # (see this script's own header) -- surface which one this run actually
    # hit, but never fail the run over it either way.
    if grep -q 'UBX-HOME-LINGER-NOTE' "$master_log"; then
      echo "$prog_name: NOTE: this run hit UBX-HOME-LINGER-NOTE -- the systemctl --user bus was not reachable this boot, so every systemctl --user-dependent assertion (service enable/active/auto-start) was skipped; only the file-domain criteria were verified. See nix/boot.nix's home-activation-proof section header, 'The systemctl --user / linger question', and pass --keep-log to inspect the full serial log." >&2
    fi
    echo "$prog_name: PASS: all required home-activation markers found (${REQUIRED_MARKERS[*]}) across $boot_num boot(s)" >&2
    exit 0
  fi

  echo "$prog_name: FAIL: not all required home-activation markers appeared within $max_boots boot(s) -- found:" >&2
  local m
  for m in "${REQUIRED_MARKERS[@]}"; do
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
