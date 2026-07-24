# Boot: kernel, GRUB, and the bootable disk image

```{admonition} Implemented (M1), narrow by design
:class: note

`nix/boot.nix`, `bin/ubx-gen-grub-cfg`, and `tests/e2e/010-qemu-boot-e2e.sh`
exist in the repository as of milestone **M1** (`SPEC.md` §11, GitHub issue
#10): the mechanism below is real, and CI's `boot` job actually builds
`.#boot-image-proof` and boots it in QEMU. What M1 does **not** implement:
`ubx rebuild`, multiple simultaneous generations, live rollback, a
generated `/etc`, or soft-reboot activation — all milestone **M2**
(`SPEC.md` §11, GitHub issue #25's generation model). Every primitive on
this page is deliberately shaped so M2 can call it again with a longer
generation list rather than rewrite it.
```

## The pipeline

A bootable image is five steps, each a function in `nix/boot.nix`,
composed in `flake.lib.boot`:

1. **`mkBootSpec`** — validates `SPEC.md` §6's `ubuntnix.boot = { kernel;
   kernelParams; }` primitive against the locked archive: the kernel
   meta-package (default `linux-image-virtual`) must actually be pinned in
   `archive.lock.json`, and every `kernelParams` entry must be a single,
   non-empty, whitespace-free command-line token.
2. **`resolveKernelFlavor`** — a real Ubuntu install's `linux-image-virtual`
   is a meta-package with no files of its own; it Depends on a concrete
   flavor package (`linux-image-<version>-generic`, alongside a matching
   `linux-modules-<version>-generic`). `composeRootfs`
   (`nix/compose.nix`) does no dependency resolution of its own, so this
   function independently scans the locked archive for the one package
   shaped like a concrete flavor and uses it — see its own comment in
   `nix/boot.nix` for exactly why, and why it throws rather than guesses if
   the lockfile ever carries zero or more than one.
3. **`bootRootfs`** — composes the *entire* locked package set
   (`composeRootfs`, pinned to every package in `archive.lock.json`: the
   kernel, `initramfs-tools`, GRUB, filesystem tools, and everything else
   the M1 lockfile carries — see that file's own provenance comment), then
   layers on a handful of plain files composition itself has no primitive
   for yet: an empty `/etc/machine-id` placeholder, the M1 writable-state
   `systemd` mount units (below), and the `/ubx` store skeleton with the
   `ubx` CLI aboard.
4. **`kernelArtifacts`** — extracts `/boot/vmlinuz-<flavor>` and
   `/boot/initrd.img-<flavor>` out of the composed tree into their own
   small derivation (`SPEC.md` §4.2: "kernel and initrd come out of the
   composed rootfs itself").
5. **`grubCfg`** / **`diskImage`** — render `grub.cfg` and assemble the raw,
   BIOS-bootable disk image. Described in their own sections below.

## How the initrd gets built

`bootRootfs` never runs `update-initramfs` itself. Debian/Ubuntu kernel
packaging does that automatically: `linux-image-<flavor>`'s own `postinst`
script invokes `/etc/kernel/postinst.d/initramfs-tools` (installed by the
`initramfs-tools` package) once both packages have been unpacked, which in
turn calls `update-initramfs -c -k <flavor>` — this happens **inside**
`composeRootfs`'s own hardened chroot (`nix/compose.nix`'s `dpkg --configure
-a` step), the same maintainer-script machinery every other composed
package already goes through. No extra plumbing was needed for this to
work: including the kernel and `initramfs-tools` packages in the same
`composeRootfs` call is sufficient, because `dpkg` orders configuration by
dependency and `initramfs-tools` has no dependency on the kernel (so it
configures first, registering the hook the kernel's own postinst then
finds).

`initramfs-tools`' shipped default is `MODULES=most` — deliberately broad,
covering essentially every storage/filesystem driver a target might need
without per-machine tuning. This project's M1 boot image relies on that
default to cover two drivers it specifically needs: **`squashfs`** (to
mount the read-only root — see below) and **`virtio_blk`**/**`virtio_pci`**
(the disk interface `tests/e2e/010-qemu-boot-e2e.sh` boots with,
`-drive ...,if=virtio`). This is an assumption, not something this
project's own dev harness could verify (it has no `nix`) — if CI's e2e
boot ever fails to find its root device, an explicit
`/etc/initramfs-tools/modules` addition forcing these modules in is the
documented fix, requiring a small hardening pass analogous to
`nix/compose.nix`'s own chroot work (see "Known limitations" below).

## How the read-only root is mounted

The squashfs image `nix/compose.nix`'s `squashfsImage` produces is written
**directly** onto a disk partition — no wrapping filesystem. A squashfs
image already is a complete, directly-mountable filesystem; the generation's
GRUB entry sets `rootfstype=squashfs` on the kernel command line (alongside
`root=/dev/vda2`, the squashfs partition), and the kernel/initramfs mount it
exactly like any other root filesystem type. This is the standard live-CD/
embedded-image idiom, and it means the disk-image assembly never needs to
create or populate a second filesystem for the root.

## Writable state: the M1 simplification

`SPEC.md` §4.2 lists `/var`, `/home`, `/ubx`, and `/flake` as writable paths
on an otherwise-immutable system. A real per-partition or overlay scheme for
these is **M2** scope. For M1, `bootRootfs` bakes in three plain `systemd`
`.mount` units — `/var`, `/tmp`, `/home` each get a `tmpfs` mount, ordered
`Before=local-fs.target` so they are in place before any service that wants
to write there starts:

```ini
[Unit]
DefaultDependencies=no
Before=local-fs.target

[Mount]
What=tmpfs
Where=/var
Type=tmpfs
Options=mode=0755

[Install]
WantedBy=local-fs.target
```

**Known tradeoff:** this masks whatever the squashfs image's own `/var`
already contains — most notably `/var/lib/dpkg`, the dpkg status database
composition itself just spent real effort building. At boot, `/var` becomes
an empty tmpfs; the baked content is still there underneath (nothing is
deleted), just inaccessible until a real M2 writable-partition/overlay
scheme replaces this. M1's acceptance bar (boot reaches multi-user/login;
a generation marker exists; `ubx` runs) does not depend on a queryable
runtime dpkg database, so this is an accepted, documented simplification
rather than a bug.

`/ubx` and `/flake` are **not** tmpfs-mounted for M1: `/ubx` is baked
read-only into the image (it only needs to hold the `ubx` CLI stub and the
generation marker for now — see below), and `/flake` does not exist yet at
all (the installer that creates it is **M7** scope).

## The `/ubx` skeleton and the generation marker

`bootRootfs` creates `/ubx/bin/ubx` (a copy of `bin/ubx`, this repo's own
CLI stub — `chmod +x`, symlinked to `/usr/local/bin/ubx` for `$PATH`
convenience), `/ubx/store/`, and `/ubx/var/` (empty, placeholders for the
real store machinery **M2**+ builds out). It also writes a minimal
per-generation marker: `/ubx/generations/current` (the active generation's
index) and `/ubx/generations/<index>/marker` (an empty file). This is
deliberately the smallest thing that is already **generation-list-shaped**:
a real generation manifest (`SPEC.md` §4.3, GitHub issue #25) is more than
one file, but a future multi-generation `bootRootfs` caller just writes
more of these, unchanged in shape.

## GRUB generation machinery

`grub.cfg` is rendered by **`bin/ubx-gen-grub-cfg`** — a small,
dependency-free `bash` script, not inline Nix string interpolation. It
takes a tab-separated generation list (`index`, `title`, `kernelPath`,
`initrdPath`, `rootDevice`, `kernelParams`), one line per generation, and
emits one `menuentry` block per line, in the file's own order — it has no
opinion on generation *ordering* (newest-first, retention, ...), which
stays a caller policy question for **M2**. Because it depends on nothing
but `bash` builtins, `nix/boot.nix`'s `grubCfg` function `source`s it
directly into its build script rather than executing it as a subprocess —
simpler than the loader-wrapping every *external binary* invocation in this
project otherwise needs (`nix/stdenv.nix`'s "BOOTSTRAP CAVEAT").

It is directly unit-tested (`tests/unit/070-boot-grub-cfg-gen.sh`) against
fixture generation lists, with exact output compared byte-for-byte — no
`nix` required, since the script itself needs none.

## The disk image

`diskImage` assembles a raw, BIOS-bootable, MBR-partitioned disk image
using **only** tools this project's Ubuntu-native stdenv already builds
from the locked archive (`grub-pc-bin`, `grub-common`, `dosfstools`,
`mtools`, `parted`):

```text
[ 1 MiB gap ][ partition 1: FAT32, /boot content ][ partition 2: raw squashfs bytes ]
```

Two departures from a "normal" Ubuntu install layout, both chosen so this
derivation needs **no** `mount(2)`, loop device, or elevated privilege at
all (the Nix build sandbox grants none of those):

- **The boot partition is FAT, not ext2/ext4.** `mkfs.vfat` and mtools'
  `mcopy`/`mmd` can create *and populate* a FAT filesystem as a plain file
  — no mount needed. `e2fsprogs` has no equivalent "populate without
  mounting" tool for ext, which is why `dosfstools`/`mtools`, not
  `e2fsprogs`, cover this partition (`e2fsprogs` is what a *real* writable
  state partition, M2 scope, would use instead).
- **The squashfs partition holds the squashfs image's raw bytes**, with no
  wrapping filesystem (see "How the read-only root is mounted" above).

Both `parted` (partitioning) and `grub-bios-setup` (embedding GRUB's boot
code — `boot.img` into the MBR, `core.img` into the embedding area between
the MBR and partition 1) are pointed at the raw disk image **file**
directly, exactly as they would a real block device; both tools' device
abstractions are documented to support this. This is the single
highest-risk step in the whole pipeline: it has not been exercised against
a real `nix` build anywhere before landing here (this project's own dev
harness has no `nix`). If CI's first build of `.#boot-image-proof` fails at
this step, that is this exact assumption meeting reality — mirroring how
`nix/stdenv.nix`'s bootstrap and `nix/compose.nix`'s `unshare` hardening
both needed real CI iteration before they worked.

`core.img`'s prefix is hardcoded to `(hd0,msdos1)/grub` — this image's own
fixed, single-disk, single-partition M1 layout — rather than a
`search`-based UUID lookup; that is a reasonable M2 follow-up once multiple
physical targets matter.

## The QEMU end-to-end test

`tests/e2e/010-qemu-boot-e2e.sh` boots `.#boot-image-proof`'s disk image in
`qemu-system-x86_64`, headless, with the serial console captured to a log
file, under a hard wall-clock timeout. It uses KVM when `/dev/kvm` is
usable, falling back to TCG (software emulation, slower but correct)
otherwise — GitHub's `ubuntu-24.04` runners have KVM available, but the
fallback keeps this correct anywhere else too.

The image itself carries a `systemd` unit, `ubx-e2e-assert.service`
(`WantedBy=multi-user.target`, baked in only when `bootRootfs` is called
with `withE2eAssertService = true` — never in a real, non-proof image),
that runs once `multi-user.target` is reached and checks, **inside the
guest**: the generation marker file exists, `/ubx/bin/ubx` is present and
executable, and `ubx --help` exits `0`. On success it echoes the
distinctive string `UBX-E2E-PASS` to the console (routed to the serial port
via `console=ttyS0` on the kernel command line) and calls
`systemctl poweroff`. The host-side harness never inspects the guest
directly — it only trusts what the guest itself asserted and printed, then
greps the captured serial log for that marker.

Per `tests/README.md`'s documented e2e contract, the harness exits `77`
(skip, not fail) when `qemu-system-x86_64` isn't on `PATH`, or when no
image can be resolved (no `--image`/`$UBX_BOOT_IMAGE`, and no `nix` to
build one) — the situation on this project's own dev harness today.
`tests/unit/072-e2e-harness-cli.sh` exercises exactly that skip path,
alongside the rest of the harness's plain argument-handling contract, with
no `qemu`/`nix` required.

## Known limitations (tracked, not blocking M1)

- **`/var`, `/tmp`, `/home` are tmpfs, not a real writable partition** — see
  "Writable state" above. M2 scope.
- **`MODULES=most` is assumed to cover `squashfs`/`virtio_blk`/`virtio_pci`**
  rather than being forced explicitly via a custom
  `/etc/initramfs-tools/modules` addition — see "How the initrd gets
  built" above. If wrong, the fix needs a small hardening pass (writing
  that file *before* `composeRootfs`'s own `dpkg --configure -a`, which
  today's `bootRootfs` cannot do — it only adds files *after* composition
  finishes, which is fine for everything else on this page but not for
  anything that needs to affect initrd *contents*).
- **No UUID/`search`-based GRUB root lookup** — `core.img`'s prefix is
  hardcoded to this image's own fixed single-disk layout. M2, once
  multiple physical targets matter.
- **One generation only** — `grubCfg`/`kernelArtifacts`/`bootRootfs` are
  already generation-list-shaped; nothing here builds `ubx rebuild`,
  retention, or rollback (GitHub issue #25, M2).
