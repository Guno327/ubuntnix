# nix/boot.nix — kernel selection + kernelParams, GRUB generation
# machinery, and bootable disk-image assembly (SPEC.md §4.2/§4.3, §6's
# `ubuntnix.boot` primitive; GitHub issue #10, milestone M1's final line
# item: "boots in QEMU with the /ubx store, Nix, and ubx skeleton aboard").
#
# -- What M1 needs vs. what M2 owns ------------------------------------
#
# SPEC.md §11's M1 exit criterion is narrower than full generation
# switching: "a flake-defined Ubuntu 24.04 image boots reproducibly [in
# QEMU]" — ONE generation, bootable, with a GRUB menu structure a future
# M2 (GitHub issue #25's generation model) can slot MORE generations into
# without a rewrite. Concretely, that split lands as:
#   - `mkBootSpec`/`kernelArtifacts`/`grubCfg` below are already
#     GENERATION-LIST-SHAPED (grubCfg takes an arbitrary-length ordered
#     list; kernelArtifacts extracts one generation's kernel+initrd at a
#     time) — M2 calls these again with a longer list, not differently;
#   - what M1 does NOT build: `ubx rebuild`, generation retention/GC,
#     live rollback, `/etc` generation, soft-reboot activation — all M2+
#     (SPEC.md §11).
#
# -- Pipeline (composeRootfs/squashfsImage are nix/compose.nix's) ---------
#
#   1. `mkBootSpec`/`resolveKernelFlavor`
#                         SPEC.md §6 `ubuntnix.boot = { kernel;
#                         kernelParams; }` primitive: validates the chosen
#                         kernel meta-package and resolves it to the
#                         concrete flavor (e.g. "6.8.0-31-generic") the
#                         locked archive actually carries — see
#                         `resolveKernelFlavor`'s own comment for the
#                         mechanism and its deliberate M1 narrowness.
#   2. `bootRootfs`       composeRootfs (nix/compose.nix), pinned to the
#                         FULL locked package set by default (kernel,
#                         initramfs-tools, grub, filesystem tools, ...
#                         all already in archive.lock.json — see that
#                         file's own header for the M1 provenance),
#                         PLUS this file's own minimal M1 writable-state
#                         story and the `/ubx` CLI skeleton (see its own
#                         comment below for exactly what and why).
#   3. `squashfsImage`    (nix/compose.nix) — the read-only rootfs image.
#   4. `kernelArtifacts`  extracts /boot/vmlinuz-<v> + /boot/initrd.img-<v>
#                         from the composed tree into their own small
#                         derivation (SPEC.md §4.2: "kernel and initrd
#                         come out of the composed rootfs itself").
#   5. `grubCfg`          renders grub.cfg for a generation list, via
#                         bin/ubx-gen-grub-cfg (see that script's own
#                         header for why this is a script, not inline Nix
#                         string interpolation).
#   6. `diskImage`        assembles the actual bootable raw disk: a FAT
#                         boot partition (GRUB + kernel + initrd) plus a
#                         raw squashfs partition, BIOS-bootable via
#                         grub-bios-setup. See that function's own header
#                         for the full layout rationale and its
#                         highest-risk step.
#
# See docs/boot.md for the end-to-end narrative (partition layout,
# read-only-root mechanism, M1's writable-state simplification, and the
# QEMU e2e harness) aimed at a human reader rather than at whoever's
# maintaining this file.
{ config, inputs, ... }:
let
  lib = inputs.nixpkgs.lib;

  inherit (config.flake.lib.stdenv) runInUbuntuBase;
  inherit (config.flake.lib.archive) lockfile debs;
  inherit (config.flake.lib.compose) composeRootfs squashfsImage toolsFHS;

  # -- primitive defaults (SPEC.md §6, this issue's task item 1) -----------
  #
  # "linux-image-virtual" per this issue's explicit design guidance (SPEC.md
  # §6's own worked example uses the illustrative name "linux-generic";
  # ubuntnix.boot.kernel is meant to take any real archive meta-package
  # name, and -virtual is the one this project's lockfile actually pins —
  # it is Ubuntu's minimal-driver-set flavor, the natural default for a
  # QEMU/virtualized target).
  defaultKernelPackage = "linux-image-virtual";

  # User-declarable extra command-line words: SPEC.md §6's own worked
  # example ("quiet"/"splash"). Boot-MECHANISM tokens this image needs
  # regardless of what a caller declares here (rootfstype=squashfs,
  # console=ttyS0 for the e2e harness's serial capture) are layered on
  # TOP of this list at the point a
  # generation entry is actually assembled (see this file's perSystem
  # block below) — they are not part of the user-facing primitive default,
  # exactly the same separation SPEC.md draws between primitives (what a
  # user declares) and the mechanism a module/the boot machinery compiles
  # that into.
  defaultKernelParams = [ "quiet" "splash" ];

  # -- validation (mirrors nix/compose.nix's renderPreseed guard style) ----
  #
  # A `kernelParams` entry becomes one whitespace-separated word on a GRUB
  # `linux` command line (grubCfg's rendering, via bin/ubx-gen-grub-cfg);
  # embedded whitespace would silently split into multiple words, and a
  # tab/newline would corrupt that script's tab-separated generation-record
  # format. Caught here, at the primitive boundary, rather than downstream
  # where the failure would be a confusing shell-quoting bug instead of a
  # clear Nix eval error.
  checkKernelParams = params:
    let
      bad = builtins.filter
        (p:
          !(builtins.isString p)
          || p == ""
          || lib.hasInfix " " p
          || lib.hasInfix "\t" p
          || lib.hasInfix "\n" p)
        params;
    in
    if bad == [ ]
    then params
    else
      throw ''
        ubuntnix.boot.kernelParams entries must be single non-empty,
        whitespace-free strings (one command-line word each); offending
        entrie(s): ${builtins.concatStringsSep ", " (map (p: builtins.toJSON p) bad)}'';

  # mkBootSpec — the primitive's own normalizer (issue #10 task item 1):
  # `{ kernel ? ..., kernelParams ? ... }` -> a validated, defaulted attrset.
  # Mirrors composeRootfs's own "validate and throw loudly at the eval-time
  # boundary" style. Does NOT resolve the kernel flavor itself (see
  # `resolveKernelFlavor` below) — a bootSpec is meaningful on its own as
  # the pure primitive value SPEC.md §6 declares, independent of which
  # concrete kernel build the archive currently happens to carry behind it.
  mkBootSpec =
    { kernel ? defaultKernelPackage
    , kernelParams ? defaultKernelParams
    }:
    if !(builtins.isString kernel) || kernel == "" then
      throw "ubuntnix.boot.kernel must be a non-empty string (a kernel meta-package name), got ${builtins.toJSON kernel}"
    else if !(debs ? ${kernel}) then
      throw "ubuntnix.boot.kernel '${kernel}' is not in the locked archive set (archive.lock.json) -- add it to archive.lock.json (nix/archive.nix) first."
    else
      { inherit kernel; kernelParams = checkKernelParams kernelParams; };

  # -- kernel flavor resolution ------------------------------------------
  #
  # A real Ubuntu install's `linux-image-virtual` is a tiny meta-package
  # (no files of its own) that Depends on a concrete flavor package,
  # `linux-image-<version>-generic` (archive.lock.json already pins both
  # "linux-image-virtual" and "linux-image-6.8.0-31-generic", the latter
  # having been pulled in as an actual dependency of the former by the real
  # apt solver — see bin/ubx-resolve/archive.packages.json). composeRootfs
  # does NOT do dependency resolution itself (nix/compose.nix's own header:
  # "dependency closure is the lockfile's/#20's job, not composition's") —
  # the caller supplies an explicit flat package list. That means THIS file
  # must independently know which concrete flavor package a given kernel
  # meta-package name resolves to, so it can predict the vmlinuz/initrd
  # filenames Debian's kernel packaging convention produces
  # (`/boot/vmlinuz-<flavor>`, `/boot/initrd.img-<flavor>`) — filenames that
  # only exist for real once the composed rootfs's own package hooks
  # (kernel postinst + update-initramfs; see docs/boot.md) have actually
  # run.
  #
  # Rather than parsing a .deb's own dependency metadata at eval time (real
  # work the project's real dependency-resolution machinery, issue #20,
  # does elsewhere — mixing that kind of import-from-derivation into this
  # file would cross SPEC.md §1.3's eval/build purity line the rest of this
  # project scrupulously keeps clean of), `resolveKernelFlavor` below takes
  # the pragmatic M1 shortcut: scan the ALREADY-LOCKED public package set
  # for the one entry shaped like a concrete generic kernel flavor
  # (`linux-image-<digit...>-generic`, excluding the "-virtual"/"-generic"
  # META names themselves, which don't start with a digit) and use it. For
  # the one series this project targets (noble, archive.lock.json's single
  # 6.8.0-31-generic entry) this is unambiguous; it throws loudly rather
  # than silently guessing if the lockfile ever carries zero or more than
  # one such entry, so a future lockfile update that adds a second kernel
  # flavor is forced to teach this file which meta-package maps to which
  # flavor instead of silently picking the wrong one.
  flavorPackages = builtins.filter
    (p: builtins.match "linux-image-[0-9].*-generic" p.name != null)
    lockfile.public.packages;

  resolveKernelFlavor = kernel:
    if kernel != defaultKernelPackage then
      throw ''
        boot: kernel selection other than "${defaultKernelPackage}" is not
        yet supported (M1 scope, GitHub issue #10) -- ${builtins.toJSON kernel}
        requested. Teach nix/boot.nix's resolveKernelFlavor the real
        meta-package -> flavor mapping (or parse it from the .deb's own
        Depends, once the project has general dependency-metadata parsing)
        before selecting a different kernel.''
    else if builtins.length flavorPackages == 0 then
      throw ''
        boot: no locked package matches "linux-image-<version>-generic" in
        archive.lock.json -- ${defaultKernelPackage} has nothing to
        resolve to. Lock a concrete kernel flavor package first.''
    else if builtins.length flavorPackages > 1 then
      throw ''
        boot: more than one locked package matches
        "linux-image-<version>-generic" (${builtins.concatStringsSep ", " (map (p: p.name) flavorPackages)})
        -- resolveKernelFlavor cannot pick one for "${defaultKernelPackage}"
        without a real meta-package -> flavor dependency mapping. Extend
        this function before adding a second kernel flavor to the
        lockfile.''
    else
      let
        pkg = builtins.elemAt flavorPackages 0;
        prefix = "linux-image-";
      in
      # "linux-image-6.8.0-31-generic" -> "6.8.0-31-generic"
      lib.removePrefix prefix pkg.name;

  # kernelPathsForFlavor — pure path arithmetic (Debian's own kernel-
  # packaging naming convention: the kernel postinst installs
  # /boot/vmlinuz-<flavor>; initramfs-tools' /etc/kernel/postinst.d hook,
  # triggered by that same postinst once both packages are unpacked — see
  # docs/boot.md — writes /boot/initrd.img-<flavor> right next to it). The
  # files these paths name only exist for real once `bootRootfs` below has
  # actually composed them; `kernelArtifacts` asserts that and extracts
  # them into their own small derivation.
  kernelPathsForFlavor = flavor: {
    vmlinuz = "/boot/vmlinuz-${flavor}";
    initrd = "/boot/initrd.img-${flavor}";
  };

  # concreteFlavorPackages — the two additional locked package NAMES a
  # given (meta-)kernel selection needs composed alongside it: the concrete
  # image and its matching modules tree (SPEC.md's own worked boot example
  # implies both travel together; a kernel with no /lib/modules for its own
  # version is a boot that can't load any driver at all).
  concreteFlavorPackages = flavor: [ "linux-image-${flavor}" "linux-modules-${flavor}" ];

  # -- the M1 boot image's full package set ---------------------------------
  #
  # composeRootfs takes an explicit flat list with no dependency resolution
  # of its own (see file header). archive.lock.json's 168 entries are
  # already the real apt-solver-resolved closure of archive.packages.json
  # (bin/ubx-resolve, issue #8/#20) -- which itself already declares every
  # top-level package this M1 boot image needs (the kernel, initramfs-tools,
  # grub-common/grub-pc-bin, parted, squashfs-tools, plus a few unrelated
  # small fixtures other proofs use). Rather than hand-picking a minimal
  # subset (real risk of silently dropping a transitive dependency dpkg
  # would only complain about deep inside a CI build), `bootPackages` is
  # deliberately the ENTIRE locked public set: a slightly larger image than
  # strictly necessary, but composed from a set the real apt solver already
  # proved mutually consistent as a whole. A future issue can trim this
  # once the project has real per-generation package-set declarations
  # (SPEC.md §6 `ubuntnix.debs`) to compose from instead of one shared
  # lockfile-wide set.
  bootPackages = map (p: p.name) lockfile.public.packages;

  # -- bootRootfs -------------------------------------------------------------
  #
  # composeRootfs (nix/compose.nix), aimed at a bootable system rather than a
  # narrow proof: defaults `packages` to `bootPackages` (the entire locked
  # archive, see above), then layers on the handful of plain files this
  # issue's scope needs that composeRootfs itself has no primitive for yet
  # (a generic `files` primitive is M2 scope, SPEC.md §6): the machine-id
  # placeholder, the minimal M1 writable-state units, and the `/ubx`
  # skeleton + CLI.
  #
  # IMPORTANT ORDERING NOTE (documented in docs/boot.md too): every file
  # this function adds is written AFTER composeRootfs has already finished
  # (and, transitively, after the kernel package's own postinst hook has
  # already triggered `update-initramfs` — see docs/boot.md for that
  # mechanism). None of the files added here need to be baked into the
  # initrd itself: the writable-state units are plain systemd unit files
  # read from the normal (squashfs) root at boot, not from the initrd, so
  # this ordering is fine for them. If a future addition here ever needs to
  # affect initrd CONTENTS (e.g. a custom initramfs-tools hook script), it
  # would need to run BEFORE composeRootfs's own dpkg --configure, which
  # this function does not attempt — see docs/boot.md's "known limitations"
  # section (this is exactly the `extraFiles`-on-composeRootfs extension a
  # earlier pass at this issue sketched but never implemented; still a
  # reasonable follow-up, not required for M1's own acceptance bar).
  bootRootfs =
    { name
    , bootSpec
    , packages ? bootPackages
    , preseed ? { }
    , generationIndex ? 1
    , withE2eAssertService ? false
    , system ? "x86_64-linux"
    }:
    let
      flavor = resolveKernelFlavor bootSpec.kernel;
      needed = [ bootSpec.kernel ] ++ concreteFlavorPackages flavor;
      missing = builtins.filter (p: !(builtins.elem p packages)) needed;
      checkedPackages =
        if missing == [ ]
        then packages
        else throw "bootRootfs: bootSpec's kernel package(s) not in the given `packages` list: ${builtins.concatStringsSep ", " missing}";

      base = composeRootfs { inherit name preseed system; packages = checkedPackages; };
      ubxScript = ../bin/ubx;

      # The writable-state units (SPEC.md §4.2 lists /var, /home, /ubx,
      # /flake as writable paths): plain tmpfs mounts, ordered before
      # local-fs.target so they're in place well before any service that
      # wants to write there starts (SPEC.md §4.2's own pragmatic-minimum
      # carve-out; a real per-partition/overlay scheme is M2 -- see
      # docs/boot.md for the tradeoff this makes, most notably that it
      # masks the dpkg status database compose-time baked under
      # /var/lib/dpkg with an empty tmpfs at boot).
      mountUnit = path: ''
        [Unit]
        Description=ubuntnix M1 writable ${path} (tmpfs; SPEC.md §4.2 -- see docs/boot.md)
        DefaultDependencies=no
        Before=local-fs.target

        [Mount]
        What=tmpfs
        Where=${path}
        Type=tmpfs
        Options=mode=0755

        [Install]
        WantedBy=local-fs.target
      '';

      e2eAssertScript = ''
        #!/bin/sh
        # /usr/local/bin/ubx-e2e-assert -- baked in ONLY when
        # withE2eAssertService is set (tests/e2e's own proof image; never a
        # real installer-produced system, SPEC.md §10). Runs once
        # multi-user.target is reached (this file's own .service unit,
        # below) and asserts exactly the three things GitHub issue #10's
        # e2e scope calls for: boot reached multi-user, a generation marker
        # file exists, and ubx is present and runnable -- then emits the
        # distinctive marker line the host-side harness
        # (tests/e2e/010-qemu-boot-e2e.sh) greps the captured serial log
        # for, and powers the guest off.
        set -e

        current="$(cat /ubx/generations/current 2>/dev/null || true)"
        if [ -z "$current" ] || [ ! -f "/ubx/generations/$current/marker" ]; then
          echo "UBX-E2E-FAIL: generation marker file missing (current='$current')"
          exit 1
        fi

        if [ ! -x /ubx/bin/ubx ]; then
          echo "UBX-E2E-FAIL: /ubx/bin/ubx missing or not executable"
          exit 1
        fi

        if ! /ubx/bin/ubx --help > /dev/null 2>&1; then
          echo "UBX-E2E-FAIL: /ubx/bin/ubx --help did not exit 0"
          exit 1
        fi

        echo "UBX-E2E-PASS"
        sync
        systemctl poweroff
      '';

      e2eAssertUnit = ''
        [Unit]
        Description=ubuntnix E2E boot assertions (tests/e2e; boot-image-proof only)
        After=multi-user.target
        Requires=multi-user.target

        [Service]
        Type=oneshot
        StandardOutput=journal+console
        StandardError=journal+console
        ExecStart=/usr/local/bin/ubx-e2e-assert

        [Install]
        WantedBy=multi-user.target
      '';

      writeUnitLines = builtins.concatStringsSep "\n" (map
        (path:
          let slug = builtins.replaceStrings [ "/" ] [ "-" ] path; in
          ''
            ubxrun "$UBX_BASE/bin/cat" > "$out/etc/systemd/system/ubx${slug}.mount" <<'UBX_UNIT_EOF'
            ${mountUnit path}
            UBX_UNIT_EOF
            ubxrun "$UBX_BASE/bin/mkdir" -p "$out/etc/systemd/system/local-fs.target.wants"
            ubxrun "$UBX_BASE/bin/ln" -sf "../ubx${slug}.mount" \
              "$out/etc/systemd/system/local-fs.target.wants/ubx${slug}.mount"
          '')
        [ "/var" "/tmp" "/home" ]);

      e2eLines =
        if !withE2eAssertService then "" else ''
          ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/bin/ubx-e2e-assert" <<'UBX_E2E_SCRIPT_EOF'
          ${e2eAssertScript}
          UBX_E2E_SCRIPT_EOF
          ubxrun "$UBX_BASE/bin/chmod" +x "$out/usr/local/bin/ubx-e2e-assert"

          ubxrun "$UBX_BASE/bin/cat" > "$out/etc/systemd/system/ubx-e2e-assert.service" <<'UBX_E2E_UNIT_EOF'
          ${e2eAssertUnit}
          UBX_E2E_UNIT_EOF
          ubxrun "$UBX_BASE/bin/mkdir" -p "$out/etc/systemd/system/multi-user.target.wants"
          ubxrun "$UBX_BASE/bin/ln" -sf ../ubx-e2e-assert.service \
            "$out/etc/systemd/system/multi-user.target.wants/ubx-e2e-assert.service"
        '';
    in
    runInUbuntuBase {
      inherit system;
      name = "boot-rootfs-${name}";
      env = { inherit base ubxScript; };
      script = ''
        ubxrun() { "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" "$@"; }

        ubxrun "$UBX_BASE/bin/mkdir" -p "$out"
        # Same reasoning as nix/compose.nix's own composeRootfs: the
        # --preserve=mode copy below faithfully carries $base's read-only
        # (0555) store-canonical top-level mode onto $out itself, which the
        # writes below need to create new entries under -- restore
        # owner-write on $out's OWN top-level mode only (cosmetic in the
        # final artifact regardless: Nix re-canonicalizes $out read-only at
        # registration).
        ubxrun "$UBX_BASE/bin/cp" -r --preserve=mode,timestamps,links --no-preserve=ownership "$base/." "$out/"
        # -R, not just $out's own top-level mode: Nix CANONICALIZES every
        # path inside a registered store output to a read-only mode (0444
        # for files, 0555 for directories) when it registers `$base`, and
        # the --preserve=mode copy above faithfully carries that whole
        # read-only tree onto $out. Restoring owner-write on $out alone is
        # therefore not enough -- the writes below create entries under
        # NESTED directories (/usr/local/bin, /etc, /ubx/...), each of
        # which arrives 0555 and rejects them ("ln: failed to create
        # symbolic link '.../usr/local/bin/ubx': Permission denied", CI run
        # 29957021613). Cosmetic in the final artifact either way: Nix
        # re-canonicalizes $out read-only at registration, and the image's
        # true set*id/ownership metadata is applied at mksquashfs pack time
        # from nix/compose.nix's pseudo-file manifest, not from these bits.
        ubxrun "$UBX_BASE/bin/chmod" -R u+w "$out"

        # -- /ubx store skeleton + the CLI aboard (scope item 3) -----------
        ubxrun "$UBX_BASE/bin/mkdir" -p "$out/ubx/bin" "$out/ubx/store" "$out/ubx/var"
        ubxrun "$UBX_BASE/bin/cp" "$ubxScript" "$out/ubx/bin/ubx"
        ubxrun "$UBX_BASE/bin/chmod" +x "$out/ubx/bin/ubx"
        ubxrun "$UBX_BASE/bin/mkdir" -p "$out/usr/local/bin"
        ubxrun "$UBX_BASE/bin/ln" -sf /ubx/bin/ubx "$out/usr/local/bin/ubx"

        # -- the per-generation marker (SPEC.md §4.3's generation model,
        #    kept intentionally tiny for M1 -- a real generation manifest
        #    is GitHub issue #25/M2 scope). "current" plus one marker file
        #    per generation index is already list-shaped: a future
        #    multi-generation bootRootfs caller just writes more of them.
        ubxrun "$UBX_BASE/bin/mkdir" -p "$out/ubx/generations/${toString generationIndex}"
        printf '%s' "${toString generationIndex}" > "$out/ubx/generations/current"
        : > "$out/ubx/generations/${toString generationIndex}/marker"

        # -- empty /etc/machine-id (SPEC.md §4.2's "machine-local mutable
        #    exceptions", created at first boot, never baked in -- mirrors
        #    every stock Ubuntu live/installer squashfs image for the
        #    identical reason: systemd bind-mounts a transient id from
        #    /run onto this existing-but-empty file when /etc is
        #    read-only, which needs the mountpoint file to already exist).
        : > "$out/etc/machine-id"

        # -- M1 minimal writable-state units (see this function's own
        #    header for the tradeoff) -----------------------------------
        ${writeUnitLines}

        ${e2eLines}
      '';
    };

  # -- kernelArtifacts --------------------------------------------------------
  #
  # { name, rootfs, flavor, system } -> $out/vmlinuz-<flavor>,
  # $out/initrd.img-<flavor>, $out/flavor: the two files SPEC.md §4.2 calls
  # out ("kernel and initrd come out of the composed rootfs itself"),
  # extracted into their own small derivation so a generation's GRUB entry
  # and disk image can depend on exactly these two files rather than the
  # whole composed tree. Deliberately NOT a glob over /boot/vmlinuz-* (which
  # would silently pick the wrong file, or fail ambiguously, if more than
  # one kernel were ever composed into the same tree) -- `flavor` (from
  # `resolveKernelFlavor`) names the expected files exactly, and a missing
  # one fails loudly with a pointer at *why* (docs/boot.md's
  # initramfs-generation mechanism).
  kernelArtifacts =
    { name, rootfs, flavor, system ? "x86_64-linux" }:
    let
      paths = kernelPathsForFlavor flavor;
    in
    runInUbuntuBase {
      inherit system;
      name = "kernel-artifacts-${name}";
      env = { inherit rootfs; };
      script = ''
        ubxrun() { "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" "$@"; }
        ubxrun "$UBX_BASE/bin/mkdir" -p "$out"

        vmlinuz="$rootfs${paths.vmlinuz}"
        initrd="$rootfs${paths.initrd}"

        [ -f "$vmlinuz" ] || {
          echo "kernelArtifacts: $vmlinuz not found in the composed rootfs -- expected linux-image-${flavor}'s own postinst to have placed it there during composition (see docs/boot.md)" >&2
          exit 1
        }
        [ -f "$initrd" ] || {
          echo "kernelArtifacts: $initrd not found in the composed rootfs -- update-initramfs did not produce an initrd for ${flavor} during composition (initramfs-tools' postinst hook should have run automatically -- see docs/boot.md)" >&2
          exit 1
        }

        ubxrun "$UBX_BASE/bin/cp" "$vmlinuz" "$out/vmlinuz-${flavor}"
        ubxrun "$UBX_BASE/bin/cp" "$initrd" "$out/initrd.img-${flavor}"
        printf '%s' "${flavor}" > "$out/flavor"
      '';
    };

  # -- grubCfg ----------------------------------------------------------------
  #
  # { name, generations, default, timeout, system } -> $out/grub.cfg,
  # rendered by bin/ubx-gen-grub-cfg (see that script's own header for why
  # rendering lives there rather than as inline Nix string interpolation).
  # `generations` is the SAME generation-list shape this whole file is
  # organized around: a list of
  #   { index, title, kernelPath, initrdPath, rootDevice, kernelParams ? [] }
  # attrsets, rendered here into that script's documented tab-separated
  # input format and passed straight through -- no reordering, no
  # generation-count assumption (M1 calls this with a one-element list; a
  # future M2 caller with more). `kernelPath`/`initrdPath` here are the
  # paths as GRUB itself will read them off the boot partition (this
  # file's `diskImage` copies the kernel/initrd to the FAT partition's
  # ROOT, so these are "/vmlinuz-<flavor>"/"/initrd.img-<flavor>", NOT the
  # "/boot/vmlinuz-<flavor>" composed-rootfs-relative paths
  # `kernelPathsForFlavor` returns -- two different addressing schemes for
  # two different filesystems, kept deliberately distinct rather than
  # reusing one name for both).
  grubCfg =
    { name
    , generations
    , default ? null
    , timeout ? 5
    , system ? "x86_64-linux"
    }:
    let
      requiredFields = [ "index" "title" "kernelPath" "initrdPath" "rootDevice" ];
      missingFields = builtins.filter (g: builtins.filter (f: !(g ? ${f})) requiredFields != [ ]) generations;
      checked =
        if generations == [ ] then
          throw "grubCfg: generations must not be an empty list"
        else if missingFields != [ ] then
          throw "grubCfg: every generation needs index/title/kernelPath/initrdPath/rootDevice (SPEC.md §4.2)"
        else
          generations;

      noTabsOrNewlines = s:
        if lib.hasInfix "\t" s || lib.hasInfix "\n" s then
          throw "grubCfg: a generation field must not contain a literal tab or newline: ${builtins.toJSON s}"
        else
          s;

      renderLine = g:
        let
          params = builtins.concatStringsSep " " (g.kernelParams or [ ]);
        in
        builtins.concatStringsSep "\t" (map noTabsOrNewlines [
          (toString g.index)
          g.title
          g.kernelPath
          g.initrdPath
          g.rootDevice
          params
        ]);

      generationsText = builtins.concatStringsSep "\n" (map renderLine checked);
      defaultArg = if default == null then "" else "--default ${lib.escapeShellArg (toString default)}";
    in
    runInUbuntuBase {
      inherit system;
      name = "grub-cfg-${name}";
      env = { genScript = ../bin/ubx-gen-grub-cfg; };
      script = ''
        ubxrun() { "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" "$@"; }
        ubxrun "$UBX_BASE/bin/mkdir" -p "$out"

        ubxrun "$UBX_BASE/bin/cat" > "$out/generations.tsv" <<'UBX_GENERATIONS_EOF'
        ${generationsText}
        UBX_GENERATIONS_EOF

        # `source`, not a child `bash <script>` exec: bin/ubx-gen-grub-cfg
        # is pure POSIX-ish bash with NO external command dependency at
        # all (see its own header), so nothing here needs the ubuntu-base
        # loader wrapper's "invoke a dynamically-linked child by absolute
        # path" caveat (nix/stdenv.nix's BOOTSTRAP CAVEAT) -- sourcing it
        # directly into THIS already-running bash process is simpler and
        # correctly propagates its `die`/`exit` calls as this derivation's
        # own build failure.
        set -- --generations "$out/generations.tsv" --timeout ${toString timeout} ${defaultArg} --out "$out/grub.cfg"
        # shellcheck disable=SC1090  # dynamic path is deliberate: $genScript is this derivation's own store-copied input
        source "$genScript"
      '';
    };

  # -- diskImage ----------------------------------------------------------
  #
  # { name, squashfs, kernel, grubCfgDrv, flavor, bootPartitionMiB, system }
  # -> $out/disk.img: a raw, BIOS-bootable whole-disk image (SPEC.md §4.1's
  # "GRUB because it is upstream Ubuntu's default bootloader" + this
  # issue's scope item 3). `squashfs` is a squashfsImage output, `kernel` a
  # kernelArtifacts output, `grubCfgDrv` a grubCfg output.
  #
  # -- Partition layout (msdos/MBR, matching grub-pc-bin's BIOS target) --
  #
  #   [ 1 MiB gap ][ partition 1: FAT32, /boot content ][ partition 2: raw squashfs bytes ]
  #
  # Two deliberate departures from a "normal" Ubuntu install, both chosen
  # so this derivation needs NO mount(2)/loop-device/root privilege at all
  # (the Nix build sandbox grants none of those, and shouldn't need to):
  #
  #   - **/boot is FAT, not ext2/ext4.** dosfstools + mtools (both already
  #     locked -- see archive.lock.json's own M1 provenance) can create AND
  #     populate a FAT filesystem entirely as a plain FILE (`mkfs.vfat` on
  #     a regular file; `mcopy`/`mmd`, mtools' whole reason to exist, write
  #     into a FAT image file directly, no mount needed). e2fsprogs has no
  #     analogous "populate without mounting" tool for ext, which is why
  #     this issue's own scope explicitly calls out dosfstools/mtools for
  #     "disk work" alongside e2fsprogs -- e2fsprogs is what a REAL system
  #     built by this same machinery would use to build a writable-state
  #     partition (M2), not this read-only, GRUB-and-kernel-only partition.
  #   - **the squashfs partition holds the squashfs image's bytes
  #     directly, with no wrapping filesystem.** A squashfs image already
  #     IS a complete, directly mountable filesystem (that's what
  #     `mksquashfs` in nix/compose.nix's `squashfsImage` already
  #     produces) -- writing it straight onto a partition and mounting
  #     that partition `-t squashfs` is the standard live-CD/embedded-
  #     image idiom, and it means this derivation never needs to create or
  #     populate a second filesystem at all.
  #
  # Both `parted` (partitioning) and `grub-bios-setup` (embedding GRUB's
  # boot code) are told to operate on the raw disk image FILE directly,
  # exactly as they would a real block device -- both tools' own device
  # abstractions (libparted's file backend; GRUB's hostdisk code, which
  # `stat`s its target and treats a regular file as a raw disk image) are
  # documented to support this, and it is the standard technique
  # image-building pipelines use to produce a BIOS-bootable raw disk with
  # no elevated privilege. Of every step in this file, THIS is the one
  # least proven in practice here: this dev harness has no `nix` (so
  # nothing in this whole flake has ever actually been built anywhere),
  # and grub-bios-setup-against-a-plain-file specifically has not been
  # smoke-tested outside Nix the way nix/stdenv.nix's loader trick was
  # before being encoded there. If CI's first build of `.#boot-image-proof`
  # fails inside the "embed GRUB's boot code" step below, that is this
  # exact assumption meeting reality -- mirroring nix/stdenv.nix's own
  # bootstrap and nix/compose.nix's unshare hardening, both of which also
  # needed real CI iteration (see their own git-blame'd CI run numbers)
  # before they worked; a `losetup`-backed fallback (attach the image as a
  # real loop device, which DOES need extra privilege the sandbox may not
  # grant either) is the documented next thing to try if so.
  diskImage =
    { name
    , squashfs
    , kernel
    , grubCfgDrv
    , flavor
    , bootPartitionMiB ? 256
    , system ? "x86_64-linux"
    }:
    let
      tools = toolsFHS {
        inherit system;
        name = "diskimage-${name}";
        # libdevmapper1.02.1 is grub-common's own runtime dep: grub-mkimage
        # and grub-bios-setup both link libdevmapper.so.1.02.1 (device-mapper
        # disk probing). toolsFHS unpacks each named deb flat with NO
        # dependency resolution, so the lib has to be named explicitly or
        # grub-mkimage dies with "libdevmapper.so.1.02.1: cannot open shared
        # object file" (CI run 29996514090). Already in archive.lock.json.
        packages = [ "grub-pc-bin" "grub-common" "grub2-common" "libdevmapper1.02.1" "dosfstools" "mtools" "parted" ];
      };
    in
    runInUbuntuBase {
      inherit system;
      name = "disk-image-${name}";
      env = { inherit squashfs kernel grubCfgDrv tools; };
      script = ''
        ubxrun() { "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" "$@"; }
        # toolsFHS's own flat extraction has no usrmerge symlinks (see
        # nix/compose.nix's squashfsImage comment on the identical issue
        # for liblzo2-2): both lib dirs are always on this combined path.
        toolrun() { "$UBX_LD" --library-path "$UBX_LIBRARY_PATH:$tools/usr/lib/x86_64-linux-gnu:$tools/lib/x86_64-linux-gnu" "$@"; }

        ubxrun "$UBX_BASE/bin/mkdir" -p "$out"

        for bin in \
          "$tools/usr/bin/grub-mkimage" \
          "$tools/usr/lib/grub/i386-pc/grub-bios-setup" \
          "$tools/usr/sbin/mkfs.vfat" \
          "$tools/usr/bin/mmd" \
          "$tools/usr/bin/mcopy" \
          "$tools/usr/sbin/parted" \
          "$tools/usr/lib/grub/i386-pc/boot.img"; do
          [ -e "$bin" ] || {
            echo "diskImage: expected tool file not found at $bin -- its package may install it under a different path than this derivation assumes (see this file's own header)" >&2
            exit 1
          }
        done

        version="${flavor}"

        # -- 0. point glibc's iconv at the base tree's gconv modules -----
        #       mkfs.vfat and mtools (mmd/mcopy) convert the FAT volume
        #       label and 8.3 short names between the DOS codepage (850 by
        #       default) and the locale charset via glibc iconv. glibc's
        #       GCONV_PATH is compiled in as the absolute
        #       /usr/lib/x86_64-linux-gnu/gconv, which does NOT exist inside
        #       the Nix sandbox — so iconv_open("...","CP850") fails
        #       ("Cannot initialize conversion from codepage 850 ...",
        #       CI run 29996044586), mtools falls back to its internal table,
        #       and even that errors out ("Error setting code page / Cannot
        #       initialize '::'"). Pointing GCONV_PATH at the base's own
        #       gconv dir lets iconv load CP850.so (shipped by libc6) again.
        export GCONV_PATH="$UBX_BASE/usr/lib/x86_64-linux-gnu/gconv"
        [ -d "$GCONV_PATH" ] || {
          echo "diskImage: gconv modules dir not found at $GCONV_PATH -- the ubuntu-base tree is expected to ship libc6's gconv modules; mtools/mkfs.vfat codepage conversion will fail without them" >&2
          exit 1
        }

        # -- 1. compute the fixed partition layout, in MiB, from the
        #       ACTUAL squashfs image size (parted/mtools/mkfs.vfat all
        #       speak MiB) -----------------------------------------------
        squashfs_bytes="$(ubxrun "$UBX_BASE/usr/bin/stat" -c%s "$squashfs/rootfs.squashfs")"
        mib=$((1024 * 1024))
        # Round UP to a whole MiB, then add 32 MiB of slack (squashfs
        # itself is exact-sized and read-only; the slack exists so a
        # slightly larger future squashfs from the same generation doesn't
        # require rethinking this arithmetic).
        squashfs_mib=$(( (squashfs_bytes + mib - 1) / mib + 32 ))

        boot_start_mib=1
        boot_size_mib=${toString bootPartitionMiB}
        boot_end_mib=$((boot_start_mib + boot_size_mib))
        squashfs_end_mib=$((boot_end_mib + squashfs_mib))

        echo "diskImage: boot partition ''${boot_start_mib}-''${boot_end_mib}MiB, squashfs partition ''${boot_end_mib}-''${squashfs_end_mib}MiB (rootfs.squashfs is ''${squashfs_bytes} bytes)"

        # -- 2. stage the FAT boot-partition CONTENT, then build+populate
        #       a standalone FAT filesystem FILE sized to the partition --
        #       via mtools' mcopy/mmd, which write directly into a FAT
        #       image file with no mount(2)/loop-device call at all (see
        #       this function's own header for why FAT, not ext, here).
        toolrun "$UBX_BASE/bin/mkdir" -p fatstage/grub/i386-pc
        toolrun "$UBX_BASE/bin/cp" "$tools"/usr/lib/grub/i386-pc/*.mod fatstage/grub/i386-pc/
        toolrun "$UBX_BASE/bin/cp" "$grubCfgDrv/grub.cfg" fatstage/grub/grub.cfg
        toolrun "$UBX_BASE/bin/cp" "$kernel/vmlinuz-$version" "fatstage/vmlinuz-$version"
        toolrun "$UBX_BASE/bin/cp" "$kernel/initrd.img-$version" "fatstage/initrd.img-$version"

        ubxrun "$UBX_BASE/usr/bin/truncate" -s "''${boot_size_mib}M" fatpart.img
        toolrun "$tools/usr/sbin/mkfs.vfat" -F 32 -n UBXBOOT fatpart.img > /dev/null

        toolrun "$tools/usr/bin/mmd" -i fatpart.img ::/grub ::/grub/i386-pc
        for f in fatstage/grub/i386-pc/*.mod; do
          base_f="$(ubxrun "$UBX_BASE/usr/bin/basename" "$f")"
          toolrun "$tools/usr/bin/mcopy" -i fatpart.img "$f" "::/grub/i386-pc/$base_f"
        done
        toolrun "$tools/usr/bin/mcopy" -i fatpart.img fatstage/grub/grub.cfg ::/grub/grub.cfg
        toolrun "$tools/usr/bin/mcopy" -i fatpart.img "fatstage/vmlinuz-$version" "::/vmlinuz-$version"
        toolrun "$tools/usr/bin/mcopy" -i fatpart.img "fatstage/initrd.img-$version" "::/initrd.img-$version"

        # -- 3. build GRUB's own standalone core.img: a small,
        #       self-contained i386-pc image embedded into the MBR's
        #       "embedding area" (below), distinct from the *.mod files
        #       just copied onto the FAT partition above (which core.img
        #       loads lazily at boot once it can read that partition). The
        #       prefix is hardcoded to this image's own fixed,
        #       single-generation-M1 layout -- (hd0,msdos1) is always the
        #       boot partition here -- rather than a `search`-based UUID
        #       lookup; UUID search is a reasonable M2 follow-up once
        #       multiple physical targets matter.
        toolrun "$tools/usr/bin/grub-mkimage" \
          -d "$tools/usr/lib/grub/i386-pc" \
          -O i386-pc -o core.img -p '(hd0,msdos1)/grub' \
          biosdisk part_msdos fat normal configfile linux search echo test ls cat halt reboot boot

        # -- 4. partition the raw disk image FILE directly (see this
        #       function's own header: parted's file backend needs no
        #       loop device/mount/elevated privilege). -------------------
        disk_size_mib=$squashfs_end_mib
        ubxrun "$UBX_BASE/usr/bin/truncate" -s "''${disk_size_mib}M" disk.img
        toolrun "$tools/usr/sbin/parted" --script disk.img -- \
          mklabel msdos \
          mkpart primary fat32 "''${boot_start_mib}MiB" "''${boot_end_mib}MiB" \
          set 1 boot on \
          mkpart primary "''${boot_end_mib}MiB" "''${squashfs_end_mib}MiB"

        # -- 5. lay the two partitions' content into place at their now-
        #       fixed byte offsets. -------------------------------------
        ubxrun "$UBX_BASE/bin/dd" if=fatpart.img of=disk.img bs=1M seek="$boot_start_mib" conv=notrunc status=none
        ubxrun "$UBX_BASE/bin/dd" if="$squashfs/rootfs.squashfs" of=disk.img bs=1M seek="$boot_end_mib" conv=notrunc status=none

        # -- 6. embed GRUB's boot code (see this function's own header:
        #       the single riskiest step here). boot.img (grub-pc-bin's
        #       own 512-byte MBR template) goes into sector 0; core.img
        #       (built above) into the embedding area between the MBR and
        #       partition 1. -------------------------------------------
        toolrun "$UBX_BASE/bin/mkdir" -p grub-setup-dir
        toolrun "$UBX_BASE/bin/cp" "$tools/usr/lib/grub/i386-pc/boot.img" grub-setup-dir/boot.img
        toolrun "$UBX_BASE/bin/cp" core.img grub-setup-dir/core.img
        printf '(hd0) %s\n' "$PWD/disk.img" > device.map
        # noble ships grub-bios-setup as a grub-pc-bin arch tool under
        # /usr/lib/grub/i386-pc/, NOT at /usr/sbin/ (grub-common's /usr/sbin
        # carries grub-mkconfig/grub-probe/... but not the BIOS setup tool);
        # confirmed against the noble grub-pc-bin/grub-common filelists.
        toolrun "$tools/usr/lib/grub/i386-pc/grub-bios-setup" \
          --directory=grub-setup-dir --device-map=device.map disk.img

        ubxrun "$UBX_BASE/bin/cp" disk.img "$out/disk.img"
      '';
    };
in
{
  flake.lib.boot = {
    inherit
      defaultKernelPackage
      defaultKernelParams
      mkBootSpec
      resolveKernelFlavor
      kernelPathsForFlavor
      concreteFlavorPackages
      bootPackages
      bootRootfs
      kernelArtifacts
      grubCfg
      diskImage;
  };

  systems = [ "x86_64-linux" ];

  perSystem = { system, ... }:
    let
      # The M1 boot-image-proof: SPEC.md §11's exit criterion in one
      # generation.
      bootSpec = mkBootSpec { };
      flavor = resolveKernelFlavor bootSpec.kernel;

      proofRootfs = bootRootfs {
        inherit system bootSpec;
        name = "boot-proof";
        withE2eAssertService = true;
      };

      proofSquashfs = squashfsImage {
        inherit system;
        name = "boot-proof";
        rootfs = proofRootfs;
      };

      proofKernel = kernelArtifacts {
        inherit system flavor;
        name = "boot-proof";
        rootfs = proofRootfs;
      };

      # Boot-mechanism kernel-command-line tokens, layered ON TOP of
      # bootSpec's own user-declarable kernelParams (SPEC.md §6's
      # `ubuntnix.boot.kernelParams` primitive) rather than folded into it
      # -- these exist because of HOW this image boots, not because a
      # user asked for them:
      #   rootfstype=squashfs  the root partition carries no other
      #                        filesystem-type signature to autodetect
      #                        (see diskImage's own header: no wrapping fs)
      #   console=ttyS0        routes kernel/systemd/the e2e assertion
      #                        unit's own output to the serial port the
      #                        QEMU e2e harness captures (tests/e2e)
      # (No init= override: archive.lock.json pins systemd-sysv since
      # PR #33, which provides the stock /sbin/init -> systemd symlink,
      # exactly as a real Ubuntu install boots.)
      proofGeneration = {
        index = 1;
        title = "ubuntnix generation 1 (${bootSpec.kernel})";
        kernelPath = "/vmlinuz-${flavor}";
        initrdPath = "/initrd.img-${flavor}";
        rootDevice = "/dev/vda2";
        kernelParams = bootSpec.kernelParams ++ [
          "rootfstype=squashfs"
          "console=ttyS0"
        ];
      };

      proofGrubCfg = grubCfg {
        inherit system;
        name = "boot-proof";
        generations = [ proofGeneration ];
      };

      proofDiskImage = diskImage {
        inherit system flavor;
        name = "boot-proof";
        squashfs = proofSquashfs;
        kernel = proofKernel;
        grubCfgDrv = proofGrubCfg;
      };
    in
    {
      packages.boot-kernel-artifacts-proof = proofKernel;
      packages.boot-grub-cfg-proof = proofGrubCfg;
      # The flake output proof this issue's scope calls for (item 4: "Expose
      # the image as a flake output proof (e.g. .#boot-image-proof)").
      packages.boot-image-proof = proofDiskImage;
    };
}
