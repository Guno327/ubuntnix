#!/usr/bin/env bash
# tests/unit/073-boot-grub-embed-layout.sh — diskImage's manual GRUB boot-code
# embed (SPEC.md §4.2/§4.3, §6 `ubuntnix.boot`; GitHub issue #10, milestone
# M1's disk-image-assembly line item).
#
# grub-bios-setup cannot run inside the Nix build sandbox: it insists on
# resolving its --directory/--device-map arguments back to a real backing
# block device via udev/sysfs (no /dev, no udevd, no device nodes in the
# sandbox), so nix/boot.nix's diskImage now embeds GRUB's boot code
# manually -- dd'ing boot.img and core.img into place and patching the
# diskboot blocklist length by hand, exactly what grub-bios-setup itself
# does for a post-MBR-gap install, with no device resolution needed.
#
# This harness has no `nix` (see tests/unit/021-flake-purity.sh's header for
# the same standing caveat), so nothing here can actually build the
# derivation or inspect a real disk.img -- that's CI-only. This is instead a
# machine-checked textual guard, mirroring tests/unit/071's relationship to
# nix/boot.nix: it asserts, by grepping nix/boot.nix's source text, that the
# manual embed's exact mechanics are present and that grub-bios-setup is no
# longer invoked at all.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

boot_nix="nix/boot.nix"
[ -f "$boot_nix" ] || {
  echo "FAIL: $boot_nix does not exist" >&2
  exit 1
}

# -- grub-bios-setup must no longer be INVOKED ------------------------------
#
# The name may still appear in prose comments explaining why it isn't used
# (that's expected and fine), but there must be no actual invocation of the
# tool binary as a command.
if grep -qE '^\s*(toolrun|ubxrun)\s+"[^"]*grub-bios-setup"' "$boot_nix"; then
  fail "$boot_nix still invokes grub-bios-setup directly -- it cannot run in the Nix sandbox (needs udev/device resolution)"
fi
if grep -qE -- '--directory=grub-setup-dir|--device-map=device\.map' "$boot_nix"; then
  fail "$boot_nix still builds a grub-bios-setup-style --directory/--device-map invocation"
fi

# The tool-preflight loop must no longer require grub-bios-setup to exist
# (it's never invoked, so requiring its presence would be dead weight).
preflight_block="$(awk '/for bin in \\/{p=1} p{print} p && /done/{exit}' "$boot_nix")"
case "$preflight_block" in
  *grub-bios-setup*)
    fail "$boot_nix's tool-preflight loop still checks for grub-bios-setup, which is no longer invoked"
    ;;
esac

# grub-mkimage, boot.img, mkfs.vfat, mmd, mcopy, and parted must all still
# be preflight-checked -- the manual embed still needs boot.img (raw MBR
# template bytes) and core.img (built via grub-mkimage), and the rest of
# diskImage still needs the FAT/partitioning tools.
for still_needed in grub-mkimage mkfs.vfat mmd mcopy parted boot.img; do
  case "$preflight_block" in
    *"$still_needed"*) ;;
    *) fail "$boot_nix's tool-preflight loop no longer checks for $still_needed" ;;
  esac
done

# -- the manual embed's exact dd/patch mechanics ----------------------------
#
# 1. boot.img's boot code (first 440 bytes only, preserving parted's
#    partition table + 0x55AA at [440,512)) written to sector 0 of
#    disk.img, with conv=notrunc (must not truncate disk.img to 440 bytes).
grep -qE 'dd\s*\\?[[:space:]]*$|dd ' "$boot_nix" ||
  fail "$boot_nix does not appear to invoke dd at all"
grep -qE 'if="\$tools/usr/lib/grub/i386-pc/boot\.img"\s+of=disk\.img' "$boot_nix" ||
  fail "$boot_nix does not dd boot.img onto disk.img"
grep -qE 'bs=440\s+count=1\s+conv=notrunc' "$boot_nix" ||
  fail "$boot_nix's boot.img embed is not written with 'bs=440 count=1 conv=notrunc' (must copy ONLY the 440-byte boot-code region, preserving parted's partition table)"

# 2. core.img written contiguously at sector 1 (seek=1, 512-byte blocks),
#    also conv=notrunc.
grep -qE 'if=core\.img\s+of=disk\.img' "$boot_nix" ||
  fail "$boot_nix does not dd core.img onto disk.img"
grep -qE 'bs=512\s+seek=1\s+conv=notrunc' "$boot_nix" ||
  fail "$boot_nix's core.img embed is not written with 'bs=512 seek=1 conv=notrunc' (must land at LBA 1, right after the MBR)"

# 3. the diskboot blocklist length field patched at on-disk byte offset
#    1020 (sector 1 start = byte 512, + in-sector offset 508 = 1020), 2
#    bytes, conv=notrunc.
grep -qE 'seek=1020\s+count=2\s+conv=notrunc' "$boot_nix" ||
  fail "$boot_nix does not patch the diskboot blocklist length at on-disk offset 1020 (bs=1 seek=1020 count=2 conv=notrunc)"

# The length must be computed from core.img's actual size (not
# hardcoded), and used to derive the two little-endian bytes written to
# that offset.
grep -qE 'core_bytes="\$\(.*stat.*-c%s core\.img\)"' "$boot_nix" ||
  fail "$boot_nix does not compute core_bytes from core.img's real size via stat -c%s"
grep -qE 'core_sectors=\$\(\(\s*\(\s*core_bytes\s*\+\s*511\s*\)\s*/\s*512\s*\)\)' "$boot_nix" ||
  fail "$boot_nix does not round core_bytes up to a whole sector count (( core_bytes + 511 ) / 512 )"
grep -qE 'blocklist_len=\$\(\(\s*core_sectors\s*-\s*1\s*\)\)' "$boot_nix" ||
  fail "$boot_nix does not compute blocklist_len as core_sectors - 1 (sectors AFTER core.img's own first sector)"

# -- the gap-fits sanity guard ------------------------------------------------
#
# core.img (1 + core_sectors sectors, MBR-relative) must be checked against
# the 2048-sectors-per-MiB pre-partition-1 boundary, and must exit 1 with an
# explanatory message if it no longer fits.
grep -qE 'gap_sectors=\$\(\(\s*boot_start_mib\s*\*\s*2048\s*\)\)' "$boot_nix" ||
  fail "$boot_nix does not derive the embedding-gap size from boot_start_mib * 2048 sectors/MiB"
grep -qE '1\s*\+\s*core_sectors.*(-ge|>=).*gap_sectors|gap_sectors.*(-le|<=).*1\s*\+\s*core_sectors' "$boot_nix" ||
  fail "$boot_nix does not guard that (1 + core_sectors) stays below gap_sectors before embedding"
if grep -qE 'gap_sectors' "$boot_nix"; then
  guard_block="$(awk '/gap_sectors=\$\(\(/{p=1} p{print} p && /^\s*fi\s*$/{exit}' "$boot_nix")"
  case "$guard_block" in
    *"exit 1"*) ;;
    *) fail "$boot_nix's gap-fits guard does not exit 1 when core.img no longer fits" ;;
  esac
  case "$guard_block" in
    *">&2"*) ;;
    *) fail "$boot_nix's gap-fits guard does not print its error to stderr" ;;
  esac
fi

exit "$fails"
