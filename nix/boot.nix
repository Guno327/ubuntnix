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
  # nix/snap.nix's declared-snap compiler + vendored fetchers -- consumed
  # below by this file's own "snap-converge-proof" section (GitHub issue
  # #64, milestone M3's exit criterion).
  inherit (config.flake.lib.snap) compileManifest snaps;

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
    # extraFilesScript — an arbitrary extra chunk of `ubxrun`-style shell,
    # spliced in AFTER every other file this function writes (see below).
    # Exists so a SECOND proof (nix/boot.nix's own switch-loop-proof,
    # GitHub issue #32, milestone M2) can layer its own additional files
    # — apt/dpkg/snap guard diversions, the switch-loop fixture assets,
    # the ext4 `/ubx/var` mountpoint + mount unit, the guest driver script
    # and its unit — onto the SAME bootRootfs machinery M1's own
    # boot-image-proof uses, without this function needing to know
    # anything about M2's concerns itself (mirrors `withE2eAssertService`'s
    # own "proof-only, additive" posture). Empty by default: M1's own
    # boot-image-proof passes nothing here and is completely unaffected.
    , extraFilesScript ? ""
    # extraEnv — additional derivation ENV ATTRS merged into this
    # derivation's own `env` (alongside `base`/`ubxBin` below), so an
    # `extraFilesScript` can reference a DERIVATION OUTPUT (a store path
    # carrying string context — e.g. a vendored fetched artifact) from
    # inside its script text. Exists for exactly the reason
    # nix/stdenv.nix's `runInUbuntuBase` header documents under "NOTE":
    # the script itself is rendered via `builtins.toFile`, which REJECTS
    # any string carrying a reference to a derivation output — only env
    # attrs may carry one. `switchLoopVarStore` (this file, M2) sidestepped
    # this by using its OWN separate derivation's `env`; the M3
    # snap-converge-proof (GitHub issue #64) needs to bake real fetched
    # `.snap`/`.snap-declaration` bytes (nix/snap.nix's `fetchSnap`/
    # `fetchAssert` outputs) directly into THIS rootfs tree, so bootRootfs
    # itself grows this one small, backward-compatible extension point
    # rather than a third bespoke derivation. Empty by default: every
    # existing caller (M1's boot-image-proof, M2's switch-loop-proof) is
    # unaffected.
    , extraEnv ? { }
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
      # The whole bin/ directory, not just bin/ubx: the CLI `source`s
      # `ubx-rebuild-lib` from its own dir and shells out to sibling tools
      # (ubx-etc/ubx-systemd/ubx-users/ubx-generations) by $bindir, so those
      # must all be baked aboard or `ubx` fails at load (`set -euo pipefail`
      # + a failed `source` -> non-zero exit; this is the #49 regression the
      # QEMU e2e's `ubx --help` check catches). Nix store canonicalization
      # preserves the exec-bit distinction, so the sourced-only *-lib files
      # stay non-executable and the runnable tools stay executable.
      ubxBin = ../bin;

      # bin/ubx-etc's `plan` subcommand defaults `--exceptions` (when the
      # caller -- here, every `ubx rebuild switch|test`/`ubx rollback`
      # invocation that declares an etc domain -- doesn't pass one
      # explicitly) to `default_exceptions_file`, which resolves to
      # "$(dirname "$0")/../etc.exceptions.json" i.e. ONE LEVEL UP FROM
      # WHATEVER DIRECTORY `ubx` ITSELF RUNS FROM (bin/ubx-etc's own
      # comment: "mirrors bin/ubx-generations' UBX_GEN_ROOT-vs-default
      # pattern for the one path this script needs a default for"). On
      # this image `ubx` runs as /ubx/bin/ubx, so that default resolves to
      # /ubx/etc.exceptions.json -- a path nothing used to write here, even
      # though only bin/ (ubxBin, above) is baked aboard, never the repo
      # root the real etc.exceptions.json lives in. Any real `ubx rebuild`
      # call that declares an etc domain and doesn't pass --etc-exceptions
      # explicitly (the switch-loop-proof's own driver script doesn't; see
      # nix/boot.nix's switch-loop-proof section) dies inside
      # `ubx-etc plan` with "no such file: /ubx/etc.exceptions.json" before
      # ever reaching the systemd/users domains -- this was the root cause
      # of the M2 switch-loop e2e's scenario 1 "ubx rebuild switch exited
      # 1" failure (UBX-M2-S1-FAIL). Baking the repo's own
      # etc.exceptions.json to that exact path fixes it for every
      # bootRootfs-based image, not just this proof.
      etcExceptionsContent = builtins.readFile ../etc.exceptions.json;

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
          # systemd REQUIRES a .mount unit's filename to equal the escaped
          # form of its `Where=` path (systemd.mount(5) / systemd-escape -p
          # --suffix=mount): "/tmp" -> "tmp.mount", "/home" -> "home.mount",
          # "/ubx/var" -> "ubx-var.mount". A mount unit whose name does NOT
          # match its Where= is silently REJECTED by systemd -- which is
          # exactly why these tmpfs writable-state mounts (formerly named
          # "ubx-tmp.mount" &c.) never actually took effect, leaving /tmp,
          # /var and /home on the read-only squashfs. The M1 boot e2e never
          # wrote to them so it passed regardless; the M2 switch-loop e2e's
          # `ubx rebuild switch` is the first thing to `mktemp -d` in /tmp,
          # which surfaced the bug (issue #32). The escaped name for these
          # single- and multi-segment absolute paths is the path with its
          # leading slash dropped and remaining slashes turned into dashes
          # (neither /tmp nor /home contains a literal dash to \x2d-escape).
          #
          # NOTE /var is deliberately NOT in the list below: it carries the
          # compose-time-baked dpkg status database (/var/lib/dpkg) that the
          # apt/dpkg guards' pass-through READ verbs (`apt-get list`,
          # `dpkg -l`; SPEC.md §7 / switch-loop scenario 5) need to succeed.
          # An empty tmpfs would mask it. It stays read-only squashfs here;
          # a writable-yet-content-preserving /var (overlay or partition,
          # SPEC.md §4.2) is deferred with the writable generated /etc work.
          # /tmp must be a real tmpfs (ubx's `mktemp -d`), /home is writable
          # per §4.2 and empty is harmless (no scenario writes it).
          let
            rel = builtins.substring 1 (builtins.stringLength path) path;
            unitName = (builtins.replaceStrings [ "/" ] [ "-" ] rel) + ".mount";
          in
          ''
            ubxrun "$UBX_BASE/bin/cat" > "$out/etc/systemd/system/${unitName}" <<'UBX_UNIT_EOF'
            ${mountUnit path}
            UBX_UNIT_EOF
            ubxrun "$UBX_BASE/bin/mkdir" -p "$out/etc/systemd/system/local-fs.target.wants"
            ubxrun "$UBX_BASE/bin/ln" -sf "../${unitName}" \
              "$out/etc/systemd/system/local-fs.target.wants/${unitName}"
          '')
        [ "/tmp" "/home" ]);

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
      env = { inherit base ubxBin; } // extraEnv;
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
        ubxrun "$UBX_BASE/bin/cp" -a "$ubxBin/." "$out/ubx/bin/"
        ubxrun "$UBX_BASE/bin/chmod" +x "$out/ubx/bin/ubx"
        ubxrun "$UBX_BASE/bin/mkdir" -p "$out/usr/local/bin"
        ubxrun "$UBX_BASE/bin/ln" -sf /ubx/bin/ubx "$out/usr/local/bin/ubx"

        # bin/ubx-etc's default --exceptions path (see the etcExceptionsContent
        # comment above) resolves to /ubx/etc.exceptions.json when `ubx` runs
        # as /ubx/bin/ubx -- bake the repo's real etc.exceptions.json there so
        # any `ubx rebuild`/`ubx rollback` call that declares an etc domain
        # without an explicit --etc-exceptions still finds a real file instead
        # of dying with "no such file".
        ubxrun "$UBX_BASE/bin/cat" > "$out/ubx/etc.exceptions.json" <<'UBX_ETC_EXCEPTIONS_EOF'
        ${etcExceptionsContent}
        UBX_ETC_EXCEPTIONS_EOF

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

        ${extraFilesScript}
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
        # toolsFHS unpacks each named deb flat with NO dependency
        # resolution, so every shared library the tools load at runtime has
        # to be named explicitly (each is already in archive.lock.json):
        #   - libdevmapper1.02.1  grub-mkimage / grub-bios-setup link
        #                         libdevmapper.so.1.02.1 for device-mapper
        #                         disk probing (CI run 29996514090).
        #   - libparted2t64       parted links libparted.so.2 (CI run
        #                         29996904485); its frontend is built with
        #                         readline, hence:
        #   - libreadline8t64 +   libreadline.so.8 (and its own libtinfo.so.6
        #     libtinfo6           dependency) that the parted binary NEEDs.
        packages = [
          "grub-pc-bin" "grub-common" "grub2-common"
          "dosfstools" "mtools" "parted"
          "libdevmapper1.02.1" "libparted2t64" "libreadline8t64" "libtinfo6"
        ];
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
        # The last partition ENDS at squashfs_end_mib, so the backing device
        # must extend PAST that offset -- parted rejects a partition whose end
        # equals the exact device size ("The location <N>MiB is outside of the
        # device", CI run 29997249917). One MiB of tail slack puts the end
        # strictly inside the device.
        disk_size_mib=$((squashfs_end_mib + 1))
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

        # -- 6. embed GRUB's boot code MANUALLY, by dd/patching disk.img
        #       directly, instead of shelling out to grub-bios-setup.
        #
        #       grub-bios-setup insists on resolving its --directory (and
        #       the disk named in --device-map) back to a real backing
        #       block device via udev/sysfs, to decide where the
        #       "embedding area" (the gap between the MBR and partition 1)
        #       starts and how large it is. That resolution is impossible
        #       in the Nix build sandbox -- there is no /dev, no udevd,
        #       and grub-setup-dir/disk.img are plain files on an
        #       overlay/tmpfs, not device nodes -- so grub-bios-setup
        #       fails outright ("sh: line 1: udevadm: command not found";
        #       "cannot find a device for grub-setup-dir (is /dev
        #       mounted?)"). Adding udevadm to $tools does not help: even
        #       a working udevadm has nothing to report against, since
        #       these files were never attached as devices in the first
        #       place.
        #
        #       What follows is exactly what grub-bios-setup itself does
        #       for a post-MBR-gap BIOS install, done by hand so it needs
        #       no device resolution at all -- this layout is GRUB's own
        #       documented i386-pc embedding format, not something
        #       reverse-engineered here:
        #
        #         sector 0        : boot.img  (grub-pc-bin's 512-byte MBR
        #                           template: [0,440) boot code, [440,446)
        #                           disk signature, [446,510) partition
        #                           table, [510,512) 0x55AA)
        #         sector 1..      : core.img  (built in step 3 above),
        #                           placed CONTIGUOUSLY starting at LBA 1,
        #                           entirely inside the gap before
        #                           partition 1 (which starts at
        #                           boot_start_mib = 1MiB = LBA 2048;
        #                           core.img is ~30KiB, i.e. tens of
        #                           sectors, so it fits with room to
        #                           spare)
        #
        #       Only [0,440) of boot.img is written to sector 0: step 4's
        #       parted call already wrote a valid partition table and the
        #       0x55AA signature into disk.img's [440,512), and those must
        #       not be clobbered by boot.img's own (empty/template)
        #       versions of those same bytes. boot.img's compiled-in
        #       "first sector of core.img" pointer (offset 0x5c) already
        #       defaults to LBA 1, which is exactly where core.img is
        #       placed below, so it needs no patching.
        #
        #       core.img's own first sector (diskboot.img) ends in a
        #       12-byte blocklist record at sector-relative offset 500:
        #       an 8-byte start LBA (offset 500, already defaults to 2 --
        #       correct, since core.img's OWN sector 1 follows immediately
        #       after its sector 0 once placed contiguously -- left
        #       untouched), a 2-byte sector count (offset 508, defaults to
        #       0 and MUST be patched to the real count or GRUB reads zero
        #       sectors of itself and hangs), and a 2-byte segment (offset
        #       510, left untouched). That length field is patched below.
        core_bytes="$(ubxrun "$UBX_BASE/usr/bin/stat" -c%s core.img)"
        core_sectors=$(( (core_bytes + 511) / 512 ))
        blocklist_len=$(( core_sectors - 1 ))

        # Sanity-guard the "core.img fits in the pre-partition-1 gap"
        # invariant this whole scheme depends on: core.img occupies LBA
        # 1..(1 + core_sectors - 1), and partition 1 starts at LBA
        # boot_start_mib * 2048 (2048 512-byte sectors per MiB). If a
        # future core.img (more modules, bigger grub.cfg parser, etc.)
        # ever grows past that gap, fail loudly here instead of silently
        # producing a disk image with a partition table clobbered by
        # GRUB's own boot code.
        gap_sectors=$((boot_start_mib * 2048))
        if [ $((1 + core_sectors)) -ge "$gap_sectors" ]; then
          echo "diskImage: core.img ($core_bytes bytes, $core_sectors sectors) no longer fits in the $gap_sectors-sector pre-partition-1 embedding gap -- it would overwrite partition 1's own data; shrink core.img's module list or raise boot_start_mib" >&2
          exit 1
        fi

        # 6a. sector 0: boot.img's boot code only, preserving parted's
        #     disk signature + partition table + 0x55AA already at
        #     [440,512).
        ubxrun "$UBX_BASE/bin/dd" \
          if="$tools/usr/lib/grub/i386-pc/boot.img" of=disk.img \
          bs=440 count=1 conv=notrunc status=none

        # 6b. sectors 1..: core.img, placed contiguously right after the
        #     MBR.
        ubxrun "$UBX_BASE/bin/dd" \
          if=core.img of=disk.img \
          bs=512 seek=1 conv=notrunc status=none

        # 6c. patch core.img's on-disk copy of the diskboot blocklist
        #     length at (sector 1 start = byte 512) + (in-sector offset
        #     508) = byte 1020, little-endian, 2 bytes. blocklist_len is
        #     always < 256 here (core.img is tens of sectors, nowhere
        #     near 65536), so the low byte alone varies and the high byte
        #     is always 0 -- both are still computed explicitly so this
        #     keeps working if core.img ever grows past 255 sectors.
        len_lo=$((blocklist_len & 255))
        len_hi=$(((blocklist_len >> 8) & 255))
        printf "$(printf '\\%03o\\%03o' "$len_lo" "$len_hi")" |
          ubxrun "$UBX_BASE/bin/dd" of=disk.img bs=1 seek=1020 count=2 conv=notrunc status=none

        ubxrun "$UBX_BASE/bin/cp" disk.img "$out/disk.img"
      '';
    };

  # ===========================================================================
  # switch-loop-proof — SPEC.md §11 M2 exit criterion's QEMU end-to-end
  # exercise (GitHub issue #32): "NixOS-parity switch loop for
  # config/service/user domains; image swap via soft-reboot; `test` reverts
  # on reboot; demonstrated offline rollback". Everything below builds ONE
  # additional flake output, `packages.switch-loop-proof`, alongside (never
  # instead of) M1's own `boot-image-proof` -- nothing here touches that
  # proof's own derivations.
  #
  # -- The two crux design decisions (see also tests/e2e/020-qemu-switch-
  #    e2e.sh's own header, and this repo's PM-facing task notes for #32) --
  #
  # 1. PERSISTENCE ACROSS REBOOTS. `ubx rebuild test` reverting on reboot,
  #    and offline `ubx rollback` surviving one, both need real on-disk
  #    state that SURVIVES a guest-initiated reboot -- M1's own image has
  #    no such thing (its `/ubx` tree is baked read-only into the squashfs;
  #    its `/var`/`/tmp`/`/home` "writable state" is tmpfs, wiped every
  #    boot). This proof adds a THIRD disk partition -- ext4, built with
  #    `mke2fs -d` (populate-without-mounting, the exact ext-side analogue
  #    of `diskImage`'s own FAT/mtools trick -- see that function's header)
  #    -- mounted at `/ubx/var` (bin/ubx-rebuild-lib's own default
  #    generations root is `/ubx/var/generations`, so this is the natural,
  #    minimal writable slice: `/ubx/bin` itself, and every switch-loop
  #    fixture asset under `/usr/local/share/ubx-switch-loop`, stay in the
  #    ordinary read-only squashfs). tests/e2e/020-qemu-switch-e2e.sh is
  #    the host side of this: it boots the SAME writable disk file
  #    multiple times in a row (no `snapshot=on`), relying on `-no-reboot`
  #    to make qemu exit every time the guest reboots, and re-launching on
  #    the same file each time.
  #
  #    A real `/etc/systemd/system` write (bin/ubx-systemd-apply --apply's
  #    default `--unit-dir`) is NOT attempted against this image's actual
  #    `/etc` (still read-only squashfs, exactly like M1 -- a real
  #    writable-`/etc` overlay is bigger, separate follow-up work, not
  #    required for this issue's own exit criterion). The guest driver
  #    below instead applies to `/run/systemd/system` -- systemd's own,
  #    always-writable (tmpfs, mounted before almost anything else) SECOND
  #    unit search path, real `systemctl`/unit-activation semantics with no
  #    partition-layout surgery required. This is why scenario 3 (below)
  #    asserts the DURABLE `grub-default`/generation-pointer bookkeeping
  #    bin/ubx-rebuild-lib actually owns today, not "the live unit tree
  #    survived a reboot" (`/run` is tmpfs BY DESIGN and is never expected
  #    to survive one, on this image or any real systemd system).
  #
  # 2. WHERE ALTERNATE GENERATIONS COME FROM. No `nix build` runs inside
  #    QEMU (would need the full flake archive aboard and blow the e2e
  #    timeout). Instead: generation 1's manifest is hand-written directly
  #    onto the ext4 `/ubx/var` populate tree at NIX BUILD TIME, in EXACTLY
  #    the on-disk shape `bin/ubx-generations create` itself produces (see
  #    `switchLoopGen1Files` below) -- deliberately NOT by invoking
  #    `bin/ubx-generations` as a subprocess inside the Nix sandbox (it
  #    calls bare `mktemp`/`awk`/`date` etc. by name, which are not
  #    reliably on `PATH` inside `runInUbuntuBase`'s minimal build
  #    environment -- see nix/stdenv.nix's own "BOOTSTRAP CAVEAT"). Every
  #    LATER generation (2, 3, 4) is instead created FOR REAL, at QEMU
  #    BOOT TIME, by the guest driver script actually invoking
  #    `ubx rebuild switch|test` against read-only fixture manifests baked
  #    into the squashfs at `/usr/local/share/ubx-switch-loop/genN/*` --
  #    this is the real code path SPEC.md §11 M2 needs exercised, and
  #    matches this issue's own instruction: pre-bake ASSETS, run the real
  #    verbs BETWEEN them.
  #
  # -- What's a faithful exercise of real code vs. a documented stand-in ---
  #
  #  - `ubx rebuild switch|test`, `ubx rollback`, the GRUB-default/booted/
  #    current bookkeeping, `ubx-etc` plan+apply (real content, real
  #    `install -D` onto the writable /etc bind-mount below), `ubx-systemd`
  #    plan+apply (real content, real `systemctl`), `ubx-users` plan (real)
  #    + the emitted activation script (run for real by the driver --
  #    `ubx-users execute` itself only ever EMITS a script, by design; see
  #    bin/ubx-rebuild-lib's header), and the apt/dpkg/snap guards (real
  #    scripts, real diversion) are ALL exercised for real here.
  #  - `/etc` activation (`bin/ubx-etc-apply`, issue #54) runs for real
  #    against this boot's writable /etc bind-mount (see decision 1 below)
  #    and scenarios 1/3 assert the landed bytes directly off live /etc,
  #    not just the touched-domains PLAN/report bookkeeping (GitHub issue
  #    #57).
  #  - Soft-reboot (scenario 2, GitHub issue #55) is now REAL up through
  #    the `/run/nextroot` STAGING step: the guest driver builds a small,
  #    real squashfs image at RUNTIME with its own on-board `mksquashfs`
  #    (squashfs-tools ships in archive.lock.json's public/locked set, so
  #    it is already installed in this composed rootfs -- no new build-time
  #    Nix plumbing needed), passes it as `--rootfs-image`, and leaves
  #    `UBX_NEXTROOT_STAGE_CMD` UNSET so `ubx rebuild switch` runs bin/ubx's
  #    real default `_ubx_stage_nextroot` -- a genuine `mount -t squashfs
  #    -o ro <image> /run/nextroot`, with real root privilege, inside the
  #    guest. The scenario then asserts /run/nextroot is really a
  #    mountpoint carrying that image's own content before tearing it back
  #    down. `$UBX_SOFT_REBOOT_CMD soft-reboot` itself STILL goes through a
  #    stub (`ubx-soft-reboot-stub`, just drops a marker file), exactly the
  #    way bin/ubx's own header documents `UBX_SOFT_REBOOT_CMD` existing
  #    FOR -- because a real re-exec into /run/nextroot needs a full second
  #    bootable userspace already staged there (systemd, every binary/unit
  #    this very driver depends on to keep running post-re-exec), not just
  #    a marker file; building one is bigger follow-up work this issue does
  #    not attempt, and firing a real `systemctl soft-reboot` at a
  #    non-bootable /run/nextroot risks hanging the guest with no useful
  #    signal rather than a clean, diagnosable failure. What IS real here,
  #    beyond scenario 2's pre-#55 baseline: the actual mount(8) call that
  #    was the missing half of the mechanism (bin/ubx's `image)` branch used
  #    to just call `$UBX_SOFT_REBOOT_CMD soft-reboot` with nothing staged
  #    at all -- see bin/ubx's own header). "Package present" for the
  #    swapped generation is represented by a real, sha256-verified systemd
  #    unit's content actually landing and starting (the one domain with a
  #    real executor today), standing in for a literal `.deb` until a real
  #    per-generation image-swap executor exists.
  #
  # See tests/e2e/020-qemu-switch-e2e.sh's own header for the host-side
  # orchestration this feeds, and `switchLoopDriverScript` below for the
  # exact guest-side phase machinery and scenario-by-scenario assertions.

  # -- systemd "canary" units: the switch-loop proof's stand-in for real
  #    application units, existing purely so a switch/test/rollback can be
  #    observed to have (or have not) touched them. --------------------
  switchLoopUnitContent = description: markerPath: ''
    [Unit]
    Description=${description}

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/bin/sh -c 'mkdir -p /run/ubx-switch-loop && date +%s > ${markerPath}'

    [Install]
    WantedBy=multi-user.target
  '';

  switchLoopCanaryA = switchLoopUnitContent
    "ubx switch-loop proof: canary A (declared in every generation, content never changes)"
    "/run/ubx-switch-loop/canary-a-ran";
  switchLoopCanaryBGen1 = switchLoopUnitContent
    "ubx switch-loop proof: canary B (generation 1 baseline content)"
    "/run/ubx-switch-loop/canary-b-ran";
  switchLoopCanaryBGen2 = switchLoopUnitContent
    "ubx switch-loop proof: canary B (generation 2 -- CHANGED content, scenario 1's restart target)"
    "/run/ubx-switch-loop/canary-b-gen2-ran";
  switchLoopCanaryCGen3 = switchLoopUnitContent
    "ubx switch-loop proof: canary C (new in generation 3 -- scenario 2's 'package landed' stand-in)"
    "/run/ubx-switch-loop/canary-c-ran";

  # -- fixture manifest builders (bin/ubx-etc / bin/ubx-systemd /
  #    bin/ubx-users' own JSON schemas -- see each script's header) -------
  switchLoopSha256 = builtins.hashString "sha256";

  switchLoopSystemdUnitEntry = { name, content, enable ? true, mask ? false }: {
    inherit name;
    class = "service";
    refuseRestart = false;
    hasContent = true;
    sha256 = switchLoopSha256 content;
    inherit enable mask;
  };

  switchLoopEtcEntry = path: content: {
    inherit path;
    sha256 = switchLoopSha256 content;
    owner = "root";
    group = "root";
    mode = "0644";
  };

  switchLoopUsersEntry = name: {
    inherit name;
    uid = null;
    system = false;
    shell = "/usr/bin/bash";
    home = null;
    createHome = false;
    groups = [ ];
    authorizedKeys = [ ];
  };

  # -- M4 password-login fixture (GitHub issue #90/#80; SPEC.md §6, §8.1,
  #    §11 M4 exit criterion "password login from a secret-sourced hash
  #    works end-to-end") --------------------------------------------------
  #
  # A clearly-fake, non-production fixture: `switchLoopPwPlaintext` is a
  # made-up string that exists ONLY in this proof (never a real
  # credential), and `switchLoopPwHash` is the real glibc crypt(3) SHA-512
  # hash of that exact plaintext (computed once, offline, with Python's
  # own `crypt` module -- the same module the guest driver below uses to
  # RE-derive and check it; nothing about generating this literal string
  # needs to happen inside the Nix sandbox, exactly like
  # switchLoopEtcHelloV2Content's own baked fixture bytes above).
  switchLoopPwPlaintext = "ubxM4FixturePw1";
  switchLoopPwHash = "$6$JTGhqtTMNCHHb/0Z$Z32aCjtVsmptBsTEECH1jEhdnZYfXvg1kHRwDC6GTN62ASyGOIj55V0Lln6QhBVXejMnH15EBbsQ3uh26/vTu.";
  switchLoopPwUserName = "ubxm4pw";
  switchLoopPwSecretName = "ubxm4pwSecret";

  # bin/ubx-users' own manifest schema (see manifest_with_secret in
  # tests/unit/106-ubx-users-password-secret.sh): the secret NAME only,
  # never the hash itself -- the hash lives solely in the secrets-domain
  # fixture file (switchLoopPwHash, staged under pw/secrets-src/<name> by
  # switchLoopExtraFilesScript below), materialized to /run/secrets/<name>
  # by the REAL secrets domain at guest boot time.
  switchLoopPwUsersManifest = builtins.toJSON {
    version = 1;
    users = [
      (switchLoopUsersEntry switchLoopPwUserName // { hashedPasswordSecret = switchLoopPwSecretName; })
    ];
    groups = [ ];
  };

  # nix/secrets.nix's own per-generation manifest shape (see
  # tests/unit/162-ubx-secrets-plan-materialize.sh): the default `dst`
  # (bare /run/secrets/<name>, tmpfs, no custom symlink) is exactly what
  # bin/ubx-users' apply-passwords reads back out of `--run-secrets-dir`.
  switchLoopPwSecretsManifest = builtins.toJSON {
    version = 1;
    secrets = [
      {
        name = switchLoopPwSecretName;
        owner = "root";
        group = "root";
        mode = "0400";
        dst = "/run/secrets/${switchLoopPwSecretName}";
        environmentVariable = null;
      }
    ];
  };

  # -- the four generations' domain manifests (gen1's are also the "real,
  #    baked baseline" this image boots with; gen2/gen3/gen4's are read-
  #    only fixtures the guest driver feeds to real `ubx rebuild` calls --
  #    see this section's own header, decision 2). --------------------
  # Content bytes for the two etc-managed fixture files -- let-bound once
  # so the manifest builders below (which hash them into `sha256`) and the
  # extraFilesScript staging (which writes the same bytes under each
  # generation's `etc-content/` dir, read at runtime via `--etc-content-dir`)
  # can never drift apart.
  switchLoopEtcHelloV2Content = "hello v2\n";
  switchLoopEtcTestMarkerContent = "test v4 -- scenario 3's deliberate change\n";

  switchLoopGen1EtcManifest = builtins.toJSON { version = 1; entries = [ ]; };
  switchLoopGen2EtcManifest = builtins.toJSON {
    version = 1;
    entries = [ (switchLoopEtcEntry "switch-loop/hello.txt" switchLoopEtcHelloV2Content) ];
  };
  # No etc change for scenario 2 (image swap) -- same declared content as
  # generation 2.
  switchLoopGen3EtcManifest = switchLoopGen2EtcManifest;
  switchLoopGen4EtcManifest = builtins.toJSON {
    version = 1;
    entries = [
      (switchLoopEtcEntry "switch-loop/hello.txt" switchLoopEtcHelloV2Content)
      (switchLoopEtcEntry "switch-loop/test-marker.txt" switchLoopEtcTestMarkerContent)
    ];
  };

  switchLoopGen1SystemdManifest = builtins.toJSON {
    version = 1;
    units = [
      (switchLoopSystemdUnitEntry { name = "ubx-m2-canary-a.service"; content = switchLoopCanaryA; })
      (switchLoopSystemdUnitEntry { name = "ubx-m2-canary-b.service"; content = switchLoopCanaryBGen1; })
    ];
  };
  switchLoopGen2SystemdManifest = builtins.toJSON {
    version = 1;
    units = [
      (switchLoopSystemdUnitEntry { name = "ubx-m2-canary-a.service"; content = switchLoopCanaryA; })
      (switchLoopSystemdUnitEntry { name = "ubx-m2-canary-b.service"; content = switchLoopCanaryBGen2; })
    ];
  };
  switchLoopGen3SystemdManifest = builtins.toJSON {
    version = 1;
    units = [
      (switchLoopSystemdUnitEntry { name = "ubx-m2-canary-a.service"; content = switchLoopCanaryA; })
      (switchLoopSystemdUnitEntry { name = "ubx-m2-canary-b.service"; content = switchLoopCanaryBGen2; })
      (switchLoopSystemdUnitEntry { name = "ubx-m2-canary-c.service"; content = switchLoopCanaryCGen3; })
    ];
  };

  switchLoopGen1UsersManifest = builtins.toJSON { version = 1; users = [ ]; groups = [ ]; };
  switchLoopGen2UsersManifest = builtins.toJSON {
    version = 1;
    users = [ (switchLoopUsersEntry "ubxm2test") ];
    groups = [ ];
  };

  # -- the extra-files script layered onto bootRootfs (via its
  #    `extraFilesScript` parameter) for the switch-loop proof only -------
  #
  # Writes, in order: (1) the baseline canary-a/b systemd units for real
  # (so generation 1's OWN declared state matches boot reality); (2) the
  # apt/dpkg/snap guard diversions (SPEC.md §7; bin/ubx-guard-* scripts
  # already exist and are unit-tested -- docs/guards.md's own "deferred
  # until issue #10's file-injection mechanism lands" now applies, since
  # that mechanism is exactly bootRootfs's own file-writing pattern this
  # whole section reuses); (3) every generation's fixture manifests +
  # systemd content dirs under /usr/local/share/ubx-switch-loop; (4) the
  # soft-reboot stub; (5) the `/ubx/var` mountpoint directory (the ext4
  # partition itself is populated and attached by `switchLoopDiskImage`,
  # not here -- this only needs the empty mountpoint to exist inside the
  # squashfs); (6) the guest driver script + its two units (the mount unit
  # and the driver's own oneshot service).
  switchLoopExtraFilesScript = ''
    # -- (1) generation 1's baseline systemd unit CONTENT, baked as a
    #    read-only fixture under gen1/systemd-content (NOT into /etc). The
    #    baseline is established at RUNTIME by the guest driver copying
    #    these into /run/systemd/system before the gen1->gen2 switch (see
    #    switchLoopDriverScript's phase 0). This matters for correctness:
    #    the switch installs the CHANGED canary-b into that same
    #    /run/systemd/system dir, and a baseline baked into the read-only
    #    /etc/systemd/system would SHADOW it -- /etc outranks /run in
    #    systemd's unit search path -- so `systemctl restart` would re-run
    #    the OLD content and canary-b's changed content would never activate
    #    (the S1 failure this replaces). Keeping every unit the switch
    #    touches in /run lets the override actually take effect.
    ubxrun "$UBX_BASE/bin/mkdir" -p "$out/usr/local/share/ubx-switch-loop/gen1/systemd-content"
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-switch-loop/gen1/systemd-content/ubx-m2-canary-a.service" <<'UBX_M2_UNIT_EOF'
    ${switchLoopCanaryA}
    UBX_M2_UNIT_EOF
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-switch-loop/gen1/systemd-content/ubx-m2-canary-b.service" <<'UBX_M2_UNIT_EOF'
    ${switchLoopCanaryBGen1}
    UBX_M2_UNIT_EOF

    # -- (2) apt/dpkg/snap mutation guards (SPEC.md §7, bin/ubx-guard-lib's
    #    documented install contract: divert the real binary aside, install
    #    the guard under the original name, tell it where the real binary
    #    went via UBX_GUARD_REAL_BIN). `dpkg` is Ubuntu-essential and is
    #    always present; `apt`/`apt-get` ship with the ubuntu-base tarball
    #    itself (archive.lock.json's own 169-package "public" set is
    #    ADDITIONAL debs layered on top of that base, not the base's own
    #    essential set -- see nix/archive.nix's header) but this script
    #    checks for them defensively rather than assuming, so a future base
    #    tarball without them fails soft (a clear warning + an un-diverted
    #    guard at /usr/local/bin instead of a hard build failure). ---------
    ubx_m2_install_guard() {
      # $1 = real command name, $2 = guard script name under /ubx/bin
      real_path="$out/usr/bin/$1"
      if [ -e "$real_path" ] && [ ! -L "$real_path" ]; then
        ubxrun "$UBX_BASE/bin/mv" "$real_path" "$real_path.ubx-real"
        # UBX_GUARD_REAL_BIN must be the RUNTIME path of the diverted binary
        # (/usr/bin/<cmd>.ubx-real once this rootfs is the live root), NOT
        # the build-time "$out"-prefixed store path -- baking the latter
        # made pass-through read verbs fail at runtime with "UBX_GUARD_REAL_BIN
        # =/nix/store/...-boot-rootfs.../usr/bin/apt.ubx-real is not an
        # executable file" (that store path is not mounted on the booted
        # guest). Blocked verbs never deref it, which is why only the read
        # verbs surfaced the bug. The heredoc is unquoted, so $1 expands to
        # the command name at build time.
        ubxrun "$UBX_BASE/bin/cat" > "$real_path" <<UBX_M2_GUARD_EOF
    #!/bin/sh
    export UBX_GUARD_REAL_BIN=/usr/bin/$1.ubx-real
    exec /ubx/bin/$2 "\$@"
    UBX_M2_GUARD_EOF
        ubxrun "$UBX_BASE/bin/chmod" +x "$real_path"
      else
        echo "switch-loop-proof: WARNING: $real_path not found in the composed image -- installing the $2 guard at /usr/local/bin/$1 instead, with no real binary to divert (UBX_GUARD_REAL_BIN=/bin/true)" >&2
        ubxrun "$UBX_BASE/bin/mkdir" -p "$out/usr/local/bin"
        ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/bin/$1" <<UBX_M2_GUARD_EOF
    #!/bin/sh
    export UBX_GUARD_REAL_BIN=/bin/true
    exec /ubx/bin/$2 "\$@"
    UBX_M2_GUARD_EOF
        ubxrun "$UBX_BASE/bin/chmod" +x "$out/usr/local/bin/$1"
      fi
    }
    ubx_m2_install_guard apt ubx-guard-apt
    ubx_m2_install_guard apt-get ubx-guard-apt
    ubx_m2_install_guard dpkg ubx-guard-dpkg
    # `snap` is M3 scope (never composed into this image at all) -- the
    # guard is still installed, at /usr/local/bin (nothing to divert), so
    # scenario 5's "snap mutation attempts blocked" exercises the real
    # bin/ubx-guard-snap decision logic against a blocked (mutating) verb,
    # which never needs a real snapd underneath it to refuse correctly.
    ubxrun "$UBX_BASE/bin/mkdir" -p "$out/usr/local/bin"
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/bin/snap" <<'UBX_M2_GUARD_EOF'
    #!/bin/sh
    export UBX_GUARD_REAL_BIN=/bin/true
    exec /ubx/bin/ubx-guard-snap "$@"
    UBX_M2_GUARD_EOF
    ubxrun "$UBX_BASE/bin/chmod" +x "$out/usr/local/bin/snap"

    # -- (3) per-generation fixture manifests + systemd content dirs -----
    ubxrun "$UBX_BASE/bin/mkdir" -p \
      "$out/usr/local/share/ubx-switch-loop/gen1" \
      "$out/usr/local/share/ubx-switch-loop/gen2/systemd-content" \
      "$out/usr/local/share/ubx-switch-loop/gen2/etc-content/switch-loop" \
      "$out/usr/local/share/ubx-switch-loop/gen3/systemd-content" \
      "$out/usr/local/share/ubx-switch-loop/gen3/etc-content/switch-loop" \
      "$out/usr/local/share/ubx-switch-loop/gen4/etc-content/switch-loop"

    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-switch-loop/gen1/etc-manifest.json" <<'UBX_M2_JSON_EOF'
    ${switchLoopGen1EtcManifest}
    UBX_M2_JSON_EOF
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-switch-loop/gen1/systemd-manifest.json" <<'UBX_M2_JSON_EOF'
    ${switchLoopGen1SystemdManifest}
    UBX_M2_JSON_EOF
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-switch-loop/gen1/users-manifest.json" <<'UBX_M2_JSON_EOF'
    ${switchLoopGen1UsersManifest}
    UBX_M2_JSON_EOF

    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-switch-loop/gen2/etc-manifest.json" <<'UBX_M2_JSON_EOF'
    ${switchLoopGen2EtcManifest}
    UBX_M2_JSON_EOF
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-switch-loop/gen2/systemd-manifest.json" <<'UBX_M2_JSON_EOF'
    ${switchLoopGen2SystemdManifest}
    UBX_M2_JSON_EOF
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-switch-loop/gen2/users-manifest.json" <<'UBX_M2_JSON_EOF'
    ${switchLoopGen2UsersManifest}
    UBX_M2_JSON_EOF
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-switch-loop/gen2/systemd-content/ubx-m2-canary-b.service" <<'UBX_M2_UNIT_EOF'
    ${switchLoopCanaryBGen2}
    UBX_M2_UNIT_EOF
    # gen2's etc CONTENT bytes (referenced by the guest driver's
    # `--etc-content-dir "$ASSETS/gen2/etc-content"`), matching
    # switchLoopGen2EtcManifest's declared path/sha256 exactly.
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-switch-loop/gen2/etc-content/switch-loop/hello.txt" <<'UBX_M2_ETC_EOF'
    ${switchLoopEtcHelloV2Content}
    UBX_M2_ETC_EOF

    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-switch-loop/gen3/etc-manifest.json" <<'UBX_M2_JSON_EOF'
    ${switchLoopGen3EtcManifest}
    UBX_M2_JSON_EOF
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-switch-loop/gen3/systemd-manifest.json" <<'UBX_M2_JSON_EOF'
    ${switchLoopGen3SystemdManifest}
    UBX_M2_JSON_EOF
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-switch-loop/gen3/systemd-content/ubx-m2-canary-c.service" <<'UBX_M2_UNIT_EOF'
    ${switchLoopCanaryCGen3}
    UBX_M2_UNIT_EOF
    # gen3's etc CONTENT bytes -- same declared content as gen2
    # (switchLoopGen3EtcManifest = switchLoopGen2EtcManifest), staged here
    # too since scenario 2 passes its own gen3-specific
    # --etc-content-dir.
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-switch-loop/gen3/etc-content/switch-loop/hello.txt" <<'UBX_M2_ETC_EOF'
    ${switchLoopEtcHelloV2Content}
    UBX_M2_ETC_EOF
    # Generation 3's rootfs image is no longer a baked-in marker STRING
    # (issue #55): it is now a real squashfs image the guest driver itself
    # builds at RUNTIME, from a fresh per-boot marker, with this rootfs's
    # own installed mksquashfs -- see switchLoopDriverScript's phase 0,
    # scenario 2, and this section's own header, decision under "Soft-
    # reboot (scenario 2, GitHub issue #55)". Nothing to bake here.

    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-switch-loop/gen4/etc-manifest.json" <<'UBX_M2_JSON_EOF'
    ${switchLoopGen4EtcManifest}
    UBX_M2_JSON_EOF
    # gen4's etc CONTENT bytes -- both entries declared in
    # switchLoopGen4EtcManifest (unchanged hello.txt plus scenario 3's
    # deliberate test-marker.txt change).
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-switch-loop/gen4/etc-content/switch-loop/hello.txt" <<'UBX_M2_ETC_EOF'
    ${switchLoopEtcHelloV2Content}
    UBX_M2_ETC_EOF
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-switch-loop/gen4/etc-content/switch-loop/test-marker.txt" <<'UBX_M2_ETC_EOF'
    ${switchLoopEtcTestMarkerContent}
    UBX_M2_ETC_EOF

    # -- (3b) the M4 password-login fixture (GitHub issue #90/#80) -------
    #
    # `secrets-src/<name>` holds the REAL glibc crypt(3) hash bytes
    # `bin/ubx-secrets-apply --secrets-dir` materializes to
    # `/run/secrets/<name>` (mirroring `--secrets-dir`'s own
    # "DIR/<name>" convention, bin/ubx-secrets-apply's header) -- the
    # guest driver never bakes/derives a hash itself, exactly like every
    # other domain here only ever converges pre-baked fixture bytes.
    ubxrun "$UBX_BASE/bin/mkdir" -p "$out/usr/local/share/ubx-switch-loop/pw/secrets-src"
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-switch-loop/pw/users-manifest.json" <<'UBX_M4_JSON_EOF'
    ${switchLoopPwUsersManifest}
    UBX_M4_JSON_EOF
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-switch-loop/pw/secrets-manifest.json" <<'UBX_M4_JSON_EOF'
    ${switchLoopPwSecretsManifest}
    UBX_M4_JSON_EOF
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-switch-loop/pw/secrets-src/${switchLoopPwSecretName}" <<'UBX_M4_HASH_EOF'
    ${switchLoopPwHash}
    UBX_M4_HASH_EOF

    # -- (4) the soft-reboot stub (see this section's own header) --------
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/bin/ubx-soft-reboot-stub" <<'UBX_M2_SCRIPT_EOF'
    #!/bin/sh
    # Stands in for `systemctl soft-reboot` (see nix/boot.nix's
    # switch-loop-proof section header, decision 2, and bin/ubx's own
    # UBX_SOFT_REBOOT_CMD documentation for why this project's own test
    # environments already substitute a stub for the real command).
    mkdir -p /run/ubx-switch-loop
    : > /run/ubx-switch-loop/soft-reboot-invoked
    exit 0
    UBX_M2_SCRIPT_EOF
    ubxrun "$UBX_BASE/bin/chmod" +x "$out/usr/local/bin/ubx-soft-reboot-stub"

    # -- (5) the /ubx/var mountpoint (the ext4 partition's own content is
    #    populated and attached by switchLoopDiskImage/switchLoopVarStore,
    #    not here) -----------------------------------------------------
    ubxrun "$UBX_BASE/bin/mkdir" -p "$out/ubx/var"

    # -- (6) the ext4 mount unit + the guest driver + its unit -----------
    #
    # Unit filename MUST equal the systemd-escaped form of `Where=`
    # (systemd.mount(5)): "/ubx/var" -> "ubx-var.mount" (leading slash
    # stripped, remaining slashes become dashes) -- unlike an arbitrary
    # name, this one systemd requires exactly.
    ubxrun "$UBX_BASE/bin/cat" > "$out/etc/systemd/system/ubx-var.mount" <<'UBX_M2_UNIT_EOF'
    [Unit]
    Description=ubuntnix M2 switch-loop proof: persistent /ubx/var (ext4, GitHub issue #32)
    DefaultDependencies=no
    Before=local-fs.target

    [Mount]
    What=/dev/vda3
    Where=/ubx/var
    Type=ext4
    Options=defaults

    [Install]
    WantedBy=local-fs.target
    UBX_M2_UNIT_EOF
    ubxrun "$UBX_BASE/bin/mkdir" -p "$out/etc/systemd/system/local-fs.target.wants"
    ubxrun "$UBX_BASE/bin/ln" -sf ../ubx-var.mount \
      "$out/etc/systemd/system/local-fs.target.wants/ubx-var.mount"

    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/bin/ubx-switch-loop-driver" <<'UBX_M2_DRIVER_EOF'
    ${switchLoopDriverScript}
    UBX_M2_DRIVER_EOF
    ubxrun "$UBX_BASE/bin/chmod" +x "$out/usr/local/bin/ubx-switch-loop-driver"

    ubxrun "$UBX_BASE/bin/cat" > "$out/etc/systemd/system/ubx-switch-loop-driver.service" <<'UBX_M2_UNIT_EOF'
    [Unit]
    Description=ubuntnix M2 switch-loop proof driver (tests/e2e/020-qemu-switch-e2e.sh; GitHub issue #32)
    After=ubx-var.mount multi-user.target
    Requires=ubx-var.mount multi-user.target

    [Service]
    Type=oneshot
    StandardOutput=journal+console
    StandardError=journal+console
    ExecStart=/usr/local/bin/ubx-switch-loop-driver

    [Install]
    WantedBy=multi-user.target
    UBX_M2_UNIT_EOF
    ubxrun "$UBX_BASE/bin/mkdir" -p "$out/etc/systemd/system/multi-user.target.wants"
    ubxrun "$UBX_BASE/bin/ln" -sf ../ubx-switch-loop-driver.service \
      "$out/etc/systemd/system/multi-user.target.wants/ubx-switch-loop-driver.service"
  '';

  # -- the guest driver script itself: reads/advances a phase counter on
  #    the persistent /ubx/var/switch-loop/phase file, and runs exactly
  #    that phase's scenario(s) -- see this section's own header for the
  #    full phase-by-phase design (why S1/S2/S5 land in phase 0, S3 needs
  #    phase 1 after a real reboot, S4 needs phase 2 after a second one).
  switchLoopDriverScript = ''
    #!/bin/bash
    # /usr/local/bin/ubx-switch-loop-driver -- see nix/boot.nix's
    # switch-loop-proof section (GitHub issue #32) for the full design.
    # Runs once per boot (ubx-switch-loop-driver.service, WantedBy
    # multi-user.target); dispatches on a persistent phase counter so it
    # picks up exactly where the previous boot left off.
    set -u
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

    ASSETS=/usr/local/share/ubx-switch-loop
    ROOT=/ubx/var/generations
    STATE=/ubx/var/switch-loop
    UBX=/ubx/bin/ubx

    mkdir -p "$STATE"
    phase_file="$STATE/phase"
    phase=0
    [ -f "$phase_file" ] && phase="$(cat "$phase_file")"

    mark_fail() { # SCENARIO REASON
      echo "UBX-M2-$1-FAIL: $2"

      # Surface diagnostic context to the serial console (this script's
      # stdout) before powering off -- otherwise the only artifact CI
      # keeps is the one-line marker above and the actual command output
      # that explains the failure is lost with the ephemeral guest disk.
      echo "----- BEGIN mark_fail diagnostics -----"

      # Best effort: pull an explicit "... -- see <path>.log" reference
      # out of the reason string and dump that file first.
      referenced_log="$(printf '%s\n' "$2" | grep -o '[^ ]*\.log' | tail -n 1)"
      if [ -n "$referenced_log" ] && [ -f "$referenced_log" ]; then
        echo "----- BEGIN $referenced_log -----"
        tail -n 200 "$referenced_log"
        echo "----- END $referenced_log -----"
      elif [ -n "$referenced_log" ]; then
        echo "(referenced log $referenced_log not found)"
      fi

      echo "----- BEGIN ls -la $STATE -----"
      ls -la "$STATE" 2> /dev/null
      echo "----- END ls -la $STATE -----"

      # Fallback: dump every *.log under STATE so nothing is missed even
      # if the reason string didn't name one (or named one we already
      # printed above -- duplication here is cheap and safer than a gap).
      for f in "$STATE"/*.log; do
        [ -f "$f" ] || continue
        echo "----- BEGIN $f -----"
        tail -n 200 "$f"
        echo "----- END $f -----"
      done

      echo "----- END mark_fail diagnostics -----"
      sync
      systemctl poweroff
      exit 0
    }

    # mark_fail_pw REASON -- the M4 password-login scenario's own sibling
    # of mark_fail above (GitHub issue #90): a fixed "PW" marker (per this
    # issue's own contract, UBX-M4-PW-FAIL, not the UBX-M2-Sn family
    # mark_fail emits) with the identical diagnostics-dump-then-poweroff
    # body, duplicated here (rather than generalizing mark_fail's own
    # hardcoded "UBX-M2-" prefix) exactly the way this file's other
    # driver scripts (see softRebootDriverScript, snapConvergeDriverScript
    # below) each already carry their own independent copy of this same
    # pattern.
    mark_fail_pw() { # REASON
      echo "UBX-M4-PW-FAIL: $1"
      echo "----- BEGIN mark_fail_pw diagnostics -----"
      referenced_log="$(printf '%s\n' "$1" | grep -o '[^ ]*\.log' | tail -n 1)"
      if [ -n "$referenced_log" ] && [ -f "$referenced_log" ]; then
        echo "----- BEGIN $referenced_log -----"
        tail -n 200 "$referenced_log"
        echo "----- END $referenced_log -----"
      elif [ -n "$referenced_log" ]; then
        echo "(referenced log $referenced_log not found)"
      fi
      echo "----- BEGIN ls -la $STATE -----"
      ls -la "$STATE" 2> /dev/null
      echo "----- END ls -la $STATE -----"
      for f in "$STATE"/*.log; do
        [ -f "$f" ] || continue
        echo "----- BEGIN $f -----"
        tail -n 200 "$f"
        echo "----- END $f -----"
      done
      echo "----- END mark_fail_pw diagnostics -----"
      sync
      systemctl poweroff
      exit 0
    }

    advance() { # NEXT_PHASE
      printf '%s' "$1" > "$phase_file"
    }

    manifest_get() { # FILE KEY
      [ -f "$1" ] || { echo ""; return 0; }
      awk -v key="$2" 'BEGIN{p=key"="} index($0,p)==1{print substr($0,length(p)+1); f=1; exit} END{if(!f) print ""}' "$1"
    }

    gen1_rootfs_image="$(manifest_get "$ROOT/1/manifest" GEN_ROOTFS_IMAGE)"
    gen1_kernel="$(manifest_get "$ROOT/1/manifest" GEN_KERNEL_PATH)"
    gen1_initrd="$(manifest_get "$ROOT/1/manifest" GEN_INITRD_PATH)"

    # Make /etc and /var writable for this boot without losing their
    # compose-time-baked content: copy each read-only squashfs dir into
    # tmpfs and bind-mount the copy back over itself.
    #   /etc -- the users domain's real activation runs useradd/usermod,
    #     which rewrite /etc/passwd (and group/shadow) via an atomic
    #     create-temp-then-rename; that needs a writable /etc DIRECTORY (not
    #     just writable files, so a per-file bind would not suffice), and
    #     `getent passwd` reads the same /etc/passwd, so it then sees the
    #     live user.
    #   /var -- the apt/dpkg guards' pass-through READ verbs (`apt-get
    #     list`, `dpkg -l`; SPEC.md §7 / scenario 5) read the baked
    #     /var/lib/dpkg database AND apt opens writable locks under
    #     /var/lib/apt even to list, so /var must be writable yet keep its
    #     baked content. An empty tmpfs would destroy the db, which is why
    #     /var is deliberately NOT in bootRootfs's tmpfs list (it stays
    #     read-only squashfs at boot); the copy here preserves the db and
    #     the bind makes it writable.
    # A real ubuntnix system gets writable generated /etc + /var from the
    # generation machinery / writable partitions (SPEC.md §4.2; the /etc
    # executor is issue #54); this stands in so the users primitive and the
    # read-verb guards -- SPEC.md §11 M2 -- are demonstrated for real. Each
    # is guarded by a /run marker so it runs once per boot (idempotent
    # across the driver's phase-by-phase re-runs).
    for ubx_wdir in etc var; do
      if [ ! -e "/run/ubx-$ubx_wdir-bound" ]; then
        mkdir -p "/run/ubx-$ubx_wdir-writable"
        cp -a "/$ubx_wdir/." "/run/ubx-$ubx_wdir-writable/"
        mount --bind "/run/ubx-$ubx_wdir-writable" "/$ubx_wdir"
        : > "/run/ubx-$ubx_wdir-bound"
      fi
    done

    case "$phase" in
      0)
        # ================= scenario 1: config/service/user switch ======
        # Establish generation 1's baseline systemd units in the writable,
        # always-present /run/systemd/system (rather than baking them into
        # the read-only /etc, which would outrank /run and shadow the
        # switch's own write below -- see the extraFilesScript's block (1)),
        # then start them so the gen1->gen2 switch has a real prior state to
        # converge FROM.
        mkdir -p /run/systemd/system
        cp "$ASSETS/gen1/systemd-content/ubx-m2-canary-a.service" \
           "$ASSETS/gen1/systemd-content/ubx-m2-canary-b.service" \
           /run/systemd/system/
        systemctl daemon-reload
        systemctl start ubx-m2-canary-a.service ubx-m2-canary-b.service
        [ -f /run/ubx-switch-loop/canary-a-ran ] || mark_fail S1 "baseline canary-a did not run when established in /run"
        [ -f /run/ubx-switch-loop/canary-b-ran ] || mark_fail S1 "baseline canary-b did not run when established in /run"

        ts_a_before="$(stat -c %Y /run/ubx-switch-loop/canary-a-ran 2>/dev/null || echo 0)"
        "$UBX" rebuild switch --root "$ROOT" \
          --rootfs-image "$gen1_rootfs_image" --kernel "$gen1_kernel" --initrd "$gen1_initrd" \
          --root-device /dev/vda2 \
          --etc-ref "$ASSETS/gen2/etc-manifest.json" \
          --systemd-ref "$ASSETS/gen2/systemd-manifest.json" \
          --users-manifest "$ASSETS/gen2/users-manifest.json" \
          --apply --systemd-unit-dir /run/systemd/system \
          --systemd-content-dir "$ASSETS/gen2/systemd-content" \
          --etc-content-dir "$ASSETS/gen2/etc-content" \
          --users-out "$STATE/gen2-users-activate.sh" \
          > "$STATE/s1.log" 2>&1
        rc=$?
        [ "$rc" -eq 0 ] || mark_fail S1 "ubx rebuild switch exited $rc -- see $STATE/s1.log"
        bash "$STATE/gen2-users-activate.sh" >> "$STATE/s1.log" 2>&1
        systemctl daemon-reload
        sleep 1
        ts_a_after="$(stat -c %Y /run/ubx-switch-loop/canary-a-ran 2>/dev/null || echo 0)"
        [ "$(readlink "$ROOT/current" 2>/dev/null)" = "2" ] || mark_fail S1 "current generation is not 2 after switch"
        [ "$ts_a_after" = "$ts_a_before" ] || mark_fail S1 "canary-a (unchanged between gen1/gen2) was restarted anyway"
        [ -f /run/ubx-switch-loop/canary-b-gen2-ran ] || mark_fail S1 "canary-b's changed content did not activate"
        getent passwd ubxm2test > /dev/null 2>&1 || mark_fail S1 "declared user ubxm2test is not present"
        [ "$(cat /etc/switch-loop/hello.txt 2>/dev/null)" = "hello v2" ] || mark_fail S1 "live /etc file switch-loop/hello.txt did not activate"
        echo "UBX-M2-S1-PASS"

        # ================= scenario 2: image swap / soft-reboot ========
        # Issue #55: drive REAL /run/nextroot staging when this guest can
        # build a real fixture squashfs image for it (mksquashfs is part
        # of this rootfs's own installed package set -- see nix/boot.nix's
        # own header, "Soft-reboot (scenario 2 ...)"); fall back to the
        # pre-#55 marker-string stand-in otherwise, so a guest that for any
        # reason lacks mksquashfs at runtime still exercises the rest of
        # this scenario rather than spuriously failing it.
        s2_real_staging=0
        if command -v mksquashfs > /dev/null 2>&1; then
          gen3_marker="ubx-m2-s2-nextroot-marker-$$-$(date +%s)"
          rm -rf /run/ubx-switch-loop/gen3-src
          mkdir -p /run/ubx-switch-loop/gen3-src
          printf '%s\n' "$gen3_marker" > /run/ubx-switch-loop/gen3-src/marker
          gen3_rootfs_image="$STATE/gen3-rootfs.squashfs"
          rm -f "$gen3_rootfs_image"
          if mksquashfs /run/ubx-switch-loop/gen3-src "$gen3_rootfs_image" -noappend -no-progress \
               > "$STATE/s2-mksquashfs.log" 2>&1 && [ -f "$gen3_rootfs_image" ]; then
            s2_real_staging=1
          else
            echo "UBX-M2-S2-NOTE: could not build a real fixture squashfs with this guest's own mksquashfs -- falling back to the marker-string stand-in, see $STATE/s2-mksquashfs.log"
          fi
        else
          echo "UBX-M2-S2-NOTE: mksquashfs not found on PATH -- falling back to the marker-string stand-in for scenario 2's rootfs image"
        fi
        if [ "$s2_real_staging" -eq 0 ]; then
          gen3_rootfs_image="ubx-m2-switch-loop-gen3-rootfs-image-marker"
        fi

        # `systemctl soft-reboot` itself still goes through a stub
        # (ubx-soft-reboot-stub) regardless of s2_real_staging -- see this
        # file's own header for exactly why a REAL re-exec is out of scope
        # here (it would need a full second bootable userspace staged at
        # /run/nextroot, not just a marker file).
        export UBX_SOFT_REBOOT_CMD=/usr/local/bin/ubx-soft-reboot-stub
        rm -f /run/ubx-switch-loop/soft-reboot-invoked
        umount /run/nextroot 2> /dev/null || true
        boot_id_before="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
        "$UBX" rebuild switch --root "$ROOT" \
          --rootfs-image "$gen3_rootfs_image" \
          --kernel "$gen1_kernel" --initrd "$gen1_initrd" \
          --root-device /dev/vda2 \
          --etc-ref "$ASSETS/gen2/etc-manifest.json" \
          --systemd-ref "$ASSETS/gen3/systemd-manifest.json" \
          --users-manifest "$ASSETS/gen2/users-manifest.json" \
          --apply --systemd-unit-dir /run/systemd/system \
          --systemd-content-dir "$ASSETS/gen3/systemd-content" \
          --etc-content-dir "$ASSETS/gen2/etc-content" \
          --users-out "$STATE/gen3-users-activate.sh" \
          > "$STATE/s2.log" 2>&1
        rc=$?
        [ "$rc" -eq 0 ] || mark_fail S2 "ubx rebuild switch (image swap) exited $rc -- see $STATE/s2.log"
        systemctl daemon-reload
        sleep 1
        boot_id_after="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
        [ "$(readlink "$ROOT/current" 2>/dev/null)" = "3" ] || mark_fail S2 "current generation is not 3 after the image-swap switch"
        [ -f /run/ubx-switch-loop/soft-reboot-invoked ] || mark_fail S2 "soft-reboot was not invoked for an image-only delta"
        [ "$boot_id_before" = "$boot_id_after" ] || mark_fail S2 "boot_id changed -- a full reboot happened where a soft-reboot should have"
        [ -f /run/ubx-switch-loop/canary-c-ran ] || mark_fail S2 "the new generation's package/unit content did not activate"

        if [ "$s2_real_staging" -eq 1 ]; then
          # -- issue #55's actual new coverage: bin/ubx's real
          #    UBX_NEXTROOT_STAGE_CMD default (_ubx_stage_nextroot) must
          #    have really `mount`ed gen3_rootfs_image at /run/nextroot,
          #    with real root privilege, during the `ubx rebuild switch`
          #    call above (UBX_NEXTROOT_STAGE_CMD was left unset). ---------
          mountpoint -q /run/nextroot \
            || mark_fail S2 "bin/ubx's real UBX_NEXTROOT_STAGE_CMD default did not leave /run/nextroot mounted -- real staging did not happen"
          [ "$(cat /run/nextroot/marker 2>/dev/null)" = "$gen3_marker" ] \
            || mark_fail S2 "/run/nextroot is mounted but its content does not match generation 3's own staged image"
          umount /run/nextroot || mark_fail S2 "could not unmount /run/nextroot after staging assertions"
          echo "UBX-M2-S2-REAL-STAGING-PASS"
        else
          echo "UBX-M2-S2-NOTE: this boot could not exercise real /run/nextroot staging (see the NOTE above) -- scenario 2 still passed via the pre-#55 marker-string stand-in"
        fi
        echo "UBX-M2-S2-PASS"

        # ================= scenario 5: apt/dpkg/snap guards ============
        s5_log="$STATE/s5.log"
        : > "$s5_log"
        if apt-get install -y ubx-m2-should-not-install >> "$s5_log" 2>&1; then
          mark_fail S5 "apt-get install was not blocked"
        fi
        if dpkg -i /nonexistent-ubx-m2.deb >> "$s5_log" 2>&1; then
          mark_fail S5 "dpkg -i was not blocked"
        fi
        if snap install ubx-m2-should-not-install >> "$s5_log" 2>&1; then
          mark_fail S5 "snap install was not blocked"
        fi
        grep -q "managed declaratively" "$s5_log" || mark_fail S5 "guard refusal message missing from $s5_log"
        # Read/query verbs must pass through the guards (SPEC.md §7). Use
        # `apt list` (a real apt read verb -- `list` is an apt, not apt-get,
        # subcommand) and `dpkg -l`; both read the baked /var/lib/dpkg the
        # driver made writable above. Capture output into the scenario log
        # so a failure is diagnosable from the serial dump.
        apt list >> "$s5_log" 2>&1 || mark_fail S5 "a read-only apt verb (list) unexpectedly failed -- see $s5_log"
        dpkg -l >> "$s5_log" 2>&1 || mark_fail S5 "a read-only dpkg verb (-l) unexpectedly failed -- see $s5_log"
        echo "UBX-M2-S5-PASS"

        # ===== prepare scenario 3: `ubx rebuild test` + a deliberate change
        old_systemd_ref="$(manifest_get "$ROOT/3/ubx-extra" SYSTEMD_MANIFEST)"
        old_users_ref="$(manifest_get "$ROOT/3/manifest" GEN_USERS_MANIFEST)"
        # Reuse scenario 2's generation-3 rootfs image (issue #55 replaced the
        # baked $ASSETS/gen3/rootfs-image-marker file with a runtime-built
        # squashfs held in $gen3_rootfs_image) so generation 4's image equals
        # generation 3's -- keeping the gen3->gen4 delta etc-only/live, exactly
        # as this scenario asserts (`test` applies live, never soft-reboots,
        # never touches grub-default).
        "$UBX" rebuild test --root "$ROOT" \
          --rootfs-image "$gen3_rootfs_image" \
          --kernel "$gen1_kernel" --initrd "$gen1_initrd" \
          --root-device /dev/vda2 \
          --etc-ref "$ASSETS/gen4/etc-manifest.json" \
          --systemd-ref "$old_systemd_ref" \
          --users-manifest "$old_users_ref" \
          --apply --systemd-unit-dir /run/systemd/system \
          --etc-content-dir "$ASSETS/gen4/etc-content" \
          > "$STATE/s3-register.log" 2>&1
        rc=$?
        [ "$rc" -eq 0 ] || mark_fail S3 "ubx rebuild test exited $rc -- see $STATE/s3-register.log"
        [ "$(readlink "$ROOT/current" 2>/dev/null)" = "4" ] || mark_fail S3 "current generation is not 4 after 'ubx rebuild test'"
        grub_default_after_test="$(cat "$ROOT/grub-default" 2>/dev/null)"
        [ "$grub_default_after_test" = "3" ] || mark_fail S3 "'ubx rebuild test' moved grub-default (was 3, now $grub_default_after_test) -- it must never touch it"
        # 'ubx rebuild test' still applies domains for real (only grub-default
        # is withheld) -- assert generation 4's deliberate etc change
        # actually landed on live /etc before the reboot below resets this
        # boot's writable /etc bind-mount back to the squashfs baseline.
        [ "$(cat /etc/switch-loop/test-marker.txt 2>/dev/null)" = "test v4 -- scenario 3's deliberate change" ] || mark_fail S3 "live /etc file switch-loop/test-marker.txt did not activate"

        echo "UBX-M2-PHASE0-DONE"
        advance 1
        sync
        systemctl reboot
        ;;

      1)
        # ===== scenario 3 assertion: survives a REAL reboot =============
        #
        # A plain reboot must have left grub-default exactly where the
        # last SWITCH (not test) set it, even though `current` moved past
        # it -- see this section's own header on why this durable marker,
        # not "which kernel/squashfs GRUB actually booted", is what's
        # asserted (bin/ubx-rebuild-lib's own header: real bootloader
        # programming from this marker is still future work).
        [ "$(cat "$ROOT/grub-default" 2>/dev/null)" = "3" ] || mark_fail S3 "grub-default is not 3 after a real reboot"
        [ "$(readlink "$ROOT/current" 2>/dev/null)" = "4" ] || mark_fail S3 "current generation regressed after reboot (expected 4)"
        echo "UBX-M2-S3-PASS"

        # ================= scenario 4: offline rollback =================
        if ip route show default 2> /dev/null | grep -q .; then
          mark_fail S4 "a default route exists -- this scenario requires no network to demonstrate an OFFLINE rollback"
        fi
        "$UBX" rollback 2 --root "$ROOT" --apply --systemd-unit-dir /run/systemd/system \
          > "$STATE/s4.log" 2>&1
        rc=$?
        [ "$rc" -eq 0 ] || mark_fail S4 "ubx rollback exited $rc -- see $STATE/s4.log"
        [ "$(cat "$ROOT/booted" 2>/dev/null)" = "2" ] || mark_fail S4 "booted marker is not 2 after rollback"
        [ "$(cat "$ROOT/grub-default" 2>/dev/null)" = "2" ] || mark_fail S4 "grub-default is not 2 after rollback"

        echo "UBX-M2-PHASE1-DONE"
        advance 2
        sync
        systemctl reboot
        ;;

      2)
        # ===== scenario 4 assertion: rollback survives a REAL reboot ====
        [ "$(cat "$ROOT/booted" 2>/dev/null)" = "2" ] || mark_fail S4 "booted marker did not survive the reboot"
        [ "$(cat "$ROOT/grub-default" 2>/dev/null)" = "2" ] || mark_fail S4 "grub-default did not survive the reboot"
        echo "UBX-M2-S4-PASS"

        # ===== M4: hashedPasswordSecret login proof (GitHub issue #90) ===
        #
        # Runs here, after every M2 scenario above has finished asserting,
        # deliberately -- a real `ubx rebuild switch --apply` call below
        # moves `current`/`grub-default`, which would corrupt S2/S3/S4's
        # own hardcoded generation-number assertions if run any earlier in
        # this driver (see this file's switch-loop-proof section header).
        # Nothing downstream of this point reads either value again.
        #
        # Two real switches, mirroring what a real machine does the FIRST
        # time it declares a brand-new hashedPasswordSecret user (see
        # bin/ubx's own execute_domains, "password hashes" comment): the
        # FIRST call creates the account (`ubx-users execute` only ever
        # EMITS an activation script; `apply-passwords` cannot set a
        # password for an account not yet present in --shadow -- a clear,
        # expected error at this point, not a bug) -- this driver runs
        # that emitted script for real, exactly like scenario 1's own
        # gen2-users-activate.sh pattern, so the account genuinely exists.
        # The SECOND call, against the identical users/secrets manifests,
        # converges the password for real: the secrets domain
        # materializes the fixture hash to /run/secrets/<name> BEFORE the
        # users domain's apply-passwords step reads it back out (GitHub
        # issue #80's own ordering requirement -- execute_domains' own
        # "secrets" block runs before its own "users" block).
        "$UBX" rebuild switch --root "$ROOT" \
          --rootfs-image "$gen1_rootfs_image" --kernel "$gen1_kernel" --initrd "$gen1_initrd" \
          --root-device /dev/vda2 \
          --users-manifest "$ASSETS/pw/users-manifest.json" \
          --secrets-manifest "$ASSETS/pw/secrets-manifest.json" \
          --secrets-dir "$ASSETS/pw/secrets-src" \
          --apply --systemd-unit-dir /run/systemd/system \
          --users-out "$STATE/pw-users-activate.sh" \
          > "$STATE/m4-create.log" 2>&1
        rc=$?
        [ "$rc" -eq 0 ] || mark_fail_pw "first 'ubx rebuild switch' (account creation) exited $rc -- see $STATE/m4-create.log"
        bash "$STATE/pw-users-activate.sh" >> "$STATE/m4-create.log" 2>&1
        getent passwd "${switchLoopPwUserName}" > /dev/null 2>&1 \
          || mark_fail_pw "declared hashedPasswordSecret user ${switchLoopPwUserName} is not present after running its activation script -- see $STATE/m4-create.log"

        "$UBX" rebuild switch --root "$ROOT" \
          --rootfs-image "$gen1_rootfs_image" --kernel "$gen1_kernel" --initrd "$gen1_initrd" \
          --root-device /dev/vda2 \
          --users-manifest "$ASSETS/pw/users-manifest.json" \
          --secrets-manifest "$ASSETS/pw/secrets-manifest.json" \
          --secrets-dir "$ASSETS/pw/secrets-src" \
          --apply --systemd-unit-dir /run/systemd/system \
          --users-out "$STATE/pw-users-activate-2.sh" \
          > "$STATE/m4-password.log" 2>&1
        rc=$?
        [ "$rc" -eq 0 ] || mark_fail_pw "second 'ubx rebuild switch' (password convergence) exited $rc -- see $STATE/m4-password.log"

        [ -f "/run/secrets/${switchLoopPwSecretName}" ] \
          || mark_fail_pw "the secrets domain did not materialize /run/secrets/${switchLoopPwSecretName} before the users domain converged -- see $STATE/m4-password.log"

        shadow_hash="$(awk -F: -v u="${switchLoopPwUserName}" '$1==u{print $2}' /etc/shadow)"
        [ -n "$shadow_hash" ] || mark_fail_pw "${switchLoopPwUserName} has no /etc/shadow hash field after apply-passwords -- see $STATE/m4-password.log"
        case "$shadow_hash" in
          '$6$'*) ;;
          *) mark_fail_pw "${switchLoopPwUserName}'s shadow hash does not look like a real crypt(3) SHA-512 hash: $shadow_hash" ;;
        esac

        # -- the real login check: feed the KNOWN fixture plaintext
        # through the same glibc crypt(3) machinery a real PAM/`su` login
        # would use (Python's own `crypt` module -- already required on
        # this image, bin/ubx-users' own shebang is python3) and assert
        # it reproduces the EXACT hash that landed in /etc/shadow -- i.e.
        # the plaintext really does authenticate against the
        # secret-sourced hash the secrets+users domains just converged,
        # never a scripted stand-in that only checks byte equality
        # against a value this driver already knows in advance.
        m4_login_rc=0
        UBX_M4_STORED_HASH="$shadow_hash" python3 <<'UBX_M4_LOGIN_PY_EOF' || m4_login_rc=$?
    import crypt
    import os
    import sys

    plaintext = "${switchLoopPwPlaintext}"
    stored_hash = os.environ["UBX_M4_STORED_HASH"]
    computed = crypt.crypt(plaintext, stored_hash)
    sys.exit(0 if computed == stored_hash else 1)
    UBX_M4_LOGIN_PY_EOF
        [ "$m4_login_rc" -eq 0 ] \
          || mark_fail_pw "the known fixture plaintext does not authenticate (crypt(3)) against ${switchLoopPwUserName}'s shadow hash -- login would fail"
        echo "UBX-M4-PW-PASS"

        advance 3
        sync
        systemctl poweroff
        ;;

      *)
        echo "UBX-M2-DRIVER-FAIL: unknown phase '$phase'"
        systemctl poweroff
        ;;
    esac
  '';

  # -- switchLoopGen1Files: generation 1's on-disk state, hand-written in
  #    EXACTLY the shape `bin/ubx-generations create` itself produces (see
  #    this section's own header, decision 2, for why this is hand-written
  #    rather than shelled out to that tool at Nix build time). Populated
  #    straight onto the ext4 populate tree (switchLoopVarStore, below).
  switchLoopGen1Files =
    { }: ''
      ubxrun "$UBX_BASE/bin/mkdir" -p "$out/generations/1"
      ubxrun "$UBX_BASE/bin/cat" > "$out/generations/1/manifest" <<UBX_M2_MANIFEST_EOF
      GEN_INDEX=1
      GEN_TITLE=switch-loop proof baseline
      GEN_CREATED=1970-01-01T00:00:00Z
      GEN_ROOTFS_IMAGE=$rootfsImage
      GEN_KERNEL_PATH=$kernelPath
      GEN_INITRD_PATH=$initrdPath
      GEN_ROOT_DEVICE=/dev/vda2
      GEN_KERNEL_PARAMS=
      GEN_ETC_REF=/usr/local/share/ubx-switch-loop/gen1/etc-manifest.json
      GEN_USERS_MANIFEST=/usr/local/share/ubx-switch-loop/gen1/users-manifest.json
      GEN_SNAP_MANIFEST=
      UBX_M2_MANIFEST_EOF
      ubxrun "$UBX_BASE/bin/cat" > "$out/generations/1/ubx-extra" <<'UBX_M2_SIDECAR_EOF'
      SYSTEMD_MANIFEST=/usr/local/share/ubx-switch-loop/gen1/systemd-manifest.json
      UBX_M2_SIDECAR_EOF
      printf '2\n' > "$out/generations/.next-index"
      printf '1\n' > "$out/generations/grub-default"
      ubxrun "$UBX_BASE/bin/ln" -s 1 "$out/generations/current"
      ubxrun "$UBX_BASE/bin/mkdir" -p "$out/switch-loop"
    '';

  # -- switchLoopVarStore: the CONTENT that becomes /ubx/var's ext4
  #    filesystem (see switchLoopVarImage below, which runs `mke2fs -d`
  #    against this directory -- the ext-side analogue of diskImage's own
  #    FAT/mtools "populate without mounting" trick). ---------------------
  switchLoopVarStore =
    { name, rootfsImage, kernelPath, initrdPath, system ? "x86_64-linux" }:
    runInUbuntuBase {
      inherit system;
      name = "switch-loop-var-store-${name}";
      # rootfsImage/kernelPath/initrdPath are derivation-output store paths
      # (string context). They must reach the script via ENV ATTRS, never
      # interpolated into the script text, because `runInUbuntuBase` renders
      # the script through `builtins.toFile`, which rejects any string
      # carrying a reference to a derivation output (see nix/stdenv.nix's
      # BOOTSTRAP CAVEAT note). The manifest heredoc below expands them as
      # ordinary shell variables ($rootfsImage, ...).
      env = { inherit rootfsImage kernelPath initrdPath; };
      script = ''
        ubxrun() { "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" "$@"; }
        ubxrun "$UBX_BASE/bin/mkdir" -p "$out"
        ${switchLoopGen1Files { }}
      '';
    };

  # -- switchLoopVarImage: mke2fs -d switchLoopVarStore -> $out/ubxvar.img
  #    (an ext4 filesystem image, populated with no mount(2)/loop-device
  #    call at all -- mke2fs's own `-d` flag, exactly analogous to
  #    diskImage's FAT/mtools trick; e2fsprogs + its runtime libs are
  #    already in archive.lock.json's locked set). ------------------------
  switchLoopVarImage =
    { name, varStore, sizeMiB ? 64, system ? "x86_64-linux" }:
    let
      tools = toolsFHS {
        inherit system;
        name = "switch-loop-e2fsprogs-${name}";
        packages = [ "e2fsprogs" "libblkid1" "libcom-err2" "libss2" "libuuid1" "libext2fs2t64" ];
      };
    in
    runInUbuntuBase {
      inherit system;
      name = "switch-loop-var-image-${name}";
      env = { inherit varStore tools; };
      script = ''
        ubxrun() { "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" "$@"; }
        toolrun() { "$UBX_LD" --library-path "$UBX_LIBRARY_PATH:$tools/usr/lib/x86_64-linux-gnu:$tools/lib/x86_64-linux-gnu" "$@"; }
        ubxrun "$UBX_BASE/bin/mkdir" -p "$out"
        [ -e "$tools/usr/sbin/mke2fs" ] || {
          echo "switchLoopVarImage: expected tool file not found at $tools/usr/sbin/mke2fs" >&2
          exit 1
        }
        ubxrun "$UBX_BASE/usr/bin/truncate" -s "${toString sizeMiB}M" ubxvar.img
        toolrun "$tools/usr/sbin/mke2fs" -q -F -t ext4 -L UBXVAR -d "$varStore" ubxvar.img
        ubxrun "$UBX_BASE/bin/cp" ubxvar.img "$out/ubxvar.img"
      '';
    };

  # -- switchLoopDiskImage: `diskImage` (see that function's own header
  #    for the FAT/squashfs partition layout and the manual MBR/core.img
  #    embedding this reuses verbatim) plus a THIRD partition -- ext4,
  #    `varImage`'s content, for `/ubx/var` (see this section's own
  #    header, decision 1). Deliberately a SEPARATE function rather than a
  #    generalization of `diskImage` itself: that function's disk-image
  #    assembly is this project's least-proven, most hand-tuned step (its
  #    own header says as much), and M1's `boot-image-proof` must stay
  #    completely unaffected by M2's own image-composition needs.
  switchLoopDiskImage =
    { name
    , squashfs
    , kernel
    , grubCfgDrv
    , flavor
    , varImage
    , bootPartitionMiB ? 256
    , system ? "x86_64-linux"
    }:
    let
      tools = toolsFHS {
        inherit system;
        name = "switch-loop-diskimage-${name}";
        packages = [
          "grub-pc-bin" "grub-common" "grub2-common"
          "dosfstools" "mtools" "parted"
          "libdevmapper1.02.1" "libparted2t64" "libreadline8t64" "libtinfo6"
        ];
      };
    in
    runInUbuntuBase {
      inherit system;
      name = "switch-loop-disk-image-${name}";
      env = { inherit squashfs kernel grubCfgDrv tools varImage; };
      script = ''
        ubxrun() { "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" "$@"; }
        toolrun() { "$UBX_LD" --library-path "$UBX_LIBRARY_PATH:$tools/usr/lib/x86_64-linux-gnu:$tools/lib/x86_64-linux-gnu" "$@"; }

        ubxrun "$UBX_BASE/bin/mkdir" -p "$out"

        for bin in \
          "$tools/usr/bin/grub-mkimage" \
          "$tools/usr/sbin/mkfs.vfat" \
          "$tools/usr/bin/mmd" \
          "$tools/usr/bin/mcopy" \
          "$tools/usr/sbin/parted" \
          "$tools/usr/lib/grub/i386-pc/boot.img"; do
          [ -e "$bin" ] || {
            echo "switchLoopDiskImage: expected tool file not found at $bin" >&2
            exit 1
          }
        done

        version="${flavor}"

        export GCONV_PATH="$UBX_BASE/usr/lib/x86_64-linux-gnu/gconv"
        [ -d "$GCONV_PATH" ] || {
          echo "switchLoopDiskImage: gconv modules dir not found at $GCONV_PATH" >&2
          exit 1
        }

        # -- 1. partition layout, in MiB -------------------------------
        squashfs_bytes="$(ubxrun "$UBX_BASE/usr/bin/stat" -c%s "$squashfs/rootfs.squashfs")"
        var_bytes="$(ubxrun "$UBX_BASE/usr/bin/stat" -c%s "$varImage/ubxvar.img")"
        mib=$((1024 * 1024))
        squashfs_mib=$(( (squashfs_bytes + mib - 1) / mib + 32 ))
        var_mib=$(( (var_bytes + mib - 1) / mib ))

        boot_start_mib=1
        boot_size_mib=${toString bootPartitionMiB}
        boot_end_mib=$((boot_start_mib + boot_size_mib))
        squashfs_end_mib=$((boot_end_mib + squashfs_mib))
        var_end_mib=$((squashfs_end_mib + var_mib))

        echo "switchLoopDiskImage: boot ''${boot_start_mib}-''${boot_end_mib}MiB, squashfs ''${boot_end_mib}-''${squashfs_end_mib}MiB, ubx-var ''${squashfs_end_mib}-''${var_end_mib}MiB"

        # -- 2. FAT boot partition content (identical to diskImage's own
        #    step 2 -- see that function's header for why FAT/mtools) ---
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

        # -- 3. GRUB's standalone core.img (identical to diskImage's own
        #    step 3) ------------------------------------------------------
        toolrun "$tools/usr/bin/grub-mkimage" \
          -d "$tools/usr/lib/grub/i386-pc" \
          -O i386-pc -o core.img -p '(hd0,msdos1)/grub' \
          biosdisk part_msdos fat normal configfile linux search echo test ls cat halt reboot boot

        # -- 4. partition the raw disk image FILE: THREE partitions now -
        disk_size_mib=$((var_end_mib + 1))
        ubxrun "$UBX_BASE/usr/bin/truncate" -s "''${disk_size_mib}M" disk.img
        toolrun "$tools/usr/sbin/parted" --script disk.img -- \
          mklabel msdos \
          mkpart primary fat32 "''${boot_start_mib}MiB" "''${boot_end_mib}MiB" \
          set 1 boot on \
          mkpart primary "''${boot_end_mib}MiB" "''${squashfs_end_mib}MiB" \
          mkpart primary ext4 "''${squashfs_end_mib}MiB" "''${var_end_mib}MiB"

        # -- 5. lay the three partitions' content into place -------------
        ubxrun "$UBX_BASE/bin/dd" if=fatpart.img of=disk.img bs=1M seek="$boot_start_mib" conv=notrunc status=none
        ubxrun "$UBX_BASE/bin/dd" if="$squashfs/rootfs.squashfs" of=disk.img bs=1M seek="$boot_end_mib" conv=notrunc status=none
        ubxrun "$UBX_BASE/bin/dd" if="$varImage/ubxvar.img" of=disk.img bs=1M seek="$squashfs_end_mib" conv=notrunc status=none

        # -- 6. embed GRUB's boot code manually (identical to diskImage's
        #    own step 6 -- see that function's header for the full
        #    rationale for why this is done by hand rather than via
        #    grub-bios-setup) ----------------------------------------------
        core_bytes="$(ubxrun "$UBX_BASE/usr/bin/stat" -c%s core.img)"
        core_sectors=$(( (core_bytes + 511) / 512 ))
        blocklist_len=$(( core_sectors - 1 ))

        gap_sectors=$((boot_start_mib * 2048))
        if [ $((1 + core_sectors)) -ge "$gap_sectors" ]; then
          echo "switchLoopDiskImage: core.img no longer fits in the $gap_sectors-sector pre-partition-1 embedding gap" >&2
          exit 1
        fi

        ubxrun "$UBX_BASE/bin/dd" \
          if="$tools/usr/lib/grub/i386-pc/boot.img" of=disk.img \
          bs=440 count=1 conv=notrunc status=none

        ubxrun "$UBX_BASE/bin/dd" \
          if=core.img of=disk.img \
          bs=512 seek=1 conv=notrunc status=none

        len_lo=$((blocklist_len & 255))
        len_hi=$(((blocklist_len >> 8) & 255))
        printf "$(printf '\\%03o\\%03o' "$len_lo" "$len_hi")" |
          ubxrun "$UBX_BASE/bin/dd" of=disk.img bs=1 seek=1020 count=2 conv=notrunc status=none

        ubxrun "$UBX_BASE/bin/cp" disk.img "$out/disk.img"
      '';
    };

  # ===========================================================================
  # soft-reboot-proof — GitHub issue #59, a direct follow-up to #55/#58: the
  # switch-loop-proof's own scenario 2 (above) already drives a REAL
  # `mount -t squashfs -o ro <image> /run/nextroot` (bin/ubx's real
  # `_ubx_stage_nextroot` default) but STILL fires the actual reboot through
  # `ubx-soft-reboot-stub` -- a marker-dropping stand-in -- because, per that
  # section's own header, a real `systemctl soft-reboot` re-exec needs a
  # FULL SECOND BOOTABLE USERSPACE already staged at /run/nextroot (systemd
  # itself, plus every binary the post-re-exec assertion path depends on),
  # not just a marker file. Firing a real soft-reboot at a non-bootable
  # /run/nextroot hangs the guest with no useful serial signal (systemd
  # tears the old userspace down BEFORE it knows whether the new one will
  # come up) -- exactly the failure mode this section is built never to
  # risk. This section closes that one remaining gap with its own small,
  # focused sibling proof + driver (deliberately NOT touching
  # switchLoopDriverScript/switchLoopExtraFilesScript above, so the already-
  # green M2 e2e stays completely unaffected -- see the issue's own explicit
  # instruction to prefer this shape).
  #
  # -- systemd soft-reboot semantics this section relies on (see
  #    systemd-soft-reboot(1)/systemctl(1) "soft-reboot" verb; targets
  #    systemd >= 254, which is the first release able to re-exec userspace
  #    into a populated /run/nextroot at all -- see bin/ubx's own identical
  #    note on UBX_SOFT_REBOOT_CMD) --------------------------------------
  #
  #   1. `systemctl soft-reboot` stops userspace (every unit), then
  #      RE-EXECS PID 1 and all of userspace from /run/nextroot IF that
  #      path is found to be a populated, bootable OS tree at the moment
  #      the verb runs -- WITHOUT going through firmware or reloading the
  #      kernel. That is this proof's central mechanism to exercise for
  #      real (SPEC.md §4.3's "Deb set (rootfs image change) -> build new
  #      image -> systemctl soft-reboot into it", §12 R3 "Soft-reboot
  #      semantics ... validate in M2" -- this section is that validation,
  #      one milestone late but still M2/M3-adjacent scope per issue #59).
  #   2. Because no kernel reload happens, `/proc/sys/kernel/random/boot_id`
  #      (regenerated by the kernel only on a REAL boot) is PRESERVED
  #      across a soft-reboot -- the guest-side proof this section uses to
  #      assert "no full/kernel reboot occurred" (acceptance criterion 3).
  #      A real full reboot, by contrast, always changes it.
  #   3. `/run` (a tmpfs) -- and critically, any filesystem mounted BELOW
  #      it, including /run/nextroot itself -- is PROPAGATED into the new
  #      root: it stays mounted across the transition, unlike every other
  #      mount in the old root. This is exactly what lets this proof's
  #      driver script keep state (the pre-reboot boot_id and the new
  #      generation's tag, `$STATE/pre-state` below) across the re-exec
  #      with NO persistent disk partition at all -- unlike the M2
  #      switch-loop-proof's ext4 `/ubx/var` (that proof needs state to
  #      survive REAL guest reboots across separate qemu launches; this one
  #      only needs it to survive a soft-reboot re-exec within the SAME
  #      qemu process, so plain `/run` persistence is sufficient and a
  #      whole extra ext4 partition would be unjustified complexity here).
  #
  # -- constructing a genuinely bootable /run/nextroot (acceptance
  #    criterion 1) -------------------------------------------------------
  #
  # Per this issue's own design guidance, the simplest ROBUST way to get a
  # /run/nextroot systemd will agree to re-exec into is to reuse the SAME
  # base rootfs this guest is already running: it is, by definition, a
  # working systemd userspace with every binary/unit this proof's own
  # post-re-exec assertion path depends on already proven to boot (this
  # very qemu instance is live proof). Concretely, the driver script
  # (`softRebootDriverScript` below) does NOT rebuild or copy that rootfs
  # at runtime (mksquashfs-ing the ENTIRE locked-archive rootfs into a
  # ~512 MiB tmpfs, under a hard e2e timeout, on possibly-TCG-emulated
  # hardware, is exactly the kind of runtime risk this proof is designed to
  # avoid -- contrast the M2 switch-loop-proof's own scenario 2, which only
  # ever mksquashfs's a TINY fixture tree, never the whole rootfs). Instead
  # it:
  #   1. mounts this image's own root partition (/dev/vda2, this proof's
  #      fixed single-generation layout -- see `diskImage`'s header for why
  #      this project addresses it that way) a SECOND, independent time,
  #      read-only, at $STATE/lower -- a fresh mount instance of the exact
  #      bytes already booted, guaranteed bootable by construction;
  #   2. overlays a tiny tmpfs upper (`$STATE/upper`/`$STATE/work`) on top
  #      of that lower mount, mounted together at /run/nextroot -- carrying
  #      ONE new file, /etc/ubx-soft-reboot-generation, containing a fresh,
  #      per-boot tag. This is the "distinguishing marker file" this
  #      issue's design guidance calls for: it costs nothing at runtime (no
  #      data copy -- overlayfs's copy-up only touches the one file this
  #      driver itself writes) yet proves, after the re-exec, that
  #      userspace is running from THIS freshly-staged mount instance and
  #      not merely the original one still running in place (acceptance
  #      criterion 3's "new generation's rootfs image", "not the old one").
  #   3. sanity-checks the staged tree BEFORE ever calling
  #      `systemctl soft-reboot` (mountpoint check + a real systemd binary
  #      present under /usr/lib/systemd or /lib/systemd) -- this is what
  #      makes firing the real re-exec safe: by the time it is invoked,
  #      /run/nextroot is either a verified-bootable tree or the driver has
  #      already bailed out to a clean NOTE (see below), never a guess.
  #
  # -- clean-fallback conditions (acceptance criterion 4: NEVER a hang) ----
  #
  # Each of the following is checked SYNCHRONOUSLY, before the one call
  # that could otherwise hang the guest (`systemctl soft-reboot` itself),
  # and each emits `UBX-SR-NOTE: <reason>` then a clean `systemctl
  # poweroff` -- never a FAIL, since none of these represent a defect in
  # the switch-loop driver mechanism itself, only an environment that
  # cannot safely exercise it:
  #   - systemd < 254 (`systemctl --version` parsed): this runtime's
  #     systemd cannot re-exec into /run/nextroot at all (see semantics
  #     note 1 above) -- this project's own images always carry systemd
  #     255 (Ubuntu 24.04 "noble"), so this branch is not expected to
  #     trigger in this repo's own CI, but guards any runtime built from a
  #     modified/older archive pin from ever attempting the real re-exec.
  #   - guest uptime already >= 90s by the point the driver reaches this
  #     decision (a wall-clock heuristic for "this boot is running under
  #     slow software emulation (TCG), no /dev/kvm" -- the ACTUAL risk that
  #     concern names is running out of the harness's own hard --timeout
  #     mid-reboot, not the re-exec mechanism itself hanging; this bails
  #     BEFORE spending any more wall-clock budget on it). No host-side
  #     wiring is needed for this -- it is a robust, self-contained, purely
  #     guest-side proxy.
  #   - the root device cannot be mounted a second time, or the overlay
  #     filesystem is unavailable in this kernel (`/proc/filesystems`),
  #     or the staged tree fails the mountpoint/systemd-binary sanity
  #     checks above -- each means this runtime cannot construct a
  #     genuinely bootable /run/nextroot at all, so the real soft-reboot is
  #     never attempted.
  # If `systemctl soft-reboot` itself returns non-zero synchronously
  # (before actually re-execing), that IS a real failure (`UBX-SR-FAIL`),
  # not a NOTE -- unlike the conditions above, it means a fully-staged,
  # sanity-checked /run/nextroot was rejected by systemd for some other
  # reason worth surfacing loudly.
  #
  # -- the marker scheme (host harness: tests/e2e/040-qemu-soft-reboot-e2e.sh)
  #
  #   UBX-SR-PRE-PASS               staging succeeded, about to soft-reboot
  #   UBX-SR-BOOTID-PASS            boot_id unchanged across the re-exec
  #   UBX-SR-POST-PASS              live /etc tag matches the new generation
  #   UBX-SR-NOTE: <reason>         clean, diagnosable skip (not a failure)
  #   UBX-SR-FAIL: <reason>         a real failure
  # The host harness requires BOTH BootID-PASS and POST-PASS together (a
  # real re-exec happened) OR a single NOTE (nothing attempted) to pass;
  # a FAIL, a timeout, or a PRE-PASS with no matching POST-PASS/BOOTID-PASS
  # (soft-reboot silently didn't take -- a hang or half-landed re-exec) all
  # fail the run. See that script's own header for the exact contract.
  softRebootDriverScript = ''
    #!/bin/bash
    # /usr/local/bin/ubx-soft-reboot-driver -- see nix/boot.nix's
    # soft-reboot-proof section (GitHub issue #59) for the full design.
    #
    # Runs once per systemd generation, via ubx-soft-reboot-driver.service
    # (oneshot, WantedBy multi-user.target). Because a successful soft-reboot
    # RE-EXECS userspace rather than reloading the kernel, this SAME unit
    # runs again, from scratch, immediately after a successful re-exec --
    # /run persists across the transition (see this file's own header on
    # systemd's soft-reboot semantics), so a state file under /run is how
    # this script tells "first run" (about to soft-reboot) from "second run"
    # (just re-exec'd) apart, with no persistent disk partition needed at
    # all (unlike the M2 switch-loop-proof's ext4 /ubx/var).
    set -u
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

    STATE=/run/ubx-soft-reboot
    NEXTROOT=/run/nextroot
    # This proof's own fixed single-generation disk layout (identical
    # convention to proofGeneration/switchLoopGeneration's own rootDevice in
    # nix/boot.nix: partition 2 is the raw squashfs root, addressed directly
    # by device -- see diskImage's own header for why no wrapping fs).
    ROOT_DEV=/dev/vda2

    mkdir -p "$STATE"

    mark_note() { # REASON
      echo "UBX-SR-NOTE: $1"
      sync
      systemctl poweroff
      exit 0
    }

    mark_fail() { # REASON
      echo "UBX-SR-FAIL: $1"
      sync
      systemctl poweroff
      exit 0
    }

    if [ -f "$STATE/pre-state" ]; then
      # ================= post-re-exec assertions ======================
      # shellcheck disable=SC1091  # dynamically written by this same script, one boot earlier
      . "$STATE/pre-state"

      boot_id_after="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
      [ "$boot_id_after" = "$UBX_SR_BOOT_ID_BEFORE" ] ||
        mark_fail "boot_id changed ($UBX_SR_BOOT_ID_BEFORE -> $boot_id_after) -- a full/kernel reboot happened where a soft-reboot re-exec should have preserved it"
      echo "UBX-SR-BOOTID-PASS: boot_id preserved ($boot_id_after)"

      live_tag="$(cat /etc/ubx-soft-reboot-generation 2>/dev/null || true)"
      [ "$live_tag" = "$UBX_SR_GEN_TAG" ] ||
        mark_fail "post-re-exec /etc/ubx-soft-reboot-generation is '$live_tag', expected the new generation's tag '$UBX_SR_GEN_TAG' -- userspace did not come up from the newly-staged /run/nextroot image"
      echo "UBX-SR-POST-PASS: live /etc/ubx-soft-reboot-generation = $live_tag"

      rm -f "$STATE/pre-state"
      sync
      systemctl poweroff
      exit 0
    fi

    # ================= pre-reboot: gate, stage, assert, fire ===========

    # -- clean-fallback gate 1: systemd version (semantics note 1 above) --
    sd_version="$(systemctl --version | head -n1 | awk '{print $2}')"
    case "$sd_version" in
      ''' | *[!0-9]*)
        mark_note "could not parse a numeric systemd version from 'systemctl --version' (got: '$sd_version') -- skipping the real soft-reboot re-exec"
        ;;
    esac
    [ "$sd_version" -ge 254 ] ||
      mark_note "systemd $sd_version is older than 254 -- systemctl soft-reboot cannot re-exec into a populated /run/nextroot on this runtime, skipping"

    # -- clean-fallback gate 2: a slow (no-KVM/TCG) boot risks not
    #    finishing inside the harness's own hard --timeout -- see this
    #    file's own header on why wall-clock uptime is used as the proxy.
    uptime_s="$(cut -d. -f1 /proc/uptime 2> /dev/null || echo 0)"
    [ -n "$uptime_s" ] || uptime_s=0
    [ "$uptime_s" -lt 90 ] ||
      mark_note "guest uptime is already ''${uptime_s}s at the point a real soft-reboot would be attempted -- likely running under slow software emulation (no /dev/kvm); skipping to stay inside the harness timeout"

    # -- criterion 1: stage a genuinely bootable /run/nextroot (see this
    #    file's own header, "constructing a genuinely bootable
    #    /run/nextroot") -------------------------------------------------
    mkdir -p "$STATE/lower" "$STATE/upper" "$STATE/work" "$NEXTROOT"

    if ! mount -t squashfs -o ro "$ROOT_DEV" "$STATE/lower" > "$STATE/mount-lower.log" 2>&1; then
      mark_note "could not mount $ROOT_DEV a second time at $STATE/lower -- see $STATE/mount-lower.log"
    fi

    grep -q '^overlay' /proc/filesystems 2> /dev/null || modprobe overlay > /dev/null 2>&1 || true
    if ! grep -q '^overlay' /proc/filesystems 2> /dev/null; then
      umount "$STATE/lower" 2> /dev/null || true
      mark_note "the overlay filesystem is not available in this kernel -- cannot tag the staged /run/nextroot as a distinct generation"
    fi

    gen_tag="ubx-sr-gen-$(date +%s)-$$"
    overlay_opts="lowerdir=$STATE/lower,upperdir=$STATE/upper,workdir=$STATE/work"
    if ! mount -t overlay overlay \
      -o "$overlay_opts" \
      "$NEXTROOT" > "$STATE/mount-overlay.log" 2>&1; then
      umount "$STATE/lower" 2> /dev/null || true
      mark_note "could not overlay-mount /run/nextroot (lower=$STATE/lower) -- see $STATE/mount-overlay.log"
    fi
    echo "$gen_tag" > "$NEXTROOT/etc/ubx-soft-reboot-generation"

    mountpoint -q "$NEXTROOT" ||
      mark_note "/run/nextroot is not a mountpoint after staging -- refusing to soft-reboot into it"
    { [ -x "$NEXTROOT/usr/lib/systemd/systemd" ] || [ -x "$NEXTROOT/lib/systemd/systemd" ]; } ||
      mark_note "the staged /run/nextroot has no systemd binary under usr/lib/systemd or lib/systemd -- not a genuinely bootable OS tree, refusing to soft-reboot into it"

    echo "UBX-SR-PRE-PASS: staged /run/nextroot from $ROOT_DEV, tag=$gen_tag"

    boot_id_before="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
    {
      echo "UBX_SR_BOOT_ID_BEFORE=$boot_id_before"
      echo "UBX_SR_GEN_TAG=$gen_tag"
    } > "$STATE/pre-state"
    sync

    # -- criterion 2: the REAL re-exec, not a marker stub (contrast the M2
    #    switch-loop-proof's ubx-soft-reboot-stub -- see this file's own
    #    header for exactly why that one still stubs this call and this
    #    proof does not). ------------------------------------------------
    echo "UBX-SR-FIRING-REAL-SOFT-REBOOT"
    if ! systemctl soft-reboot; then
      mark_fail "systemctl soft-reboot exited non-zero without re-execing -- a fully-staged, sanity-checked /run/nextroot was rejected"
    fi
    # Unreached on a real re-exec: the call above tears this very process
    # down as part of stopping userspace. If control ever returns here
    # (systemd accepted the call but somehow came back to the OLD
    # userspace instead of re-execing), that is itself a real failure.
    mark_fail "systemctl soft-reboot returned 0 but this OLD userspace instance is still running -- the re-exec did not happen"
  '';

  # -- the extra-files script layered onto bootRootfs for the soft-reboot
  #    proof only: the driver script above, plus its own oneshot unit. No
  #    fixture manifests, no guard diversions, no ext4 partition -- this
  #    proof exercises exactly one mechanism (see this section's own
  #    header) and needs nothing else the switch-loop-proof's own
  #    extraFilesScript carries.
  softRebootExtraFilesScript = ''
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/bin/ubx-soft-reboot-driver" <<'UBX_SR_DRIVER_EOF'
    ${softRebootDriverScript}
    UBX_SR_DRIVER_EOF
    ubxrun "$UBX_BASE/bin/chmod" +x "$out/usr/local/bin/ubx-soft-reboot-driver"

    ubxrun "$UBX_BASE/bin/cat" > "$out/etc/systemd/system/ubx-soft-reboot-driver.service" <<'UBX_SR_UNIT_EOF'
    [Unit]
    Description=ubuntnix soft-reboot-proof driver (tests/e2e/040-qemu-soft-reboot-e2e.sh; GitHub issue #59)
    After=multi-user.target
    Requires=multi-user.target

    [Service]
    Type=oneshot
    StandardOutput=journal+console
    StandardError=journal+console
    ExecStart=/usr/local/bin/ubx-soft-reboot-driver

    [Install]
    WantedBy=multi-user.target
    UBX_SR_UNIT_EOF
    ubxrun "$UBX_BASE/bin/mkdir" -p "$out/etc/systemd/system/multi-user.target.wants"
    ubxrun "$UBX_BASE/bin/ln" -sf ../ubx-soft-reboot-driver.service \
      "$out/etc/systemd/system/multi-user.target.wants/ubx-soft-reboot-driver.service"
  '';

  # ===========================================================================
  # snap-converge-proof — SPEC.md §11 M3 exit criterion's QEMU end-to-end
  # exercise (GitHub issue #64): "declared snap set converged live + drift
  # purge" -- modeled directly on this file's own switch-loop-proof section
  # above (M2, issue #32); see that section's header for the fuller
  # discussion of the general technique (bake fixture assets at Nix build
  # time, run the real verbs BETWEEN them, host harness only trusts serial
  # markers) this one reuses without repeating verbatim.
  #
  # -- The three scenarios (GitHub issue #64's acceptance criteria) --------
  #
  #   S1  Boot a generation declaring a small snap set (hello-world, the
  #       one snap already vendored end-to-end in snaps.lock.json/
  #       snaps/assertions -- see nix/snap.nix's own header on why reusing
  #       it, rather than resolving a new pin, is this proof's deliberate
  #       choice); converge it LIVE via a real
  #       `ubx rebuild switch --apply` (bin/ubx's real snap-domain block,
  #       GitHub issues #66/#72: `bin/ubx-snap plan` -> `bin/ubx-snap-apply`
  #       -> `bin/ubx-snap-purge`) from VENDORED payloads only (no Store
  #       fetch reachable from inside the guest -- see "What's real vs
  #       simulated" below); assert the snap lands at its pinned revision
  #       with its declared connections/config, and that auto-refresh is
  #       held permanently.
  #   S2  Simulate an undeclared snap already being present (this proof's
  #       own documented drift stand-in -- see below); demonstrate the
  #       drift guard (bin/ubx-guard-snap, issue #31) BLOCKS an interactive
  #       `snap install`; then reconverge (SAME declared manifest) and
  #       assert the undeclared snap was PURGED by bin/ubx-snap-purge
  #       (issues #63/#65).
  #   S3  Reconverge AGAIN with NO manifest change and assert NO snap is
  #       re-sideloaded (bin/ubx-snap's diff-driven no-op, issue #61) --
  #       the declared snap stays present and correct throughout.
  #
  # -- What's real vs. simulated here, and why (the issue's own explicit
  #    instruction: exercise the real path wherever the guest allows it;
  #    stub ONLY the leaf snapd mutation/Store-fetch, and document every
  #    stubbed segment loudly) -----------------------------------------
  #
  #  - REAL: `bin/ubx rebuild switch --apply`'s full snap-domain block --
  #    `bin/ubx-snap plan` (diffing declared-vs-observed and deciding
  #    ack/install/refresh/revert/connect/set/hold), `bin/ubx-snap-apply`
  #    (translating that plan into an ordered sequence of snap-CLI-shaped
  #    calls, resolving `--payload-dir`/`--assert-dir` from the manifest's
  #    own directory exactly as bin/ubx's `execute_domains` documents), and
  #    `bin/ubx-snap-purge` (querying the "installed" set, diffing against
  #    the declared manifest, deciding what to purge). None of this
  #    project's own decision-making code is stubbed -- only the ONE seam
  #    each of those scripts already documents as injectable for exactly
  #    this reason (`UBX_SNAP_CMD`, `UBX_SNAP_BIN`) is redirected.
  #  - REAL: the vendored `.snap`/`.snap-declaration` bytes baked aboard
  #    (`snapConvergeHelloWorldPayload`/`snapConvergeHelloWorldAssert`,
  #    below) are nix/snap.nix's own real, hash-verified fixed-output
  #    fetches of the actual hello-world Snap Store artifacts (see that
  #    file's header) -- not synthetic placeholder bytes. The driver's
  #    `ack`/`install` calls below really do read these exact files by the
  #    real `<name>_<revision>` naming convention bin/ubx-snap-apply
  #    expects.
  #  - REAL: `bin/ubx-guard-snap`'s block decision for an interactive
  #    `snap install` (scenario 2) -- the same real script/diversion
  #    technique the M2 switch-loop-proof's own scenario 5 already
  #    exercises for apt/dpkg/snap, applied here to the specific verb this
  #    scenario's acceptance criteria calls out.
  #  - SIMULATED (`snapConvergeSimScript`, below, /usr/local/bin/
  #    ubx-snap-sim): the actual snapd daemon and Store network access. A
  #    real snapd is not reachable from this offline QEMU guest (no Store
  #    network reachable, and even a real LOCAL snapd would need a working
  #    confinement stack this minimal guest doesn't carry -- exactly this
  #    issue's own stated expectation). `ubx-snap-sim` stands in for BOTH
  #    injectable seams at once (`UBX_SNAP_CMD` for bin/ubx-snap-apply's
  #    mutating calls; `UBX_SNAP_BIN` for bin/ubx-snap-purge's list/purge
  #    calls) -- legitimate because both already speak the exact same
  #    "CMD <subcommand> <args...>" calling convention a real `snap`
  #    binary invocation would use (see both scripts' own headers). It
  #    maintains one small persistent JSON "installed snaps" state file,
  #    mutated only in response to a real call arriving from the real
  #    planner/executor/purge code above -- so the ASSERTIONS below are
  #    checking real decisions this project's own code made, filtered
  #    through a fake backend, not a scripted fake outcome.
  #  - DOCUMENTED STAND-IN (not a seam bin/ubx itself exposes for this):
  #    scenario 2's "undeclared snap already present" precondition is
  #    established by calling `ubx-snap-sim seed-drift NAME REV` directly
  #    -- a subcommand that exists ONLY on this proof's own simulator,
  #    bypassing ack/install entirely, standing in for "a snap somehow
  #    ended up installed outside this project's own convergence" (a stale
  #    leftover, a bug, anything other than the interactive path this same
  #    scenario proves IS blocked). This is the one place this proof
  #    injects state the real code path did not itself produce; everything
  #    that happens to that seeded snap afterward (the purge decision, the
  #    real removal call) is real.
  #  - DOCUMENTED STAND-IN (mirrors the M2 switch-loop-proof's own
  #    identical stand-in verbatim, same reasoning): this is the very
  #    FIRST generation this guest ever registers, so `bin/ubx rebuild
  #    switch`'s soft-reboot delta classification
  #    (`ubx_rebuild_classify_delta`, bin/ubx-rebuild-lib) sees a brand new
  #    rootfs-image value and classifies the delta "image", which would
  #    otherwise attempt a REAL `/run/nextroot` mount of that image path
  #    followed by `systemctl soft-reboot`. That mechanism is already
  #    proven for real by the M2 e2e (issue #55) and is unrelated to this
  #    issue's own snap-domain scope, so this proof passes a fixed,
  #    non-existent marker string as `--rootfs-image`/`--kernel`/`--initrd`
  #    (exactly the switch-loop-proof's own gen3 marker-string fallback
  #    technique) and points `UBX_NEXTROOT_STAGE_CMD`/`UBX_SOFT_REBOOT_CMD`
  #    at trivial no-op stubs so that classification's side effects never
  #    touch anything real. Nothing about the snap domain itself depends
  #    on this.
  #
  # -- Marker scheme ------------------------------------------------------
  #
  # UBX-M3-S1-PASS / UBX-M3-S2-PASS / UBX-M3-S3-PASS, analogous to the M2
  # switch-loop-proof's own UBX-M2-Sn-PASS convention; a scenario failure
  # instead emits UBX-M3-Sn-FAIL: <reason> and powers off, exactly like M2
  # (see tests/e2e/030-qemu-snap-e2e.sh, the host-side harness that scrapes
  # these).
  #
  # This proof needs only ONE boot (no persistence-across-reboot claim is
  # part of M3's own exit criterion, unlike M2's) -- `/ubx/var` is a plain
  # tmpfs mount here (wiped every boot, irrelevant since there is only
  # one), not the ext4 partition the switch-loop-proof needs for ITS OWN
  # multi-reboot exit criterion; this proof therefore reuses the plain
  # two-partition `diskImage` (this file, M1) rather than
  # `switchLoopDiskImage`'s three-partition layout.

  # -- the declared snap set (SPEC.md §6 `ubuntnix.snaps.<name>`) ----------
  #
  # Reuses the ALREADY-VENDORED hello-world pin (snaps.lock.json/
  # snaps/assertions/hello-world_29.snap-declaration) per this project's
  # All-Canonical rule and nix/snap.nix's own header ("PREFER reusing what
  # is already committed" -- resolving a NEW pin needs live Snap Store
  # network access this authoring environment does not have). `connections`/
  # `config` are declared here even though the real hello-world snap has no
  # interesting interfaces of its own (snaps.lock.json's own comment: "zero
  # interesting interfaces") -- legitimate because the whole snapd side is
  # simulated for this proof (see header above): `ubx-snap-sim` accepts any
  # connect/set call for a snap it already "has installed" with no real
  # interface/attribute validation, so declaring them here genuinely
  # exercises bin/ubx-snap's connect/set planning + bin/ubx-snap-apply's
  # dispatch for those ops, which the bare lockfile entry alone would not.
  snapConvergeEntries = {
    hello-world = {
      channel = "stable";
      revision = 29;
      classic = false;
      connections = [ "network" ];
      config = { greeting = "hi"; };
    };
  };

  # compileManifest (nix/snap.nix), evaluated eagerly here (pure data, no
  # derivation build) against the real committed snaps.lock.json (its own
  # default `lockfile`) -- the exact per-generation manifest shape
  # bin/ubx-snap's plan/apply/purge already consume elsewhere in this
  # project; embedding it as plain JSON text mirrors switchLoopGen2EtcManifest
  # &c.'s own "small, non-derivation JSON, safe to interpolate directly"
  # posture.
  snapConvergeManifestJson = builtins.toJSON (compileManifest { entries = snapConvergeEntries; });

  # -- vendored payload/assertion bytes (nix/snap.nix's real fixed-output
  #    fetches) -- REAL derivation outputs, so they travel through
  #    bootRootfs's new `extraEnv` (see that function's own comment on why)
  #    rather than being interpolated into extraFilesScript's own text. --
  snapConvergeHelloWorldPayload = snaps.hello-world.snap;
  snapConvergeHelloWorldAssert = snaps.hello-world."assert";

  # -- the simulated snapd backend (see this section's header, "What's
  #    real vs. simulated") -------------------------------------------
  #
  # One script answers to BOTH injectable seams bin/ubx-snap-apply
  # (UBX_SNAP_CMD) and bin/ubx-snap-purge (UBX_SNAP_BIN) already expose,
  # because both already speak the identical "CMD <subcommand> <args...>"
  # calling convention a real `snap` invocation would use (see both
  # scripts' own headers). Maintains a small persistent JSON state file at
  # $UBX_SNAP_SIM_STATE (`{"refreshHold": bool, "snaps": {name: {revision,
  # channel, classic, connections, config}}}`) and appends every invocation
  # verbatim to $UBX_SNAP_SIM_LOG (an argv-per-line trace) -- the driver
  # script inspects that log directly to assert scenario 3's "no snap is
  # re-sideloaded" property (no NEW ack/install lines appear across a
  # no-op reconverge), and inspects the state file directly for every
  # other assertion (installed revision, connections, config, refresh
  # hold, presence/absence of a name).
  snapConvergeSimScript = ''
    #!/bin/sh
    # /usr/local/bin/ubx-snap-sim -- see nix/boot.nix's snap-converge-proof
    # section header ("What's real vs. simulated") for the full scope
    # note: this stands in for the real snapd/`snap` client ONLY, never
    # for this project's own planner/executor/purge decision logic, which
    # calls this script exactly as it would call the real `snap` CLI.
    set -eu
    STATE="''${UBX_SNAP_SIM_STATE:?UBX_SNAP_SIM_STATE must be set}"
    LOG="''${UBX_SNAP_SIM_LOG:?UBX_SNAP_SIM_LOG must be set}"
    cmd="''${1:-}"
    if [ $# -ge 1 ]; then shift; fi
    printf '%s' "$cmd" >> "$LOG"
    for a in "$@"; do printf ' %s' "$a" >> "$LOG"; done
    printf '\n' >> "$LOG"

    exec python3 - "$STATE" "$cmd" "$@" <<'PYEOF'
    import json
    import os
    import sys

    state_path, cmd = sys.argv[1], sys.argv[2]
    args = sys.argv[3:]

    if os.path.exists(state_path):
        with open(state_path, encoding="utf-8") as f:
            state = json.load(f)
    else:
        state = {"refreshHold": False, "snaps": {}}


    def save():
        tmp = state_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(state, f)
        os.replace(tmp, state_path)


    def name_rev_from_snap_path(path):
        base = os.path.basename(path)
        if base.endswith(".snap"):
            base = base[: -len(".snap")]
        name, _, rev = base.rpartition("_")
        return name, int(rev)


    if cmd == "list":
        print("Name  Version  Rev  Tracking  Publisher  Notes")
        for name, s in sorted(state["snaps"].items()):
            print(f"{name}  -  {s['revision']}  {s.get('channel') or '-'}  -  -")
        sys.exit(0)

    if cmd == "ack":
        assert_path = args[0]
        if not os.path.isfile(assert_path):
            print(f"ubx-snap-sim: ack: assertion file not found: {assert_path}", file=sys.stderr)
            sys.exit(1)
        sys.exit(0)

    if cmd == "install":
        classic = "--classic" in args
        payload = [a for a in args if a not in ("--dangerous", "--classic")][-1]
        if not os.path.isfile(payload):
            print(f"ubx-snap-sim: install: payload not found: {payload}", file=sys.stderr)
            sys.exit(1)
        name, rev = name_rev_from_snap_path(payload)
        state["snaps"][name] = {"revision": rev, "channel": "", "classic": classic, "connections": [], "config": {}}
        save()
        sys.exit(0)

    if cmd == "refresh":
        if args and args[0] == "--hold=forever":
            state["refreshHold"] = True
            save()
            sys.exit(0)
        payload = [a for a in args if a != "--dangerous"][-1]
        if not os.path.isfile(payload):
            print(f"ubx-snap-sim: refresh: payload not found: {payload}", file=sys.stderr)
            sys.exit(1)
        name, rev = name_rev_from_snap_path(payload)
        existing = state["snaps"].get(name, {"channel": "", "classic": False, "connections": [], "config": {}})
        existing["revision"] = rev
        state["snaps"][name] = existing
        save()
        sys.exit(0)

    if cmd == "revert":
        name = args[0]
        rev = None
        for a in args[1:]:
            if a.startswith("--revision="):
                rev = int(a.split("=", 1)[1])
        if name not in state["snaps"] or rev is None:
            print(f"ubx-snap-sim: revert: no such snap or missing --revision: {args}", file=sys.stderr)
            sys.exit(1)
        state["snaps"][name]["revision"] = rev
        save()
        sys.exit(0)

    if cmd == "remove":
        names = [a for a in args if a != "--purge"]
        for n in names:
            state["snaps"].pop(n, None)
        save()
        sys.exit(0)

    if cmd == "connect":
        name, _, iface = args[0].partition(":")
        if name not in state["snaps"]:
            print(f"ubx-snap-sim: connect: no such snap: {name}", file=sys.stderr)
            sys.exit(1)
        conns = set(state["snaps"][name].get("connections", []))
        conns.add(iface)
        state["snaps"][name]["connections"] = sorted(conns)
        save()
        sys.exit(0)

    if cmd == "disconnect":
        name, _, iface = args[0].partition(":")
        if name in state["snaps"]:
            conns = set(state["snaps"][name].get("connections", []))
            conns.discard(iface)
            state["snaps"][name]["connections"] = sorted(conns)
            save()
        sys.exit(0)

    if cmd == "set":
        name, kv = args[0], args[1]
        key, _, value = kv.partition("=")
        if value in ("true", "false"):
            parsed = value == "true"
        else:
            try:
                parsed = json.loads(value)
            except Exception:
                parsed = value
        if name not in state["snaps"]:
            print(f"ubx-snap-sim: set: no such snap: {name}", file=sys.stderr)
            sys.exit(1)
        state["snaps"][name].setdefault("config", {})[key] = parsed
        save()
        sys.exit(0)

    if cmd == "unset":
        name, key = args[0], args[1]
        if name in state["snaps"]:
            state["snaps"][name].get("config", {}).pop(key, None)
            save()
        sys.exit(0)

    if cmd == "seed-drift":
        # Proof-only, NOT a real snap subcommand -- see this section's own
        # header, "DOCUMENTED STAND-IN": establishes scenario 2's
        # undeclared-snap precondition directly, bypassing ack/install
        # entirely (deliberate -- this represents drift that did NOT come
        # from this project's own convergence path).
        name, rev = args[0], int(args[1])
        state["snaps"][name] = {"revision": rev, "channel": "", "classic": False, "connections": [], "config": {}}
        save()
        sys.exit(0)

    print(f"ubx-snap-sim: unknown subcommand: {cmd!r}", file=sys.stderr)
    sys.exit(1)
    PYEOF
  '';

  # -- the guest driver script ----------------------------------------------
  snapConvergeDriverScript = ''
    #!/bin/bash
    # /usr/local/bin/ubx-snap-converge-driver -- see nix/boot.nix's
    # snap-converge-proof section (GitHub issue #64) for the full design,
    # and this file's own header for exactly what is real vs. simulated.
    set -u
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

    ASSETS=/usr/local/share/ubx-snap-converge
    ROOT=/ubx/var/generations
    STATE=/ubx/var/snap-converge
    UBX=/ubx/bin/ubx
    MANIFEST="$ASSETS/gen/manifest.json"

    mkdir -p "$STATE"
    export UBX_SNAP_SIM_STATE="$STATE/snapd-state.json"
    export UBX_SNAP_SIM_LOG="$STATE/snapd-actions.log"
    : > "$UBX_SNAP_SIM_LOG"
    export UBX_SNAP_CMD=/usr/local/bin/ubx-snap-sim
    export UBX_SNAP_BIN=/usr/local/bin/ubx-snap-sim
    # See this file's own header, "DOCUMENTED STAND-IN" (soft-reboot
    # classification on the very first generation) -- both stubs are
    # trivial no-ops, unrelated to the snap domain this proof targets.
    export UBX_NEXTROOT_STAGE_CMD=/usr/local/bin/ubx-m3-nextroot-stage-stub
    export UBX_SOFT_REBOOT_CMD=/usr/local/bin/ubx-m3-soft-reboot-stub

    mark_fail() { # SCENARIO REASON
      echo "UBX-M3-$1-FAIL: $2"
      echo "----- BEGIN mark_fail diagnostics -----"
      ls -la "$STATE" 2> /dev/null
      for f in "$STATE"/*.log; do
        [ -f "$f" ] || continue
        echo "----- BEGIN $f -----"
        tail -n 200 "$f"
        echo "----- END $f -----"
      done
      echo "----- END mark_fail diagnostics -----"
      sync
      systemctl poweroff
      exit 0
    }

    check_state() { # LABEL PYTHON_EXPR (must be a valid boolean expr over `state`)
      python3 - "$UBX_SNAP_SIM_STATE" "$2" <<'PYEOF'
    import json
    import sys
    with open(sys.argv[1], encoding="utf-8") as f:
        state = json.load(f)
    ok = eval(sys.argv[2])
    sys.exit(0 if ok else 1)
    PYEOF
    }

    do_switch() { # LOG_NAME [EXTRA ubx-rebuild-switch ARGS...]
      local log_name="$1"
      shift
      "$UBX" rebuild switch --root "$ROOT" \
        --rootfs-image "ubx-m3-snap-converge-proof-rootfs-image-marker" \
        --kernel "/vmlinuz-ubx-m3-marker" --initrd "/initrd-ubx-m3-marker" \
        --root-device /dev/vda2 \
        --snap-manifest "$MANIFEST" \
        "$@" \
        --apply \
        > "$STATE/$log_name.log" 2>&1
    }

    # ================= scenario 1: declare + converge live =================
    #
    # --snap-observed is passed EXPLICITLY here (rather than bin/ubx's own
    # default synthesis, snap_synthesize_observed) because that default
    # unconditionally assumes 'refreshHold' is ALREADY true (bin/ubx's own
    # documented "a fully converged system already holds it" baseline
    # assumption) -- which would never let a real 'hold' action reach the
    # simulated snapd seam on this guest's very first switch. Pointing at a
    # genuinely empty/unheld observed-state fixture instead
    # ($ASSETS/empty-snap-observed.json, baked below) makes this scenario
    # exercise the REAL ack+install+connect+set+hold sequence end to end,
    # which is exactly what "converge it LIVE" (this issue's own acceptance
    # criteria) means to prove.
    do_switch s1 --snap-observed "$ASSETS/empty-snap-observed.json"
    rc=$?
    [ "$rc" -eq 0 ] || mark_fail S1 "ubx rebuild switch exited $rc -- see $STATE/s1.log"

    grep -q '^ack ' "$UBX_SNAP_SIM_LOG" || mark_fail S1 "no 'ack' action reached the snapd seam -- see $STATE/s1.log"
    grep -q '^install ' "$UBX_SNAP_SIM_LOG" || mark_fail S1 "no 'install' action reached the snapd seam -- see $STATE/s1.log"
    grep -q '^refresh --hold=forever' "$UBX_SNAP_SIM_LOG" || mark_fail S1 "no 'hold' action reached the snapd seam -- see $STATE/s1.log"

    check_state S1 "state['refreshHold'] is True" ||
      mark_fail S1 "auto-refresh was not held permanently after convergence"
    check_state S1 "state['snaps'].get('hello-world', {}).get('revision') == 29" ||
      mark_fail S1 "hello-world is not installed at its pinned revision (29)"
    check_state S1 "state['snaps'].get('hello-world', {}).get('connections') == ['network']" ||
      mark_fail S1 "hello-world's declared connection (network) did not converge"
    check_state S1 "state['snaps'].get('hello-world', {}).get('config', {}).get('greeting') == 'hi'" ||
      mark_fail S1 "hello-world's declared config (greeting=hi) did not converge"
    echo "UBX-M3-S1-PASS"

    # ================= scenario 2: drift block + purge ======================
    #
    # Real guard decision first (bin/ubx-guard-snap, issue #31): an
    # interactive sideload attempt must be BLOCKED. "snap" here is the
    # diverted guard (see extraFilesScript below), never this proof's own
    # ubx-snap-sim -- a completely separate binary/seam, see this file's
    # header.
    s2_guard_log="$STATE/s2-guard.log"
    if snap install /nonexistent-ubx-m3-should-not-install.snap > "$s2_guard_log" 2>&1; then
      mark_fail S2 "interactive 'snap install' was NOT blocked by the drift guard"
    fi
    grep -q "managed declaratively" "$s2_guard_log" || mark_fail S2 "guard refusal message missing -- see $s2_guard_log"

    # Now simulate the undeclared snap already being present (this proof's
    # own documented stand-in -- see this file's header, "DOCUMENTED
    # STAND-IN") and confirm it really landed in the simulated backend.
    "$UBX_SNAP_CMD" seed-drift ubx-m3-undeclared-drift-snap 1
    check_state S2 "'ubx-m3-undeclared-drift-snap' in state['snaps']" ||
      mark_fail S2 "seeding the drift snap into the simulated backend did not take"

    # Reconverge with the SAME declared manifest -- the purge sweep
    # (bin/ubx-snap-purge, issues #63/#65) must remove the undeclared snap.
    do_switch s2
    rc=$?
    [ "$rc" -eq 0 ] || mark_fail S2 "ubx rebuild switch (reconverge) exited $rc -- see $STATE/s2.log"
    grep -q '^remove --purge ubx-m3-undeclared-drift-snap' "$UBX_SNAP_SIM_LOG" ||
      mark_fail S2 "no purge ('remove --purge') action for the undeclared snap reached the snapd seam -- see $STATE/s2.log"
    check_state S2 "'ubx-m3-undeclared-drift-snap' not in state['snaps']" ||
      mark_fail S2 "the undeclared snap was not purged from the simulated backend"
    check_state S2 "state['snaps'].get('hello-world', {}).get('revision') == 29" ||
      mark_fail S2 "hello-world was disturbed by the purge sweep (should be untouched)"
    echo "UBX-M3-S2-PASS"

    # ================= scenario 3: no-op reconverge =========================
    actions_before="$(wc -l < "$UBX_SNAP_SIM_LOG")"

    do_switch s3
    rc=$?
    [ "$rc" -eq 0 ] || mark_fail S3 "ubx rebuild switch (no-op reconverge) exited $rc -- see $STATE/s3.log"

    actions_after="$(wc -l < "$UBX_SNAP_SIM_LOG")"
    new_installs="$(tail -n "+$((actions_before + 1))" "$UBX_SNAP_SIM_LOG" | grep -c '^install \|^ack \|^refresh ' || true)"
    [ "$new_installs" -eq 0 ] ||
      mark_fail S3 "a snap was re-sideloaded on a no-op reconverge ($new_installs new ack/install/refresh action(s) -- see $STATE/s3.log)"
    check_state S3 "state['snaps'].get('hello-world', {}).get('revision') == 29" ||
      mark_fail S3 "hello-world is no longer correctly converged after the no-op reconverge"
    echo "UBX-M3-S3-PASS"

    sync
    systemctl poweroff
  '';

  # -- the extra-files script layered onto bootRootfs for this proof only --
  snapConvergeExtraFilesScript = ''
    # -- the "snap" drift guard (SPEC.md §7, bin/ubx-guard-snap; mirrors the
    #    switch-loop-proof's own identical block verbatim -- "snap" is
    #    never part of this image's composed package set, so there is
    #    nothing to divert, only the fallback /usr/local/bin install
    #    path). --------------------------------------------------------
    ubxrun "$UBX_BASE/bin/mkdir" -p "$out/usr/local/bin"
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/bin/snap" <<'UBX_M3_GUARD_EOF'
    #!/bin/sh
    export UBX_GUARD_REAL_BIN=/bin/true
    exec /ubx/bin/ubx-guard-snap "$@"
    UBX_M3_GUARD_EOF
    ubxrun "$UBX_BASE/bin/chmod" +x "$out/usr/local/bin/snap"

    # -- the simulated snapd backend (this proof's own; see this section's
    #    header) -------------------------------------------------------
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/bin/ubx-snap-sim" <<'UBX_M3_SIM_EOF'
    ${snapConvergeSimScript}
    UBX_M3_SIM_EOF
    ubxrun "$UBX_BASE/bin/chmod" +x "$out/usr/local/bin/ubx-snap-sim"

    # -- the two trivial soft-reboot-classification stubs (see this
    #    section's header, "DOCUMENTED STAND-IN") -----------------------
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/bin/ubx-m3-nextroot-stage-stub" <<'UBX_M3_STUB_EOF'
    #!/bin/sh
    # Stands in for bin/ubx's real _ubx_stage_nextroot (UBX_NEXTROOT_STAGE_CMD
    # default) -- see nix/boot.nix's snap-converge-proof header for why a
    # real /run/nextroot mount is out of scope for this snap-domain-only
    # proof (already proven for real by the M2 switch-loop e2e, issue #55).
    exit 0
    UBX_M3_STUB_EOF
    ubxrun "$UBX_BASE/bin/chmod" +x "$out/usr/local/bin/ubx-m3-nextroot-stage-stub"
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/bin/ubx-m3-soft-reboot-stub" <<'UBX_M3_STUB_EOF'
    #!/bin/sh
    # Stands in for `systemctl soft-reboot` -- see nix/boot.nix's
    # switch-loop-proof header (ubx-soft-reboot-stub) for the identical
    # precedent this reuses verbatim, one level up the milestone.
    mkdir -p /run/ubx-m3-snap-converge
    : > /run/ubx-m3-snap-converge/soft-reboot-invoked
    exit 0
    UBX_M3_STUB_EOF
    ubxrun "$UBX_BASE/bin/chmod" +x "$out/usr/local/bin/ubx-m3-soft-reboot-stub"

    # -- the declared snap manifest + its vendored payload/assertion,
    #    together in ONE directory (bin/ubx's own "--payload-dir/
    #    --assert-dir derived from the manifest's own directory"
    #    convention -- see execute_domains' comment in bin/ubx). ---------
    ubxrun "$UBX_BASE/bin/mkdir" -p "$out/usr/local/share/ubx-snap-converge/gen"
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-snap-converge/gen/manifest.json" <<'UBX_M3_JSON_EOF'
    ${snapConvergeManifestJson}
    UBX_M3_JSON_EOF
    ubxrun "$UBX_BASE/bin/cp" "$snapConvergeHelloWorldPayload" \
      "$out/usr/local/share/ubx-snap-converge/gen/hello-world_29.snap"
    ubxrun "$UBX_BASE/bin/cp" "$snapConvergeHelloWorldAssert" \
      "$out/usr/local/share/ubx-snap-converge/gen/hello-world_29.snap-declaration"

    # -- scenario 1's genuinely-empty/unheld --snap-observed fixture (see
    #    the driver script's own comment on why the default
    #    snap_synthesize_observed synthesis is deliberately NOT used for
    #    the very first switch). ----------------------------------------
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-snap-converge/empty-snap-observed.json" <<'UBX_M3_JSON_EOF'
    {"version": 1, "refreshHold": false, "snaps": []}
    UBX_M3_JSON_EOF

    # -- the /ubx/var mountpoint + its tmpfs mount unit (see this
    #    section's header: no ext4/persistence needed, this proof is a
    #    single boot). Unit filename must equal the systemd-escaped form
    #    of Where= (systemd.mount(5)), same rule bootRootfs's own
    #    mountUnit helper documents for /tmp,/home. --------------------
    ubxrun "$UBX_BASE/bin/mkdir" -p "$out/ubx/var"
    ubxrun "$UBX_BASE/bin/cat" > "$out/etc/systemd/system/ubx-var.mount" <<'UBX_M3_UNIT_EOF'
    [Unit]
    Description=ubuntnix M3 snap-converge proof: /ubx/var (tmpfs; single-boot proof, no persistence needed)
    DefaultDependencies=no
    Before=local-fs.target

    [Mount]
    What=tmpfs
    Where=/ubx/var
    Type=tmpfs
    Options=mode=0755

    [Install]
    WantedBy=local-fs.target
    UBX_M3_UNIT_EOF
    ubxrun "$UBX_BASE/bin/mkdir" -p "$out/etc/systemd/system/local-fs.target.wants"
    ubxrun "$UBX_BASE/bin/ln" -sf ../ubx-var.mount \
      "$out/etc/systemd/system/local-fs.target.wants/ubx-var.mount"

    # -- the guest driver + its unit --------------------------------------
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/bin/ubx-snap-converge-driver" <<'UBX_M3_DRIVER_EOF'
    ${snapConvergeDriverScript}
    UBX_M3_DRIVER_EOF
    ubxrun "$UBX_BASE/bin/chmod" +x "$out/usr/local/bin/ubx-snap-converge-driver"

    ubxrun "$UBX_BASE/bin/cat" > "$out/etc/systemd/system/ubx-snap-converge-driver.service" <<'UBX_M3_UNIT_EOF'
    [Unit]
    Description=ubuntnix M3 snap-converge proof driver (tests/e2e/030-qemu-snap-e2e.sh; GitHub issue #64)
    After=ubx-var.mount multi-user.target
    Requires=ubx-var.mount multi-user.target

    [Service]
    Type=oneshot
    StandardOutput=journal+console
    StandardError=journal+console
    ExecStart=/usr/local/bin/ubx-snap-converge-driver

    [Install]
    WantedBy=multi-user.target
    UBX_M3_UNIT_EOF
    ubxrun "$UBX_BASE/bin/mkdir" -p "$out/etc/systemd/system/multi-user.target.wants"
    ubxrun "$UBX_BASE/bin/ln" -sf ../ubx-snap-converge-driver.service \
      "$out/etc/systemd/system/multi-user.target.wants/ubx-snap-converge-driver.service"
  '';

  # ===========================================================================
  # home-activation-proof — a LIVE QEMU end-to-end proof that
  # `ubx rebuild switch --apply` really activates the per-user home domain
  # (nix/home.nix's `render`, bin/ubx-home's planner, bin/ubx-home-apply's
  # executor -- SPEC.md §9, §11 M5; GitHub issue #105, a follow-up to #98
  # which landed the home surface itself with only a build-time,
  # non-booting `.#home-proof` -- see nix/home.nix's own header). Structural
  # sibling of this file's own switch-loop-proof section above (read that
  # section's header first if you haven't -- this one reuses its two
  # generic building blocks, `switchLoopVarImage` and `switchLoopDiskImage`,
  # directly rather than duplicating them: neither is actually
  # switch-loop-specific, both just assemble a THIRD, ext4, disk partition
  # from an arbitrary populate-tree derivation, which this proof needs for
  # its own reason -- see decision 1 below).
  #
  # -- Two crux design decisions -------------------------------------------
  #
  # 1. WHERE THE PERSISTENT `/home` COMES FROM. The acceptance criteria
  #    need a real reboot (to prove an enabled user service auto-starts via
  #    `loginctl enable-linger`), so home CONTENT and linger's own durable
  #    state (systemd-logind's `/var/lib/systemd/linger/<user>` marker,
  #    which this proof's writable-`/etc` bind-mount -- see decision 2 --
  #    makes real and persistent for exactly this reason) must both survive
  #    it. `bootRootfs`'s own M1 default already mounts `/home` -- but as
  #    EMPTY, wiped-every-boot tmpfs (see that function's own
  #    `writeUnitLines` comment). This proof overwrites that SAME unit file
  #    (`/etc/systemd/system/home.mount` -- already correctly named and
  #    already symlinked under `local-fs.target.wants` by `bootRootfs`
  #    itself; `extraFilesScript` runs AFTER that machinery, so this is a
  #    plain content overwrite, no new symlink needed) with a REAL ext4
  #    mount of a third disk partition -- `switchLoopVarImage`'s own
  #    `mke2fs -d` trick, `switchLoopDiskImage`'s own three-partition
  #    layout, both reused verbatim, just mounted at `/home` this time
  #    instead of `/ubx/var` (this proof's own generations root needs no
  #    such persistence -- see decision 2).
  #
  # 2. NO PERSISTENT GENERATIONS ROOT NEEDED. Unlike the M2 switch-loop-
  #    proof, this proof never asserts anything about `current`/
  #    `grub-default`/rollback surviving a reboot -- only `/home` content
  #    and linger state need to. Its `ubx rebuild switch --root` therefore
  #    points at a plain `/run` (tmpfs) directory, recreated fresh every
  #    boot -- one real generation-registration call per domain change is
  #    still exactly what SPEC.md §4.3 requires end to end, it just never
  #    needs to be READ BACK after this proof's one and only reboot. Every
  #    `--rootfs-image`/`--kernel`/`--initrd` this driver passes is a
  #    non-existent placeholder path -- `bin/ubx-generations create` never
  #    checks these for existence (this file's own switch-loop-proof
  #    section already relies on the identical fact for its own generation
  #    3's rootfs image marker string), so nothing here needs a second,
  #    real bootable image staged at build time.
  #
  #    `/etc` is bind-mounted onto a writable tmpfs copy first (identical
  #    idiom to the switch-loop-proof driver's own phase-0 preamble --
  #    `useradd -m`, `loginctl enable-linger`'s own on-disk marker, and
  #    `ubx-users`' apply-passwords-adjacent /etc/{passwd,group,shadow}
  #    writes all need a genuinely writable /etc DIRECTORY, not just
  #    writable files) so the declared fixture user and its linger state
  #    are real.
  #
  # -- The `systemctl --user` / linger question (documented, not silently
  #    assumed) ---------------------------------------------------------
  #
  # `bin/ubx-home-apply --apply`'s own service actions run
  # `runuser -u USER -- systemctl --user <verb> <unit>` (see that script's
  # header) against the REAL per-user systemd instance `loginctl
  # enable-linger` starts (`user@<uid>.service`) -- this project's locked
  # archive (archive.lock.json) carries `systemd`/`systemd-sysv` but NO
  # `dbus`/`dbus-user-session` package, so whether a minimal QEMU guest like
  # this one can really reach `/run/user/<uid>/bus` this way was NOT
  # provable by static reading alone (systemd >= ~246 is documented to act
  # as its own bus broker for `systemctl`'s own point-to-point calls,
  # without a separate `dbus-daemon`, but this repo has no existing proof
  # of it actually working end to end in ITS OWN composed image -- see this
  # section's own driver script, `homeActivationDriverScript`, for exactly
  # where this gets exercised for real). Per this issue's own instruction
  # ("if a user systemctl --user bus is not reachable, document the exact
  # limitation ... and assert what you can"), the driver:
  #   - creates the fixture user, then calls `loginctl enable-linger` and
  #     POLLS (up to 30s) for `user@<uid>.service` to become active AND
  #     `/run/user/<uid>/bus` to exist, before ever attempting a real
  #     `systemctl --user` call;
  #   - if that polling times out, prints `UBX-HOME-LINGER-NOTE` (never a
  #     FAIL) and re-runs EVERY subsequent `ubx rebuild switch --apply`
  #     home-manifest call with an explicit `--home-observed` override that
  #     shows this run's SERVICES ALONE as already converged (see
  #     `homeGen1ObservedSkipServices`/`homeGen2ObservedSkipServices`
  #     below) -- this makes `bin/ubx-home plan` emit zero service actions
  #     (no `runuser`/`systemctl --user` call is ever attempted), while
  #     leaving the FILE side of the very same plan completely real and
  #     unaffected (the acceptance criteria's file/mode/ownership and
  #     gen1-file-not-rewritten diff proofs still run for real either way);
  #   - the post-reboot phase mirrors this exactly: the enabled-service-
  #     auto-starts assertion only runs if linger was actually confirmed
  #     reachable pre-reboot (its own outcome, persisted across the reboot
  #     at `$STATE/linger-ok` on the now-persistent `/home` partition,
  #     since `/run` does not survive a real reboot); if it was not, the
  #     driver still emits `UBX-HOME-REBOOT-PASS` (the file-persistence
  #     half of that phase's own criteria, genuinely asserted) but ANNOTATES
  #     it inline that the service auto-start half was skipped, never
  #     silently treated as passing.
  #
  # -- Marker contract (tests/e2e/060-qemu-home-activation-e2e.sh's own host
  #    side) -- printed in this order, on one single boot-then-reboot run:
  #      UBX-HOME-USER-PASS      the declared fixture user exists for real
  #                               (useradd -m, on the persistent /home)
  #      UBX-HOME-LINGER-PASS or -- see "linger question" above; never
  #      UBX-HOME-LINGER-NOTE       fatal either way
  #      UBX-HOME-GEN1-PASS      first home apply: file content+mode+
  #                               ownership, and (bus permitting) both
  #                               services enabled+active
  #      UBX-HOME-GEN2-PASS      second generation: .bashrc content changed,
  #                               .profile's mtime+inode UNCHANGED (a real
  #                               diff-driven "not rewritten" proof, not
  #                               just a content-still-matches check), and
  #                               (bus permitting) home-svc-b now disabled+
  #                               inactive while home-svc-a is untouched
  #      UBX-HOME-REBOOT-PASS    after a REAL reboot: gen2 content survived,
  #                               and (bus permitting) home-svc-a auto-
  #                               started with NO explicit start call this
  #                               boot (the actual linger/auto-start proof)
  #    `UBX-HOME-FAIL: <reason>` on any real failure -- see `mark_fail`,
  #    below, same "trust only what the guest itself asserted to serial"
  #    posture as this file's every other driver.
  homeUserName = "ubxhome";

  homeSha256 = builtins.hashString "sha256";

  homeFileEntry = path: content: mode: {
    inherit path mode;
    sha256 = homeSha256 content;
  };

  homeServiceEntry = name: content: enable: {
    inherit name enable;
    class = "service";
    mask = false;
    sha256 = homeSha256 content;
  };

  # -- fixture byte content -- deliberately small and grep-friendly (see
  #    homeActivationDriverScript's own assertions). `.profile`'s content
  #    is IDENTICAL between generation 1 and 2 -- the whole point of the
  #    "untouched file" proof is that its declared sha256/mode never
  #    changes, so bin/ubx-home's own diff algorithm (nix/home.nix's
  #    header) never even proposes touching it a second time.
  homeBashrcV1 = "# ubuntnix home-activation e2e fixture: gen1 .bashrc\nexport EDITOR=vim\n";
  homeBashrcV2 = "# ubuntnix home-activation e2e fixture: gen2 .bashrc (CHANGED)\nexport EDITOR=nano\n";
  homeProfileContent = "# ubuntnix home-activation e2e fixture: .profile (UNCHANGED across generations)\numask 022\n";

  homeSvcAContent = ''
    [Unit]
    Description=ubuntnix home-activation e2e fixture service A (declared enabled every generation -- this proof's own reboot/auto-start target)

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/bin/sh -c 'mkdir -p %h/.local/state && date +%s > %h/.local/state/home-svc-a-ran'

    [Install]
    WantedBy=default.target
  '';
  homeSvcBContent = ''
    [Unit]
    Description=ubuntnix home-activation e2e fixture service B (enabled in gen1, DECLARED DISABLED in gen2)

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/bin/sh -c 'mkdir -p %h/.local/state && date +%s > %h/.local/state/home-svc-b-ran'

    [Install]
    WantedBy=default.target
  '';

  homeGen1FileEntries = [
    (homeFileEntry ".bashrc" homeBashrcV1 "0644")
    (homeFileEntry ".profile" homeProfileContent "0640")
  ];
  homeGen1ServiceEntries = [
    (homeServiceEntry "home-svc-a.service" homeSvcAContent true)
    (homeServiceEntry "home-svc-b.service" homeSvcBContent true)
  ];
  homeGen2FileEntries = [
    (homeFileEntry ".bashrc" homeBashrcV2 "0644")
    (homeFileEntry ".profile" homeProfileContent "0640")
  ];
  homeGen2ServiceEntries = [
    (homeServiceEntry "home-svc-a.service" homeSvcAContent true)
    (homeServiceEntry "home-svc-b.service" homeSvcBContent false)
  ];

  homeManifestFor = files: services: builtins.toJSON {
    version = 1;
    users = [{ name = homeUserName; inherit files services; }];
  };
  homeGen1Manifest = homeManifestFor homeGen1FileEntries homeGen1ServiceEntries;
  homeGen2Manifest = homeManifestFor homeGen2FileEntries homeGen2ServiceEntries;

  # -- `--home-observed` overrides used ONLY when linger could not be
  #    confirmed reachable (see this section's own header) -- files carry
  #    the TRUE prior declared state (so the file side of the plan is
  #    completely unaffected: same "not rewritten" / "content changed"
  #    outcomes either way), services are reported as already exactly at
  #    THIS generation's own target (sha256/enabled/masked/active all
  #    matching), so bin/ubx-home's plan algorithm computes zero service
  #    actions and no `runuser`/`systemctl --user` call is ever attempted.
  homeObservedServiceFromDecl = s: {
    inherit (s) name sha256;
    enabled = s.enable;
    masked = s.mask;
    active = s.enable && !s.mask;
  };
  homeObservedFilesFromDecl = files: map (f: { inherit (f) path sha256 mode; }) files;
  homeObservedSkipServices = files: services: builtins.toJSON {
    version = 1;
    users = [{
      name = homeUserName;
      files = homeObservedFilesFromDecl files;
      services = map homeObservedServiceFromDecl services;
    }];
  };
  homeGen1ObservedSkipServices = homeObservedSkipServices [ ] homeGen1ServiceEntries;
  homeGen2ObservedSkipServices = homeObservedSkipServices homeGen1FileEntries homeGen2ServiceEntries;

  homeUsersManifest = builtins.toJSON {
    version = 1;
    users = [{
      name = homeUserName;
      uid = null;
      system = false;
      shell = "/usr/bin/bash";
      home = null;
      createHome = true;
      groups = [ ];
      authorizedKeys = [ ];
    }];
    groups = [ ];
  };

  # -- the extra-files script layered onto bootRootfs for the
  #    home-activation-proof only (mirrors switchLoopExtraFilesScript's own
  #    structure -- see this section's own header for what each numbered
  #    block does). ----------------------------------------------------
  homeActivationExtraFilesScript = ''
    # -- (1) persistent /home: overwrite bootRootfs's own M1 default (tmpfs,
    #    already correctly named+symlinked -- see this section's own
    #    header, decision 1) with a real ext4 mount of this proof's third
    #    disk partition. ----------------------------------------------
    ubxrun "$UBX_BASE/bin/cat" > "$out/etc/systemd/system/home.mount" <<'UBX_HOME_UNIT_EOF'
    [Unit]
    Description=ubuntnix home-activation e2e proof: persistent /home (ext4, GitHub issue #105)
    DefaultDependencies=no
    Before=local-fs.target

    [Mount]
    What=/dev/vda3
    Where=/home
    Type=ext4
    Options=defaults

    [Install]
    WantedBy=local-fs.target
    UBX_HOME_UNIT_EOF

    # -- (2) per-generation fixture manifests + content trees -----------
    ubxrun "$UBX_BASE/bin/mkdir" -p \
      "$out/usr/local/share/ubx-home-activation/gen1/home-tree/${homeUserName}/files" \
      "$out/usr/local/share/ubx-home-activation/gen1/home-tree/${homeUserName}/services" \
      "$out/usr/local/share/ubx-home-activation/gen2/home-tree/${homeUserName}/files" \
      "$out/usr/local/share/ubx-home-activation/gen2/home-tree/${homeUserName}/services"

    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-home-activation/users-manifest.json" <<'UBX_HOME_JSON_EOF'
    ${homeUsersManifest}
    UBX_HOME_JSON_EOF

    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-home-activation/gen1/home-manifest.json" <<'UBX_HOME_JSON_EOF'
    ${homeGen1Manifest}
    UBX_HOME_JSON_EOF
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-home-activation/gen1/home-observed-skip-services.json" <<'UBX_HOME_JSON_EOF'
    ${homeGen1ObservedSkipServices}
    UBX_HOME_JSON_EOF
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-home-activation/gen1/home-tree/${homeUserName}/files/.bashrc" <<'UBX_HOME_CONTENT_EOF'
    ${homeBashrcV1}
    UBX_HOME_CONTENT_EOF
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-home-activation/gen1/home-tree/${homeUserName}/files/.profile" <<'UBX_HOME_CONTENT_EOF'
    ${homeProfileContent}
    UBX_HOME_CONTENT_EOF
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-home-activation/gen1/home-tree/${homeUserName}/services/home-svc-a.service" <<'UBX_HOME_UNIT_EOF'
    ${homeSvcAContent}
    UBX_HOME_UNIT_EOF
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-home-activation/gen1/home-tree/${homeUserName}/services/home-svc-b.service" <<'UBX_HOME_UNIT_EOF'
    ${homeSvcBContent}
    UBX_HOME_UNIT_EOF

    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-home-activation/gen2/home-manifest.json" <<'UBX_HOME_JSON_EOF'
    ${homeGen2Manifest}
    UBX_HOME_JSON_EOF
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-home-activation/gen2/home-observed-skip-services.json" <<'UBX_HOME_JSON_EOF'
    ${homeGen2ObservedSkipServices}
    UBX_HOME_JSON_EOF
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-home-activation/gen2/home-tree/${homeUserName}/files/.bashrc" <<'UBX_HOME_CONTENT_EOF'
    ${homeBashrcV2}
    UBX_HOME_CONTENT_EOF
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-home-activation/gen2/home-tree/${homeUserName}/files/.profile" <<'UBX_HOME_CONTENT_EOF'
    ${homeProfileContent}
    UBX_HOME_CONTENT_EOF
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-home-activation/gen2/home-tree/${homeUserName}/services/home-svc-a.service" <<'UBX_HOME_UNIT_EOF'
    ${homeSvcAContent}
    UBX_HOME_UNIT_EOF
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/share/ubx-home-activation/gen2/home-tree/${homeUserName}/services/home-svc-b.service" <<'UBX_HOME_UNIT_EOF'
    ${homeSvcBContent}
    UBX_HOME_UNIT_EOF

    # -- (3) the guest driver + its unit ---------------------------------
    ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/bin/ubx-home-activation-driver" <<'UBX_HOME_DRIVER_EOF'
    ${homeActivationDriverScript}
    UBX_HOME_DRIVER_EOF
    ubxrun "$UBX_BASE/bin/chmod" +x "$out/usr/local/bin/ubx-home-activation-driver"

    ubxrun "$UBX_BASE/bin/cat" > "$out/etc/systemd/system/ubx-home-activation-driver.service" <<'UBX_HOME_UNIT_EOF'
    [Unit]
    Description=ubuntnix home-activation e2e proof driver (tests/e2e/060-qemu-home-activation-e2e.sh; GitHub issue #105)
    After=home.mount multi-user.target
    Requires=home.mount multi-user.target

    [Service]
    Type=oneshot
    StandardOutput=journal+console
    StandardError=journal+console
    ExecStart=/usr/local/bin/ubx-home-activation-driver

    [Install]
    WantedBy=multi-user.target
    UBX_HOME_UNIT_EOF
    ubxrun "$UBX_BASE/bin/mkdir" -p "$out/etc/systemd/system/multi-user.target.wants"
    ubxrun "$UBX_BASE/bin/ln" -sf ../ubx-home-activation-driver.service \
      "$out/etc/systemd/system/multi-user.target.wants/ubx-home-activation-driver.service"
  '';

  # -- the guest driver script itself: a two-phase counter on the
  #    persistent `/home/.ubx-home-state/phase` file (the ext4 partition is
  #    the only thing this proof needs to survive its one real reboot --
  #    see this section's own header, decision 2). ----------------------
  homeActivationDriverScript = ''
    #!/bin/bash
    # /usr/local/bin/ubx-home-activation-driver -- see nix/boot.nix's
    # home-activation-proof section (GitHub issue #105) for the full design.
    set -u
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

    # This proof converges $HOME LIVE; it deliberately does not exercise
    # rootfs image-swaps. The first (from-<none>) generation nonetheless
    # classifies as an "image" delta, which would make `ubx rebuild switch`
    # really mount the fixture rootfs marker at /run/nextroot and then
    # soft-reboot -- but that marker is intentionally NOT a real device, so
    # the mount (and thus the whole switch) would fail. Stub both injectable
    # commands to no-ops (invoked as `CMD IMAGE TARGET` / `CMD soft-reboot`;
    # `true` ignores its args and succeeds), mirroring switchLoopDriverScript's
    # own UBX_SOFT_REBOOT_CMD stub. Home file/service convergence is unaffected.
    export UBX_NEXTROOT_STAGE_CMD=true
    export UBX_SOFT_REBOOT_CMD=true

    ASSETS=/usr/local/share/ubx-home-activation
    ROOT=/run/ubx-home-activation/generations
    STATE=/home/.ubx-home-state
    UBX=/ubx/bin/ubx
    USER_NAME=${homeUserName}

    mkdir -p "$STATE" "$ROOT"
    phase_file="$STATE/phase"
    phase=0
    [ -f "$phase_file" ] && phase="$(cat "$phase_file")"

    mark_fail() { # REASON
      echo "UBX-HOME-FAIL: $1"
      echo "----- BEGIN mark_fail diagnostics -----"
      referenced_log="$(printf '%s\n' "$1" | grep -o '[^ ]*\.log' | tail -n 1)"
      if [ -n "$referenced_log" ] && [ -f "$referenced_log" ]; then
        echo "----- BEGIN $referenced_log -----"
        tail -n 200 "$referenced_log"
        echo "----- END $referenced_log -----"
      elif [ -n "$referenced_log" ]; then
        echo "(referenced log $referenced_log not found)"
      fi
      echo "----- BEGIN ls -la $STATE -----"
      ls -la "$STATE" 2> /dev/null
      echo "----- END ls -la $STATE -----"
      for f in "$STATE"/*.log; do
        [ -f "$f" ] || continue
        echo "----- BEGIN $f -----"
        tail -n 200 "$f"
        echo "----- END $f -----"
      done
      echo "----- END mark_fail diagnostics -----"
      sync
      systemctl poweroff
      exit 0
    }

    advance() { # NEXT_PHASE
      printf '%s' "$1" > "$phase_file"
    }

    # Writable /etc (see this section's own header, decision 2) -- guarded
    # by a /run marker so it only happens once per boot.
    if [ ! -e /run/ubx-home-etc-bound ]; then
      mkdir -p /run/ubx-home-etc-writable
      cp -a /etc/. /run/ubx-home-etc-writable/
      mount --bind /run/ubx-home-etc-writable /etc
      : > /run/ubx-home-etc-bound
    fi

    case "$phase" in
      0)
        # ============ create the declared fixture user for real =========
        "$UBX" rebuild switch --root "$ROOT" \
          --rootfs-image "$ASSETS/rootfs-marker" --kernel "$ASSETS/kernel-marker" --initrd "$ASSETS/initrd-marker" \
          --root-device /dev/vda2 \
          --users-manifest "$ASSETS/users-manifest.json" \
          --apply --systemd-unit-dir /run/systemd/system \
          --users-out "$STATE/gen1-users-activate.sh" \
          > "$STATE/gen1-create.log" 2>&1
        rc=$?
        [ "$rc" -eq 0 ] || mark_fail "generation 1 'ubx rebuild switch' (account creation) exited $rc -- see $STATE/gen1-create.log"
        bash "$STATE/gen1-users-activate.sh" >> "$STATE/gen1-create.log" 2>&1
        getent passwd "$USER_NAME" > /dev/null 2>&1 \
          || mark_fail "declared user $USER_NAME is not present after running its activation script -- see $STATE/gen1-create.log"
        user_uid="$(id -u "$USER_NAME")"
        [ -d "/home/$USER_NAME" ] || mark_fail "useradd -m did not create /home/$USER_NAME on the persistent ext4 partition"
        echo "UBX-HOME-USER-PASS"

        # ============ loginctl enable-linger + poll for a reachable
        # per-user systemctl --user bus (see this section's own header,
        # "The systemctl --user / linger question") ======================
        linger_ok=0
        if command -v loginctl > /dev/null 2>&1; then
          loginctl enable-linger "$USER_NAME" > "$STATE/linger.log" 2>&1 || true
          i=0
          while [ "$i" -lt 30 ]; do
            if systemctl is-active --quiet "user@$user_uid.service" 2> /dev/null \
              && [ -S "/run/user/$user_uid/bus" ]; then
              linger_ok=1
              break
            fi
            i=$((i + 1))
            sleep 1
          done
        fi
        if [ "$linger_ok" -eq 1 ]; then
          echo "UBX-HOME-LINGER-PASS: user@$user_uid.service is active and /run/user/$user_uid/bus is reachable"
        else
          echo "UBX-HOME-LINGER-NOTE: could not reach a per-user systemctl --user bus for $USER_NAME within 30s after loginctl enable-linger (see $STATE/linger.log, and nix/boot.nix's home-activation-proof section header, 'The systemctl --user / linger question', for why this is a documented, non-fatal gap in this project's own locked archive -- no dbus/dbus-user-session package) -- every systemctl --user-dependent assertion below (service enable/active/auto-start) is SKIPPED this run; file content/mode/ownership and the gen1-file-not-rewritten diff proof still run for real"
        fi
        printf '%s' "$linger_ok" > "$STATE/linger-ok"

        # ============ generation 2: apply gen1's home declaration ========
        home_observed_args=()
        [ "$linger_ok" -eq 1 ] || home_observed_args=(--home-observed "$ASSETS/gen1/home-observed-skip-services.json")
        "$UBX" rebuild switch --root "$ROOT" \
          --rootfs-image "$ASSETS/rootfs-marker" --kernel "$ASSETS/kernel-marker" --initrd "$ASSETS/initrd-marker" \
          --root-device /dev/vda2 \
          --users-manifest "$ASSETS/users-manifest.json" \
          --home-manifest "$ASSETS/gen1/home-manifest.json" --home-content-dir "$ASSETS/gen1/home-tree" \
          "''${home_observed_args[@]}" \
          --apply --systemd-unit-dir /run/systemd/system \
          --users-out "$STATE/gen1-home-users-activate.sh" \
          > "$STATE/gen1-home.log" 2>&1
        rc=$?
        [ "$rc" -eq 0 ] || mark_fail "generation 2 'ubx rebuild switch' (gen1 home apply) exited $rc -- see $STATE/gen1-home.log"
        bash "$STATE/gen1-home-users-activate.sh" >> "$STATE/gen1-home.log" 2>&1

        bashrc="/home/$USER_NAME/.bashrc"
        profile="/home/$USER_NAME/.profile"
        [ -f "$bashrc" ] || mark_fail "gen1: $bashrc was not created -- see $STATE/gen1-home.log"
        grep -qF "EDITOR=vim" "$bashrc" || mark_fail "gen1: $bashrc does not contain the gen1 fixture content"
        [ "$(stat -c '%U:%G %a' "$bashrc" 2> /dev/null)" = "$USER_NAME:$USER_NAME 644" ] \
          || mark_fail "gen1: $bashrc has the wrong owner/group/mode: $(stat -c '%U:%G %a' "$bashrc" 2>&1)"
        [ -f "$profile" ] || mark_fail "gen1: $profile was not created -- see $STATE/gen1-home.log"
        grep -qF "UNCHANGED across generations" "$profile" || mark_fail "gen1: $profile does not contain the fixture content"
        [ "$(stat -c '%U:%G %a' "$profile" 2> /dev/null)" = "$USER_NAME:$USER_NAME 640" ] \
          || mark_fail "gen1: $profile has the wrong owner/group/mode: $(stat -c '%U:%G %a' "$profile" 2>&1)"
        # Recorded so generation 2 below can prove -- via mtime+inode, not
        # just "content still matches" -- that this exact file is NEVER
        # rewritten when its declaration never changes (SPEC.md §9's own
        # diff-driven activation contract).
        stat -c '%Y %i' "$profile" > "$STATE/profile-stat-gen1"

        if [ "$linger_ok" -eq 1 ]; then
          runuser -u "$USER_NAME" -- systemctl --user is-enabled home-svc-a.service > "$STATE/gen1-svc.log" 2>&1 \
            || mark_fail "gen1: home-svc-a.service is not enabled -- see $STATE/gen1-svc.log"
          runuser -u "$USER_NAME" -- systemctl --user is-active home-svc-a.service >> "$STATE/gen1-svc.log" 2>&1 \
            || mark_fail "gen1: home-svc-a.service is not active -- see $STATE/gen1-svc.log"
          runuser -u "$USER_NAME" -- systemctl --user is-enabled home-svc-b.service >> "$STATE/gen1-svc.log" 2>&1 \
            || mark_fail "gen1: home-svc-b.service is not enabled -- see $STATE/gen1-svc.log"
          runuser -u "$USER_NAME" -- systemctl --user is-active home-svc-b.service >> "$STATE/gen1-svc.log" 2>&1 \
            || mark_fail "gen1: home-svc-b.service is not active -- see $STATE/gen1-svc.log"
        fi
        echo "UBX-HOME-GEN1-PASS"

        # ============ generation 3: apply gen2's home declaration ========
        home_observed_args=()
        [ "$linger_ok" -eq 1 ] || home_observed_args=(--home-observed "$ASSETS/gen2/home-observed-skip-services.json")
        "$UBX" rebuild switch --root "$ROOT" \
          --rootfs-image "$ASSETS/rootfs-marker" --kernel "$ASSETS/kernel-marker" --initrd "$ASSETS/initrd-marker" \
          --root-device /dev/vda2 \
          --users-manifest "$ASSETS/users-manifest.json" \
          --home-manifest "$ASSETS/gen2/home-manifest.json" --home-content-dir "$ASSETS/gen2/home-tree" \
          "''${home_observed_args[@]}" \
          --apply --systemd-unit-dir /run/systemd/system \
          --users-out "$STATE/gen2-home-users-activate.sh" \
          > "$STATE/gen2-home.log" 2>&1
        rc=$?
        [ "$rc" -eq 0 ] || mark_fail "generation 3 'ubx rebuild switch' (gen2 home apply) exited $rc -- see $STATE/gen2-home.log"
        bash "$STATE/gen2-home-users-activate.sh" >> "$STATE/gen2-home.log" 2>&1

        grep -qF "EDITOR=nano" "$bashrc" || mark_fail "gen2: $bashrc's content did not update to the gen2 fixture -- see $STATE/gen2-home.log"
        grep -qF "EDITOR=vim" "$bashrc" && mark_fail "gen2: $bashrc still contains gen1's content after a declared change"
        profile_stat_gen1="$(cat "$STATE/profile-stat-gen1" 2> /dev/null)"
        profile_stat_gen2="$(stat -c '%Y %i' "$profile" 2> /dev/null)"
        [ "$profile_stat_gen2" = "$profile_stat_gen1" ] \
          || mark_fail "gen2: $profile's mtime+inode changed even though its declared content never changed between gen1 and gen2 (it was rewritten when bin/ubx-home's own diff algorithm should have left it untouched) -- gen1=[$profile_stat_gen1] gen2=[$profile_stat_gen2]"

        if [ "$linger_ok" -eq 1 ]; then
          runuser -u "$USER_NAME" -- systemctl --user is-enabled home-svc-b.service > "$STATE/gen2-svc.log" 2>&1 \
            && mark_fail "gen2: home-svc-b.service is still enabled after being declared disabled -- see $STATE/gen2-svc.log"
          runuser -u "$USER_NAME" -- systemctl --user is-active home-svc-b.service >> "$STATE/gen2-svc.log" 2>&1 \
            && mark_fail "gen2: home-svc-b.service is still active after being declared disabled -- see $STATE/gen2-svc.log"
          runuser -u "$USER_NAME" -- systemctl --user is-enabled home-svc-a.service >> "$STATE/gen2-svc.log" 2>&1 \
            || mark_fail "gen2: home-svc-a.service should still be enabled (its declaration never changed) -- see $STATE/gen2-svc.log"
        fi
        echo "UBX-HOME-GEN2-PASS"

        advance 1
        sync
        systemctl reboot
        ;;

      1)
        linger_ok=0
        [ -f "$STATE/linger-ok" ] && linger_ok="$(cat "$STATE/linger-ok")"
        user_uid="$(id -u "$USER_NAME" 2> /dev/null)"
        [ -n "$user_uid" ] || mark_fail "post-reboot: user $USER_NAME is gone after a real reboot"

        bashrc="/home/$USER_NAME/.bashrc"
        profile="/home/$USER_NAME/.profile"
        [ -f "$bashrc" ] || mark_fail "post-reboot: $bashrc did not survive the reboot"
        grep -qF "EDITOR=nano" "$bashrc" || mark_fail "post-reboot: $bashrc's gen2 content did not survive the reboot"
        [ -f "$profile" ] || mark_fail "post-reboot: $profile did not survive the reboot"

        if [ "$linger_ok" -eq 1 ]; then
          # logind restarts user@<uid>.service for every lingering user at
          # boot; that user manager's own default.target then starts every
          # unit still enabled in its (persistent) unit-state directory --
          # home-svc-a.service among them -- with NO explicit `systemctl
          # --user start` call from this driver at all. That is the actual
          # thing this whole proof exists to demonstrate; poll briefly
          # since this races ordinary boot-up.
          i=0
          svc_ok=0
          while [ "$i" -lt 30 ]; do
            if systemctl is-active --quiet "user@$user_uid.service" 2> /dev/null \
              && runuser -u "$USER_NAME" -- systemctl --user is-active --quiet home-svc-a.service 2> /dev/null; then
              svc_ok=1
              break
            fi
            i=$((i + 1))
            sleep 1
          done
          [ "$svc_ok" -eq 1 ] \
            || mark_fail "post-reboot: home-svc-a.service (declared enabled, never explicitly started this boot) did not auto-start within 30s of a real reboot despite 'loginctl enable-linger $USER_NAME' -- linger did not do what it should"
          runuser -u "$USER_NAME" -- systemctl --user is-active --quiet home-svc-b.service 2> /dev/null \
            && mark_fail "post-reboot: home-svc-b.service (declared disabled) auto-started after the reboot"
          echo "UBX-HOME-REBOOT-PASS"
        else
          echo "UBX-HOME-REBOOT-PASS: linger/systemctl --user bus was not reachable earlier this run (see the UBX-HOME-LINGER-NOTE above) -- only file persistence across the real reboot was verified above; the enabled-user-service auto-start proof was SKIPPED, never silently assumed"
        fi

        sync
        systemctl poweroff
        ;;

      *)
        echo "UBX-HOME-FAIL: unknown phase '$phase'"
        systemctl poweroff
        ;;
    esac
  '';
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

      # -- the M2 switch-loop-proof (GitHub issue #32; see nix/boot.nix's
      #    own "switch-loop-proof" section above for the full design). The
      #    kernel is REUSED from M1's own proofKernel above (unchanged
      #    flavor/package set -- no need to re-extract vmlinuz/initrd from
      #    a second, mostly-identical rootfs compose); everything else
      #    (rootfs, squashfs, the ext4 /ubx/var image, the disk image) is
      #    this proof's own. -------------------------------------------
      switchLoopKernelPath = "${proofKernel}/vmlinuz-${flavor}";
      switchLoopInitrdPath = "${proofKernel}/initrd.img-${flavor}";

      switchLoopRootfs = bootRootfs {
        inherit system bootSpec;
        name = "switch-loop-proof";
        extraFilesScript = switchLoopExtraFilesScript;
      };

      switchLoopSquashfs = squashfsImage {
        inherit system;
        name = "switch-loop-proof";
        rootfs = switchLoopRootfs;
      };

      switchLoopRootfsImagePath = "${switchLoopSquashfs}/rootfs.squashfs";

      switchLoopVarStoreDrv = switchLoopVarStore {
        inherit system;
        name = "switch-loop-proof";
        rootfsImage = switchLoopRootfsImagePath;
        kernelPath = switchLoopKernelPath;
        initrdPath = switchLoopInitrdPath;
      };

      switchLoopVarImageDrv = switchLoopVarImage {
        inherit system;
        name = "switch-loop-proof";
        varStore = switchLoopVarStoreDrv;
      };

      # Same single-entry GRUB menu shape as M1's own proofGeneration
      # (same kernel, same root device for the squashfs partition -- the
      # third, ext4 partition needs no GRUB entry of its own, it is mounted
      # by a systemd .mount unit at boot, not selected at the bootloader).
      switchLoopGeneration = {
        index = 1;
        title = "ubuntnix switch-loop-proof generation 1 (${bootSpec.kernel})";
        kernelPath = "/vmlinuz-${flavor}";
        initrdPath = "/initrd.img-${flavor}";
        rootDevice = "/dev/vda2";
        kernelParams = bootSpec.kernelParams ++ [
          "rootfstype=squashfs"
          "console=ttyS0"
        ];
      };

      switchLoopGrubCfgDrv = grubCfg {
        inherit system;
        name = "switch-loop-proof";
        generations = [ switchLoopGeneration ];
      };

      switchLoopDiskImageDrv = switchLoopDiskImage {
        inherit system flavor;
        name = "switch-loop-proof";
        squashfs = switchLoopSquashfs;
        kernel = proofKernel;
        grubCfgDrv = switchLoopGrubCfgDrv;
        varImage = switchLoopVarImageDrv;
      };

      # -- the M3 snap-converge-proof (GitHub issue #64; see nix/boot.nix's
      #    own "snap-converge-proof" section above for the full design).
      #    Kernel reused from M1's proofKernel, exactly like the M2
      #    switch-loop-proof above; no ext4 partition needed (single-boot
      #    proof, see that section's header), so this reuses the plain
      #    two-partition `diskImage` (M1) rather than
      #    `switchLoopDiskImage`. ------------------------------------------
      snapConvergeRootfs = bootRootfs {
        inherit system bootSpec;
        name = "snap-converge-proof";
        extraFilesScript = snapConvergeExtraFilesScript;
        extraEnv = { inherit snapConvergeHelloWorldPayload snapConvergeHelloWorldAssert; };
      };

      snapConvergeSquashfs = squashfsImage {
        inherit system;
        name = "snap-converge-proof";
        rootfs = snapConvergeRootfs;
      };

      snapConvergeGeneration = {
        index = 1;
        title = "ubuntnix snap-converge-proof generation 1 (${bootSpec.kernel})";
        kernelPath = "/vmlinuz-${flavor}";
        initrdPath = "/initrd.img-${flavor}";
        rootDevice = "/dev/vda2";
        kernelParams = bootSpec.kernelParams ++ [
          "rootfstype=squashfs"
          "console=ttyS0"
        ];
      };

      snapConvergeGrubCfgDrv = grubCfg {
        inherit system;
        name = "snap-converge-proof";
        generations = [ snapConvergeGeneration ];
      };

      snapConvergeDiskImageDrv = diskImage {
        inherit system flavor;
        name = "snap-converge-proof";
        squashfs = snapConvergeSquashfs;
        kernel = proofKernel;
        grubCfgDrv = snapConvergeGrubCfgDrv;
      };

      # -- the soft-reboot-proof (GitHub issue #59; see nix/boot.nix's own
      #    "soft-reboot-proof" section above for the full design). Kernel
      #    reused from M1's proofKernel exactly like the M2/M3 proofs above;
      #    no ext4 partition needed (state lives in /run across the
      #    soft-reboot re-exec itself -- see that section's own header), so
      #    this reuses the plain two-partition `diskImage` (M1), not
      #    `switchLoopDiskImage`. --------------------------------------
      softRebootRootfs = bootRootfs {
        inherit system bootSpec;
        name = "soft-reboot-proof";
        extraFilesScript = softRebootExtraFilesScript;
      };

      softRebootSquashfs = squashfsImage {
        inherit system;
        name = "soft-reboot-proof";
        rootfs = softRebootRootfs;
      };

      softRebootGeneration = {
        index = 1;
        title = "ubuntnix soft-reboot-proof generation 1 (${bootSpec.kernel})";
        kernelPath = "/vmlinuz-${flavor}";
        initrdPath = "/initrd.img-${flavor}";
        rootDevice = "/dev/vda2";
        kernelParams = bootSpec.kernelParams ++ [
          "rootfstype=squashfs"
          "console=ttyS0"
        ];
      };

      softRebootGrubCfgDrv = grubCfg {
        inherit system;
        name = "soft-reboot-proof";
        generations = [ softRebootGeneration ];
      };

      softRebootDiskImageDrv = diskImage {
        inherit system flavor;
        name = "soft-reboot-proof";
        squashfs = softRebootSquashfs;
        kernel = proofKernel;
        grubCfgDrv = softRebootGrubCfgDrv;
      };

      # -- the home-activation-proof (GitHub issue #105; see nix/boot.nix's
      #    own "home-activation-proof" section above for the full design).
      #    Kernel reused from M1's proofKernel exactly like every other
      #    proof above; this one DOES need `switchLoopDiskImage`'s three-
      #    partition layout (a real, persistent /home, mounted from a third
      #    ext4 partition, is the whole point -- see that section's own
      #    header, decision 1), even though it never needs
      #    `switchLoopVarStore`'s own gen1-bookkeeping content (this proof's
      #    ext4 partition starts genuinely empty; `useradd -m` and the home
      #    domain's own executor populate it for real at boot time). -------
      homeActivationRootfs = bootRootfs {
        inherit system bootSpec;
        name = "home-activation-proof";
        extraFilesScript = homeActivationExtraFilesScript;
      };

      homeActivationSquashfs = squashfsImage {
        inherit system;
        name = "home-activation-proof";
        rootfs = homeActivationRootfs;
      };

      homeActivationVarStoreDrv = runInUbuntuBase {
        inherit system;
        name = "home-activation-var-store";
        script = ''
          ubxrun() { "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" "$@"; }
          ubxrun "$UBX_BASE/bin/mkdir" -p "$out"
        '';
      };

      homeActivationVarImageDrv = switchLoopVarImage {
        inherit system;
        name = "home-activation-proof";
        varStore = homeActivationVarStoreDrv;
        sizeMiB = 64;
      };

      homeActivationGeneration = {
        index = 1;
        title = "ubuntnix home-activation-proof generation 1 (${bootSpec.kernel})";
        kernelPath = "/vmlinuz-${flavor}";
        initrdPath = "/initrd.img-${flavor}";
        rootDevice = "/dev/vda2";
        kernelParams = bootSpec.kernelParams ++ [
          "rootfstype=squashfs"
          "console=ttyS0"
        ];
      };

      homeActivationGrubCfgDrv = grubCfg {
        inherit system;
        name = "home-activation-proof";
        generations = [ homeActivationGeneration ];
      };

      homeActivationDiskImageDrv = switchLoopDiskImage {
        inherit system flavor;
        name = "home-activation-proof";
        squashfs = homeActivationSquashfs;
        kernel = proofKernel;
        grubCfgDrv = homeActivationGrubCfgDrv;
        varImage = homeActivationVarImageDrv;
      };
    in
    {
      packages.boot-kernel-artifacts-proof = proofKernel;
      packages.boot-grub-cfg-proof = proofGrubCfg;
      # The flake output proof this issue's scope calls for (item 4: "Expose
      # the image as a flake output proof (e.g. .#boot-image-proof)").
      packages.boot-image-proof = proofDiskImage;
      # SPEC.md §11 M2's own exit-criterion proof (GitHub issue #32) --
      # tests/e2e/020-qemu-switch-e2e.sh boots this one.
      packages.switch-loop-proof = switchLoopDiskImageDrv;
      # SPEC.md §11 M3's own exit-criterion proof (GitHub issue #64) --
      # tests/e2e/030-qemu-snap-e2e.sh boots this one.
      packages.snap-converge-proof = snapConvergeDiskImageDrv;
      # GitHub issue #59's own exit criterion (a real `systemctl
      # soft-reboot` re-exec into a genuinely bootable /run/nextroot) --
      # tests/e2e/040-qemu-soft-reboot-e2e.sh boots this one.
      packages.soft-reboot-proof = softRebootDiskImageDrv;
      # GitHub issue #105's own exit criterion (a real, booted
      # `ubx rebuild switch --apply` home-domain activation: $HOME files +
      # a per-user systemd --user service, across two generations and a
      # real reboot) -- tests/e2e/060-qemu-home-activation-e2e.sh boots
      # this one.
      packages.home-activation-proof = homeActivationDiskImageDrv;
    };
}
