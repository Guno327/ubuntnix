# nix/compose.nix — rootfs image composition: maintainer scripts + debconf
# preseeds inside a HARDENED Ubuntu-native sandbox (SPEC.md §4.1, §4.2, §6;
# GitHub issue #9, milestone M1).
#
# This is the follow-up nix/stdenv.nix's own "HARDENING NOTE" promised: that
# file's `runInUbuntuBase` runs scripts via a raw ld.so invocation with no
# real filesystem root of their own (they can still see the outer Nix
# sandbox filesystem, and any dynamically-linked ubuntu-base binary they
# spawn as a CHILD process — rather than one WE explicitly loader-wrap —
# fails outright, per that file's "BOOTSTRAP CAVEAT"). That was fine for
# proving ubuntu-base binaries run at all (issue #6) and for fetching/
# parsing one .deb's control data (issue #7); it is not fine for running
# arbitrary Debian maintainer scripts, which assume a completely normal FHS
# root (`/bin`, `/usr`, `/etc`, `/proc`, `/dev`, absolute shebangs like
# `/usr/share/debconf/confmodule`, and exec-by-bare-name everywhere).
#
# -- GitHub issue #48: fakeroot replaces the scan/restore interim ---------
#
# PR #36 (see this file's git history / the "PR #36" section that used to
# live here) introduced an INTERIM workaround for two independent, real
# dpkg unpack-time failures under this file's single-id-mapped user
# namespace: chown(2) to a non-root owner fails EINVAL, and chmod(2)
# setting a setuid/setgid/sticky bit fails EPERM, both unconditionally
# attempted by dpkg's own tarobject() with no force flag to suppress them
# (see https://lists.debian.org/debian-dpkg/2007/12/msg00031.html). That
# interim (bin/ubx-scan-deb-ownership, now DELETED) pre-scanned every
# .deb's data.tar for the affected paths, `--path-exclude`d them from
# dpkg's own extraction, restored their real content unprivileged and
# separately, and recorded owner+mode in an mksquashfs pseudo-file
# manifest applied at pack time -- three separate, hand-rolled mechanisms
# for one root cause.
#
# fakeroot is the GENERAL fix that same interim's own header always
# pointed at: an LD_PRELOAD library that intercepts chown(2)/chmod(2)/
# stat(2) and friends, fakes success for the calling process while
# recording the INTENDED owner/mode in an in-memory (or save-file-backed)
# database, and transparently returns that faked data to any later
# stat(2) call made by a process sharing the same fakeroot session. This
# lets `dpkg --unpack`/`--configure` run with NO --path-exclude dance at
# all -- every path extracts normally, dpkg's own chown/chmod calls all
# "succeed" (faked), and the composed tree's TRUE ownership/mode data
# lives in fakeroot's own database for as long as something reads it back
# through the same faked session.
#
# Two consequences that shape the design below:
#   (1) fakeroot's fake data is NOT written to the real on-disk inode --
#       real chown to a non-root id, or a real chmod setting a special
#       bit, remains just as impossible here as it always was; only
#       PROCESSES SHARING THE FAKED SESSION see the faked values via
#       their own stat(2) calls. Nix's own post-build store-path
#       canonicalization (0444 files / 0555 dirs, unconditional -- see
#       the "Nix canonicalizes every registered store path read-only"
#       comment further down) therefore still applies to composeRootfs's
#       raw $out regardless of fakeroot -- exactly as before fakeroot,
#       $out's own on-disk permission bits are NOT where the true
#       ownership/mode record lives.
#   (2) The true record must therefore survive PAST this derivation's own
#       build, for squashfsImage (a separate derivation, run later) to
#       pack correct inode metadata. fakeroot's `-s`/`-i` save/load-file
#       flags exist for exactly this cross-invocation handoff (the same
#       mechanism Debian's own dh_fixperms -> dh_builddeb pipeline uses):
#       composeRootfs's fakeroot session ends with `-s /.ubx-fakeroot-state`
#       (written at $out's TOP level, so it survives `rm -rf
#       /.ubx-compose` and is exposed to squashfsImage as part of
#       $rootfs); squashfsImage loads it back with `-i` and runs
#       mksquashfs itself AS A CLIENT OF THAT SAME FAKED SESSION, so
#       mksquashfs's own stat(2) calls see the true owner/mode directly --
#       no manifest, no pseudo-file pass, no scan script.
#
# fakeroot is fetched from the locked Ubuntu archive like any other
# package (archive.packages.json declares it; see that file's own comment
# for the exact `bin/ubx-resolve` regeneration this issue still owes the
# lockfile) and used purely as a BUILD TOOL here (via `toolsFHS`, exactly
# like squashfs-tools/liblzo2-2 already are) -- it is never added to a
# composed rootfs's OWN `packages` list, since nothing about the target
# system needs fakeroot installed at runtime.
#
# CI VERIFICATION NOTE (mirrors this file's own existing note on
# `unshare --user`): this dev harness has no `nix`, no `fakeroot`, and no
# `dpkg` binary to exercise ANY of this against a real build (see the
# `which fakeroot faked dpkg` checks that came back empty during this
# issue's own implementation). The exact absolute paths fakeroot's Ubuntu
# package installs `fakeroot`/`faked`/`libfakeroot-*.so` under are
# therefore discovered at BUILD time (a `find` over the extracted
# `toolsFHS` tree, both here and in squashfsImage below) rather than
# hardcoded from an unverifiable guess -- if CI's first real build can't
# locate one of the three, that `find` failing loudly with a clear message
# is the signal to go fix, not a wrong hardcoded path silently no-op'ing.
#
# -- What this file builds -----------------------------------------------
#
# `composeRootfs` (below): given a list of already-locked package names
# (SPEC.md §4.4's archive lockfile, via nix/archive.nix's `debs`) and an
# optional debconf preseed attrset (SPEC.md §6's `ubuntnix.debconf` shape),
# produces a full rootfs directory tree: ubuntu-base plus every declared
# package, unpacked and CONFIGURED — i.e. every maintainer script (preinst/
# postinst) has actually run, exactly as it would on a real Ubuntu install,
# inside a real chroot (see "HARDENING" in `composeRootfs` below).
#
# `squashfsImage` (below): packages an already-composed rootfs tree into a
# read-only squashfs image using `mksquashfs`, itself sourced from the
# locked Ubuntu archive (never nixpkgs — SPEC.md §1.3) via two new
# archive.lock.json entries this issue adds (`squashfs-tools`,
# `liblzo2-2` — see that file's own comments for why).
#
# Priority ordering followed here (per the issue's design guidance, in case
# later work needs to pick this file back up): (1) rootfs tree composition
# + maintainer scripts + hardened chroot, (2) debconf preseeds, (3) the
# squashfs image artifact, (4) determinism CI (the two-run comparison lives
# in .github/workflows/ci.yml, not here — this file's contribution to (4)
# is the mtime/log normalization inside `composeRootfs` below).
#
# -- SPEC.md §12 R1 determinism inventory ---------------------------------
#
# Maintainer-script nondeterminism is a TRACKED RISK (R1), not a solved
# problem — this file normalizes what is reasonably normalizable at
# compose time and documents what it cannot. GitHub issue #22 (`nix build
# --rebuild .#compose-proof` observed non-reproducible) re-audited every
# suspect below individually; each decision's reasoning also lives inline
# at the point in `composeRootfs`'s script where it's implemented, so this
# list is a summary/index, not the only copy of the reasoning.
#
#   NORMALIZED here:
#     - every file/directory mtime in the composed tree is reset to the
#       Unix epoch after configuration (dpkg's own admin-dir writes —
#       /var/lib/dpkg/status, /var/lib/dpkg/info/*, alternatives, ... —
#       otherwise carry the wall-clock time of the build);
#     - /var/log/dpkg.log (dpkg's own action log) is removed outright — it
#       is a literal timestamped transcript of the build, carrying no
#       configuration-relevant information;
#     - the squashfs image step passes `-mkfs-time 0 -all-time 0` (fixes
#       the image's own embedded superblock/inode timestamps) and
#       `-processors 1` (mksquashfs's parallel block-compression path is a
#       documented source of nondeterministic block ordering with >1
#       worker — this is standard practice for reproducible squashfs
#       builds, e.g. Debian's live-build);
#     - (issue #22) `dpkg --unpack` runs in an EXPLICIT order generated
#       from the Nix-side `packages` list (see `unpackLines` below),
#       rather than a shell glob over `/.ubx-compose/debs/*.deb` — a glob
#       is deterministic FOR A FIXED SET OF FILENAMES, but is a needless
#       dependency on filesystem/locale globbing behavior for something
#       Nix already knows the intended order of, and does not sort
#       numerically past 9 entries (`10.deb` < `2.deb` lexically). Since
#       dpkg appends each newly-unpacked package's stanza to
#       /var/lib/dpkg/status (and creates /var/lib/dpkg/info/<pkg>.* ) in
#       unpack order, pinning this order also pins those files' content —
#       likely fixing several of the suspects issue #22 enumerated (status
#       ordering, info database) as a side effect of fixing just this one
#       thing;
#     - (issue #22) `PERL_HASH_SEED=0 PERL_PERTURB_KEYS=0` is exported for
#       the whole in-chroot configuration run — Perl (since 5.18) randomizes
#       hash-key iteration order per process by default specifically to
#       harden against algorithmic-complexity attacks; any Perl program
#       that serializes `keys %hash` without an explicit sort (debconf's
#       own DbDriver::File config/templates writer is the leading suspect
#       here, and the `debconf` package IS present in this project's
#       locked archive set — see archive.lock.json) can therefore write
#       differently-ordered output across independent process invocations
#       even given byte-identical input. Pinning the seed is a standard,
#       safe mitigation for exactly this reproducibility class (used by
#       Debian's own reproducible-builds effort) — it changes iteration
#       ORDER only, never a correct Perl program's externally observable
#       behavior;
#     - (issue #22) a canonical, explicit final `ldconfig` re-run, plus
#       deletion of `/var/cache/ldconfig/aux-cache` (a pure stat()-time
#       change-detection cache — see the inline comment at its `rm -f` for
#       why its very existence embeds this build's own real, pre-epoch-
#       reset directory timestamps) and `/var/cache/debconf/*.dat-old`
#       (debconf's own crash-recovery backups of files this same build
#       already wrote, read by nothing at runtime).
#   NOT normalized, DOCUMENTED as a known residual risk:
#     - /var/cache/debconf/{config,templates}.dat — debconf's own on-disk
#       database. Content should be a deterministic function of the
#       packages unpacked and the preseed answers given, and issue #22's
#       PERL_HASH_SEED pinning above is a real (if unproven) attempt at
#       fixing its most likely nondeterminism source, but this file still
#       has NOT independently verified byte-for-byte stability of its
#       on-disk record ordering across two independent builds; the two-run
#       CI comparison (SPEC.md R1's own mitigation, now with a precise
#       recursive-diff artifact on failure — see .github/workflows/ci.yml)
#       is what actually proves or disproves this in practice, not this
#       comment.
#     - /etc/ld.so.cache — regenerated deterministically-if-achievable by
#       the explicit final `ldconfig` re-run above, but whether that
#       actually yields byte-identical output across two independent
#       builds depends on whether this Ubuntu release's `ldconfig` sorts
#       its cache entries before writing (a known, Debian-patched fix for
#       exactly this reproducibility class) versus still reflecting raw
#       directory-scan order (which this file's own dev harness cannot
#       verify either way — no `nix` binary, see this file's header).
#       DELIBERATELY NOT DELETED here even though `glibc` falls back to a
#       slower-but-correct path search when the cache is absent (a real,
#       always-available fallback): deleting a file every real Ubuntu
#       install ships is a bigger behavioral step than re-running the tool
#       that already writes it, so this file tries the smaller step first.
#       Loud flag for whoever picks this up next: if the CI determinism
#       diff artifact keeps naming /etc/ld.so.cache after this change,
#       switch to deleting it here instead (that one-line follow-up is the
#       documented fallback, not a mystery to re-derive).
#     - (GitHub issue #48) /.ubx-fakeroot-state — the saved fakeroot
#       ownership/mode database (see this file's own "GitHub issue #48"
#       header section). NORMALIZED here now (issue #22 follow-up), no
#       longer a residual risk: the CI two-run comparison DID flag this
#       file, exactly as the previous version of this note anticipated it
#       might. fakeroot's own raw `-s` save-file is keyed by the real
#       (dev, inode) pairs of every file on THIS build's filesystem, and
#       those inode numbers are allocated by the underlying store
#       filesystem's own free-inode allocator — a function of global fs
#       state, NOT of this build's unpack order — so they differ between
#       any two independent builds (the registered path vs. the
#       `--rebuild` `.check` path). That makes the raw save-file's
#       serialized bytes non-reproducible in BOTH record order AND the
#       key VALUES themselves; sorting record order alone could never fix
#       the differing inode values. The fix (see the "normalize the
#       fakeroot save-file" block at the end of composeRootfs's builder
#       below, and pack.sh's matching reconstruction in squashfsImage):
#       AFTER the fakeroot session has fully exited and written the raw
#       file, rewrite it — from OUTSIDE the chroot — into a deterministic,
#       inode-INDEPENDENT manifest keyed by PATH (`<path>\t<owner/mode
#       tail>`, sorted `LC_ALL=C`), dropping the non-deterministic
#       (dev,inode) key entirely. squashfsImage then RECONSTRUCTS a real,
#       (dev,inode)-keyed fakeroot save-file from that manifest against the
#       store path's OWN actual inodes at pack time and loads THAT via
#       `-i`, so mksquashfs still sees the true owner/mode — and, as a
#       bonus, this no longer depends on Nix having preserved compose's
#       build-time inodes into the registered store path at all (see the
#       "cross-derivation (dev,inode)" note in squashfsImage below).
#     - any maintainer script that embeds genuinely random or
#       machine-specific data into a file it manages (SSH host keys,
#       D-Bus/systemd machine-id generation, ...) is categorically outside
#       what compose-time normalization can fix — SPEC.md §4.2 already
#       treats `machine-id` and friends as machine-local mutable exceptions
#       created at first boot, not baked into the image, for exactly this
#       reason. None of the packages this file's own proofs declare
#       (htop, hello, tzdata) exhibit this, but a future declared package
#       might; the fix belongs to that package's module, not to this
#       generic composition machinery.
{ config, inputs, ... }:
let
  lib = inputs.nixpkgs.lib;

  inherit (config.flake.lib.stdenv) runInUbuntuBase;
  inherit (config.flake.lib.archive) debs;

  # -- renderPreseed --------------------------------------------------------
  #
  # SPEC.md §6's `ubuntnix.debconf` primitive shape:
  #   ubuntnix.debconf."keyboard-configuration" = { "kb/layout" = "us"; };
  # i.e. `{ "<pkg>" = { "<question>" = "<value>"; ...}; ... }`. Flattened
  # here (pure Nix-eval-time string work, no derivations) into simple
  # tab-separated "pkg<TAB>question<TAB>value" records, one per line — NOT
  # yet the 4-field `debconf-set-selections` format (`owner question type
  # value`), because the `type` of a question is only reliably knowable
  # from the package's OWN registered debconf template, which does not
  # exist until that package has actually been unpacked inside the sandbox
  # — see `composeRootfs`'s HARDENING section below for where the
  # 3-field-to-4-field conversion actually happens (at build time, inside
  # the chroot, by reading each package's own
  # /var/lib/dpkg/info/<pkg>.templates).
  #
  # Deliberately conservative about what a "value" may contain: a literal
  # tab or newline would corrupt the one-record-per-line format consumed
  # downstream, so both are rejected outright with a clear eval-time error
  # rather than silently mis-parsed later inside the sandbox.
  renderPreseed = preseed:
    let
      pkgNames = builtins.attrNames preseed;
      renderPkg = pkg:
        let
          questions = builtins.attrNames preseed.${pkg};
          renderQuestion = q:
            let
              v = preseed.${pkg}.${q};
            in
            if !(builtins.isString v) then
              throw ''ubuntnix.debconf."${pkg}"."${q}" must be a string value, got ${builtins.typeOf v}''
            else if lib.hasInfix "\t" v || lib.hasInfix "\n" v then
              throw ''ubuntnix.debconf."${pkg}"."${q}" value must not contain a literal tab or newline''
            else if lib.hasInfix "\t" pkg || lib.hasInfix "\t" q then
              throw ''ubuntnix.debconf package/question names must not contain a literal tab (package "${pkg}", question "${q}")''
            else
              "${pkg}\t${q}\t${v}";
        in
        map renderQuestion questions;
    in
    builtins.concatStringsSep "\n" (builtins.concatMap renderPkg pkgNames);

  # -- composeRootfs --------------------------------------------------------
  #
  # { name, packages, preseed, system } -> a derivation whose $out is a
  # complete, configured Ubuntu rootfs tree: ubuntu-base plus every
  # `packages` entry (looked up in nix/archive.nix's locked `debs`),
  # unpacked and run through dpkg's normal preinst/postinst lifecycle
  # inside a real chroot, with `preseed` (SPEC.md §6 shape) applied via
  # `debconf-set-selections` before configuration.
  #
  # `packages` entries MUST already be present in archive.lock.json (this
  # function does not fetch anything itself — nix/archive.nix owns
  # fetching); an undeclared name fails loudly at eval time rather than
  # producing a confusing missing-attribute error deep inside the build.
  composeRootfs =
    { name
    , packages ? [ ]
    , preseed ? { }
    , system ? "x86_64-linux"
    }:
    let
      missing = builtins.filter (p: !(debs ? ${p})) packages;
      checked =
        if missing == [ ]
        then packages
        else
          throw ''
            compose: package(s) not in the locked archive set (archive.lock.json): ${builtins.concatStringsSep ", " missing}
            -- add them to archive.lock.json (nix/archive.nix) first.'';

      n = builtins.length checked;
      indices = builtins.genList (i: i) n;
      envName = i: "UBX_DEB_${toString i}";
      nameAt = i: builtins.elemAt checked i;

      # Every fetched .deb store path is threaded through as an ENV ATTR
      # (never spliced into the script string) for the exact reason
      # nix/archive.nix's own `archive-fetch-proof` documents: the script
      # text goes through `builtins.toFile` inside `runInUbuntuBase`, which
      # refuses to embed a string carrying derivation-output context.
      debEnv = builtins.listToAttrs (map
        (i: { name = envName i; value = debs.${nameAt i}; })
        indices);

      # One `cp` per staged .deb, run via the loader wrapper (`ubxrun` in
      # the script below, defined before this is spliced in) since this
      # happens BEFORE the hardened chroot exists — `cp` is a dynamically-
      # linked ubuntu-base binary just like everything else pre-chroot
      # (nix/stdenv.nix's BOOTSTRAP CAVEAT). Filenames are index-prefixed,
      # not name-derived, mirroring nix/archive.nix's `DEB_<i>` convention
      # — agnostic to whether a package name is a valid shell/store token.
      # `varRef` is built as a PLAIN Nix string ("$" + envName i, e.g.
      # "$UBX_DEB_0") rather than spliced via `${...}` interpolation of the
      # env-var NAME directly, mirroring nix/archive.nix's `proofLines`
      # exactly — only `env`, above, references the actual derivation
      # outputs; the script text only ever sees the plain shell variable
      # reference.
      debCopyLines = builtins.concatStringsSep "\n" (map
        (i:
          let varRef = "$" + envName i;
          in ''ubxrun "$UBX_BASE/bin/cp" "${varRef}" "$out/.ubx-compose/debs/${toString i}.deb"'')
        indices);

      # unpackLines — R1 determinism (issue #22): the in-chroot
      # `dpkg --unpack` sequence, spelled out explicitly in the SAME order
      # as `checked`/`debCopyLines` above, one absolute-path invocation per
      # declared package, rather than a shell `for deb in
      # /.ubx-compose/debs/*.deb` glob loop. A glob over these
      # index-named files is deterministic for a FIXED set of filenames,
      # but ties unpack order to filesystem/locale glob-matching behavior
      # (and sorts lexically, not numerically, past 9 packages —
      # "10.deb" < "2.deb") for something Nix already knows the intended
      # order of. This is spliced into configure.sh's `UBX_INNER_EOF`
      # heredoc body exactly like `debCopyLines`/`preseedText` are spliced
      # into the outer pre-chroot script — Nix's `${...}` interpolation
      # doesn't care that the surrounding shell text happens to be a
      # quoted heredoc; only the value of this Nix `let` binding matters.
      #
      # `--force-depends` (PR #36, first full-locked-set compose): dpkg
      # enforces Pre-Depends AT UNPACK TIME against whatever is installed
      # at that moment — which, mid-sequence, is a MIXTURE of the
      # ubuntu-base tarball's own package versions and the already-
      # unpacked pinned ones. A strictly-versioned Pre-Depends
      # (e2fsprogs's `Pre-Depends: libext2fs2t64 (= <version>)` was the
      # first real instance: ubuntu-base carries a NEWER point release
      # than the snapshot pin, and 'e' unpacks before 'l' in the pinned
      # order) can therefore fail against the TRANSIENT state even though
      # the FINAL pinned set is perfectly consistent. `--force-depends`
      # is the standard debootstrap idiom for exactly this
      # (debootstrap(8) unpacks its required set the same way):
      # dependency errors at unpack become warnings, while the final
      # tree's consistency is still strictly enforced — `dpkg
      # --configure -a` below runs WITHOUT any force flag, and configures
      # in real dependency order, so a genuinely inconsistent locked set
      # still fails the build there, loudly.
      unpackLines = builtins.concatStringsSep "\n" (map
        (i: ''dpkg --unpack --force-depends "/.ubx-compose/debs/${toString i}.deb"'')
        indices);

      # fakerootTools (GitHub issue #48; see this file's header "GitHub
      # issue #48" section for the full design) -- fakeroot fetched from
      # the locked archive and extracted as a plain build tool via
      # `toolsFHS` (defined below in this same `let`; Nix's laziness makes
      # the forward reference fine), exactly like squashfsImage's own
      # `squashfs-tools`/`liblzo2-2` tools already are. Never added to
      # this rootfs's own `packages` -- nothing about the composed SYSTEM
      # needs fakeroot installed at runtime, only THIS BUILD does.
      # `libfakeroot` is listed EXPLICITLY alongside `fakeroot`: toolsFHS
      # extracts only each named package's own data and runs no maintainer
      # scripts, so it does NOT pull dependencies -- the LD_PRELOAD payload
      # `libfakeroot-*.so` lives in the separate `libfakeroot` deb and would
      # otherwise be missing (CI run 30199370520: `libfakeroot=''`).
      fakerootTools = toolsFHS {
        inherit system;
        name = "fakeroot-${name}";
        packages = [ "fakeroot" "libfakeroot" ];
      };

      preseedText = renderPreseed preseed;
    in
    runInUbuntuBase {
      inherit system;
      name = "rootfs-${name}";
      env = debEnv // {
        # fakerootTools (GitHub issue #48) -- a derivation-output env attr
        # (never spliced directly into `script`, for the same
        # derivation-output-context reason `debEnv` above documents),
        # copied into $out/.ubx-compose below and invoked BY PATH from
        # inside the chroot (see configure.sh's own fakeroot re-exec block
        # further down) -- it needs a real FHS root (chroot) around it,
        # not the raw-loader trick, since fakeroot's own frontend is a
        # shell script that execs further child processes by bare path.
        inherit fakerootTools;
      };
      script = ''
        # ubxrun BIN ARGS... — invoke a dynamically-linked ubuntu-base
        # binary through its own ELF interpreter (nix/stdenv.nix's
        # "BOOTSTRAP CAVEAT": nothing has a real /lib64 yet at this point).
        # EVERY external command below, up until the chroot (see
        # HARDENING), needs this wrapper -- mkdir/cat/chmod/rm/cp are
        # ordinary dynamically-linked ubuntu-base binaries exactly like
        # dpkg-deb/tar/sha256sum were in nix/archive.nix; only bash's OWN
        # builtins (cd, echo, [, ...) are exempt, and none of those alone
        # can create a directory, copy a tree, or change a mode bit.
        ubxrun() {
          "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" "$@"
        }

        ubxrun "$UBX_BASE/bin/mkdir" -p "$out"

        # Deliberately drop ownership on copy: ubuntu-base ships root-owned
        # throughout (nix/stdenv.nix's own note), but preserving that here
        # would make every file's on-disk uid (0) fall OUTSIDE the single
        # uid `unshare --map-root-user` (below) maps into the new user
        # namespace -- files whose numeric owner isn't the mapped uid
        # become inaccessible-as-root inside that namespace (a well-known
        # rootless-container gotcha). Per nix/stdenv.nix's own precedent
        # ("the resulting tree's ownership bits are not meant to be a
        # meaningful part of what's pinned"), ownership bits are not part
        # of what this derivation reproduces: every file under $out ends
        # up owned by whichever uid actually runs this build, which is
        # exactly the uid `--map-root-user` maps to namespace-uid 0, so the
        # whole tree is fully root-accessible inside the chroot below.
        ubxrun "$UBX_BASE/bin/cp" -r --preserve=mode,timestamps,links --no-preserve=ownership \
          "$UBX_BASE/." "$out/"

        # Nix canonicalizes every registered store path read-only: all of
        # $UBX_BASE's directories are mode 0555 on disk, and the
        # `--preserve=mode` copy above faithfully stamps that 0555 onto
        # $out ITSELF -- which the very next (pre-chroot, plain-build-uid)
        # staging steps must still create `.ubx-compose/` inside. Proven
        # by CI run 29785021551: `mkdir: cannot create directory
        # '$out/.ubx-compose': Permission denied`. Restore owner-write on
        # $out's own top-level mode only: everything DEEPER is either
        # written in-chroot by namespace-root (whose CAP_DAC_OVERRIDE
        # covers files owned by the mapped build uid -- i.e. this whole
        # tree) or touched post-chroot as the owning uid (utimensat needs
        # ownership, not write bits). The bit is cosmetic in the final
        # artifact anyway: Nix re-canonicalizes $out read-only at
        # registration, so this cannot introduce nondeterminism.
        ubxrun "$UBX_BASE/bin/chmod" u+w "$out"

        # Stage every declared package's fetched .deb where the chroot
        # below can still reach it -- nothing outside $out is visible after
        # chroot(2), so anything the maintainer scripts need must already
        # be inside $out before that point.
        ubxrun "$UBX_BASE/bin/mkdir" -p "$out/.ubx-compose/debs"
        ${debCopyLines}

        # Stage fakeroot itself (GitHub issue #48; see the `fakerootTools`
        # env attr comment above) -- configure.sh's own fakeroot re-exec
        # block (below) locates `fakeroot`/`faked`/`libfakeroot-*.so`
        # under "/.ubx-compose/fakeroot-tools" from inside the chroot, so
        # the whole tree must exist there before enter.sh's chroot(2)
        # happens.
        ubxrun "$UBX_BASE/bin/mkdir" -p "$out/.ubx-compose/fakeroot-tools"
        ubxrun "$UBX_BASE/bin/cp" -r --preserve=mode,timestamps,links --no-preserve=ownership \
          "$fakerootTools/." "$out/.ubx-compose/fakeroot-tools/"

        # Stage the rendered preseed data (see renderPreseed above):
        # tab-separated "pkg<TAB>question<TAB>value" records. This heredoc
        # embeds plain user-supplied strings only (no derivation-output
        # context), so it is safe inside the outer `builtins.toFile`-backed
        # script text -- see the debEnv comment above for the pattern this
        # would otherwise violate. `cat` here is loader-wrapped like
        # everything else pre-chroot; the redirection/heredoc themselves
        # are pure shell syntax the OUTER (already-running) bash handles
        # directly, so only the `cat` program itself needs `ubxrun`.
        ubxrun "$UBX_BASE/bin/mkdir" -p "$out/.ubx-compose"
        ubxrun "$UBX_BASE/bin/cat" > "$out/.ubx-compose/preseed.txt" <<'UBX_PRESEED_EOF'
        ${preseedText}
        UBX_PRESEED_EOF

        # Write the in-chroot script to a FILE rather than passing it as a
        # quoted argument: the inner script itself needs single quotes
        # (awk programs, POSIX parameter checks) that would otherwise force
        # a third layer of nested quoting (this Nix string's own delimiter,
        # an outer "sh -c '...'", and awk's own '...' program) -- a plain
        # file sidesteps that entirely.
        ubxrun "$UBX_BASE/bin/cat" > "$out/.ubx-compose/configure.sh" <<'UBX_INNER_EOF'
        set -eu
        export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        export DEBIAN_FRONTEND=noninteractive
        export DEBCONF_NONINTERACTIVE_SEEN=true
        export LC_ALL=C LANG=C

        # R1 determinism (issue #22): pin Perl's per-process hash-iteration
        # randomization (perlsec(1); default since Perl 5.18, a
        # hardening measure against algorithmic-complexity attacks, not a
        # correctness feature). Any Perl program below that serializes
        # `keys %hash` without an explicit sort — debconf's own
        # DbDriver::File config/templates writer (`debconf` is in this
        # project's locked archive set) is the leading suspect — can
        # otherwise write differently-ordered records across independent
        # process invocations even given byte-identical input. Exported
        # here, at the top of this whole in-chroot run, so it also covers
        # every maintainer script `dpkg --configure -a` (below) invokes,
        # not just the explicit `debconf-set-selections` call — none of
        # those scripts re-export it themselves. This changes hash
        # ITERATION ORDER only; it can never change what a correct Perl
        # program computes or writes as DATA, only the order in which
        # order-insensitive data (hash keys) comes out.
        export PERL_HASH_SEED=0 PERL_PERTURB_KEYS=0

        # /dev was prepared BEFORE this chroot, by enter.sh (see below):
        # bind mounts of the outer build sandbox's own device nodes onto
        # plain-file mountpoints under $out/dev. mknod is NOT an option
        # here, twice over: namespace-root's CAP_MKNOD does not extend to
        # filesystems whose superblock is owned by the INITIAL user
        # namespace (proven by CI run 29785721098: 'mknod: /dev/null:
        # Operation not permitted'), and even a successful mknod would be
        # fatal later -- Nix refuses to register device nodes in store
        # paths, so only the empty regular-file mountpoints (which the
        # bind mounts cover for the duration of this mount namespace, and
        # a real system's devtmpfs covers at boot) are storable in $out.
        [ -e /dev/null ] || { echo "enter.sh failed to prepare /dev" >&2; exit 1; }

        # GitHub issue #48: re-exec THIS SAME script under fakeroot, once,
        # before dpkg touches anything. `FAKEROOTKEY` is the env var
        # fakeroot's own frontend sets for every process it wraps (and
        # every child THEY fork/exec, since it's inherited normally) -- so
        # checking it here is the standard "have I already been re-exec'd
        # under fakeroot?" idiom, and avoids nesting a second fakeroot
        # session inside the first if this script were ever re-entered.
        # `exec`, not a subshell: replaces this process outright, so
        # everything from here to the end of this script (dpkg --unpack,
        # --configure, and even the ldconfig/cleanup/mtime-reset steps
        # below) runs as ONE continuous fakeroot session -- exactly the
        # single shared session mksquashfs (nix/compose.nix's
        # squashfsImage, below) later needs to load back via `-i` for its
        # own pack-time stat(2) calls to see the same faked owner/mode.
        # `fakeroot`/`faked`/`libfakeroot-*.so`'s exact absolute paths
        # inside the Ubuntu fakeroot package are DISCOVERED here via
        # `find` rather than hardcoded (see this file's header "CI
        # VERIFICATION NOTE" for why: this dev harness has no `fakeroot`
        # binary to inspect directly).
        #
        # We target the CONCRETE `fakeroot-tcp`/`faked-tcp` binaries (with a
        # `-sysv` fallback), not the bare `fakeroot`/`faked` names: on Ubuntu
        # those bare names are update-alternatives symlinks
        # (`/usr/bin/fakeroot -> /etc/alternatives/fakeroot`) wired up by the
        # package's postinst -- which toolsFHS never runs -- so in a raw
        # data-only extraction they are DANGLING symlinks `-type f` skips, and
        # `faked-*` also matches manpages under share/man. Restricting to a
        # `*/bin/*` path excludes the manpages, `-tcp`/`-sysv` pick a concrete
        # frontend, and `-L` on the library lets `-type f` follow any
        # `libfakeroot-*.so -> libfakeroot-0.so` symlink to a real file.
        # (Original fix for CI run 30199370520, where the old bare-name find
        # returned an empty fakeroot path, a manpage for faked, and an empty
        # library path.)
        #
        # WHY TCP, NOT SYSV (CI run on bf1f13a): with the LD_PRELOAD load
        # fixed (readlink + LD_LIBRARY_PATH below), libfakeroot now LOADS
        # everywhere (zero `cannot be preloaded` warnings), yet dpkg STILL
        # EINVAL'd on the first non-root-GID chown -- boot-proof's
        # `error setting ownership of ./usr/sbin/pam_extrausers_chkpwd:
        # Invalid argument` (that file is root:shadow, gid 42). root:root
        # chowns only "succeed" because uid 0 maps to the build uid in the
        # userns; the first non-zero gid reaches the REAL kernel and EINVALs.
        # i.e. libfakeroot was loaded but NOT intercepting chown at all: the
        # `-sysv` frontend/daemon reach each other over SysV IPC message
        # queues, which do not work inside this file's `unshare --user`
        # sandbox, so libfakeroot silently fell through to the real chown.
        # The `-tcp` backend (`faked-tcp` + `libfakeroot-tcp.so`, both already
        # staged by toolsFHS -- no packaging change) talks to the daemon over
        # a localhost socket instead, which the sandbox permits. compose's
        # `-s` save-file and pack's `-i` load-file share one backend-agnostic
        # record format, so a tcp compose still interoperates with a tcp pack.
        # (NB: no adjacent single-quote pair may appear in this comment -- it
        # lives inside a Nix indented-string, where that pair would terminate
        # the string.)
        if [ -z "''${FAKEROOTKEY:-}" ]; then
          ubx_fakeroot_backend=tcp
          ubx_fakeroot_bin="$(find /.ubx-compose/fakeroot-tools -path '*/bin/*' -type f -name 'fakeroot-tcp' | head -n1)"
          ubx_faked_bin="$(find /.ubx-compose/fakeroot-tools -path '*/bin/*' -type f -name 'faked-tcp' | head -n1)"
          ubx_libfakeroot="$(find -L /.ubx-compose/fakeroot-tools -type f -name 'libfakeroot-tcp.so' | head -n1)"
          # Fall back to the sysv backend if the tcp trio is not all present,
          # so we never regress to a hard "not found" (sysv still loads; it
          # just may not fake chown under unshare --user -- the diag below
          # and the post-re-exec self-test will make that visible).
          if [ -z "$ubx_fakeroot_bin" ] || [ -z "$ubx_faked_bin" ] || [ -z "$ubx_libfakeroot" ]; then
            ubx_fakeroot_backend=sysv
            ubx_fakeroot_bin="$(find /.ubx-compose/fakeroot-tools -path '*/bin/*' -type f -name 'fakeroot-sysv' | head -n1)"
            ubx_faked_bin="$(find /.ubx-compose/fakeroot-tools -path '*/bin/*' -type f -name 'faked-sysv' | head -n1)"
            ubx_libfakeroot="$(find -L /.ubx-compose/fakeroot-tools -type f -name 'libfakeroot-sysv.so' | head -n1)"
          fi
          [ -n "$ubx_libfakeroot" ] || ubx_libfakeroot="$(find -L /.ubx-compose/fakeroot-tools -type f -name 'libfakeroot-*.so' | head -n1)"
          if [ -z "$ubx_fakeroot_bin" ] || [ -z "$ubx_faked_bin" ] || [ -z "$ubx_libfakeroot" ]; then
            echo "configure.sh: could not locate fakeroot-tcp/faked-tcp/libfakeroot-tcp.so (nor the -sysv fallback) under /.ubx-compose/fakeroot-tools (backend='$ubx_fakeroot_backend' fakeroot='$ubx_fakeroot_bin' faked='$ubx_faked_bin' libfakeroot='$ubx_libfakeroot')" >&2
            exit 1
          fi

          # GitHub issue #48 -- the LD_PRELOAD actually has to LOAD, or none
          # of the chown/chmod faking happens and dpkg hits EINVAL on the
          # first non-root-owned/setgid file (boot-proof's pam packages:
          # `error setting ownership of pam_extrausers_chkpwd: Invalid
          # argument`). Ubuntu ships `libfakeroot-sysv.so` as a SYMLINK
          # (-> libfakeroot-0.so) in .../libfakeroot/, and `find -L` returns
          # the SYMLINK path; ld.so was reporting `object '<that path>' from
          # LD_PRELOAD cannot be preloaded (cannot open shared object file):
          # ignored` -- i.e. running WITHOUT fakeroot -- in every run so far
          # (the small compose-proof only looked healthy because htop/hello/
          # libnl are all root:root, so nothing needed a faked owner). Two
          # robustness fixes: (1) resolve to the CONCRETE real ELF file with
          # readlink -f and preload THAT absolute regular-file path, so no
          # symlink sits in LD_PRELOAD; (2) put its own directory plus the
          # staged fakeroot lib dirs on LD_LIBRARY_PATH so libfakeroot's own
          # NEEDED deps resolve in every faked child (dpkg-deb's extraction
          # subprocess, which is where the failing chown runs, included).
          ubx_libfakeroot_real="$(readlink -f "$ubx_libfakeroot")"
          [ -n "$ubx_libfakeroot_real" ] && ubx_libfakeroot="$ubx_libfakeroot_real"
          ubx_ft_libdir="$(dirname "$ubx_libfakeroot")"
          export LD_LIBRARY_PATH="$ubx_ft_libdir:/.ubx-compose/fakeroot-tools/usr/lib/x86_64-linux-gnu:/.ubx-compose/fakeroot-tools/lib/x86_64-linux-gnu''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          # THE fix for issue #48 under `unshare --user`: libfakeroot RECORDS
          # the faked ownership to faked-tcp (self-test stat reads back 0:42),
          # but by default it then ALSO performs the real chown/fchownat --
          # and inside this single-id user namespace the target gid (e.g. 42
          # = shadow, for pam_extrausers_chkpwd) is UNMAPPED, so the kernel
          # rejects it at make_kgid with EINVAL (id-validity is checked before
          # any CAP_CHOWN permission check, so dropping caps would not help;
          # and libfakeroot only swallows EPERM, not EINVAL -- Debian bug
          # #802612). FAKEROOTDONTTRYCHOWN=1 (fakeroot >= 1.29; we pin 1.33)
          # tells every libfakeroot chown/lchown/fchown/fchownat wrapper to
          # send_stat the faked owner and then SKIP the real syscall entirely
          # (return 0), so dpkg's fchownat succeeds and the faked db still
          # carries the correct ownership for mksquashfs's -s/-i to apply.
          export FAKEROOTDONTTRYCHOWN=1

          # --- DIAGNOSTIC (issue #48; REMOVE once CI is green) ------------
          # Neither dev harness can run fakeroot/dpkg offline, so make the
          # next CI run self-diagnosing: dump the three discovered paths,
          # whether the libfakeroot file is a symlink and whether its target
          # exists (ls -laL, deref), the lib's own declared dynamic deps
          # (readelf -d NEEDED/RUNPATH -- the smoking gun for a preload that
          # fails on a missing dependency; guarded with `command -v` because
          # readelf may not exist in the chroot -- if absent we skip, never
          # fail, since this whole block runs under `set -eu`), the exact
          # LD_LIBRARY_PATH we just exported, and whether a bare preload of
          # the resolved lib is accepted or still ignored. All to stderr so
          # it lands in the build log regardless of exit status, and every
          # external command is `|| true`-guarded so a missing tool can never
          # abort the build.
          echo "UBX-DIAG(compose): backend        = $ubx_fakeroot_backend" >&2
          echo "UBX-DIAG(compose): fakeroot_bin    = $ubx_fakeroot_bin" >&2
          echo "UBX-DIAG(compose): faked_bin       = $ubx_faked_bin" >&2
          echo "UBX-DIAG(compose): lib(real)       = $ubx_libfakeroot" >&2
          echo "UBX-DIAG(compose): LD_LIBRARY_PATH = $LD_LIBRARY_PATH" >&2
          echo "UBX-DIAG(compose): ls -laL of lib file + its dir:" >&2
          ls -laL "$ubx_libfakeroot" "$ubx_ft_libdir" >&2 || true
          echo "UBX-DIAG(compose): readelf -d of preload lib (if readelf present):" >&2
          if command -v readelf >/dev/null 2>&1; then
            readelf -d "$ubx_libfakeroot" >&2 || true
          else
            echo "UBX-DIAG(compose): readelf not present in chroot, skipping" >&2
          fi
          echo "UBX-DIAG(compose): ldd of preload lib:" >&2
          ldd "$ubx_libfakeroot" >&2 || true
          echo "UBX-DIAG(compose): preload probe (any ld.so warning below => still IGNORED):" >&2
          LD_PRELOAD="$ubx_libfakeroot" /bin/true || true
          echo "UBX-DIAG(compose): preload probe done" >&2
          # --- end DIAGNOSTIC ---------------------------------------------

          # `-s`: save the final faked ownership/mode database to
          # /.ubx-fakeroot-state -- deliberately OUTSIDE /.ubx-compose (a
          # later step in this same script `rm -rf`s that directory) and
          # at $out's own TOP level, so squashfsImage's `rootfs` input
          # still carries it. Excluded from the packed squashfs's actual
          # CONTENT by squashfsImage itself (mirrors how
          # /.ubx-ownership-pseudo.txt used to be excluded).
          exec "$ubx_fakeroot_bin" --lib "$ubx_libfakeroot" --faked "$ubx_faked_bin" \
            -s /.ubx-fakeroot-state -- /bin/sh /.ubx-compose/configure.sh
        fi

        # --- SELF-TEST (issue #48; REMOVE once CI is green) -------------
        # Execution only reaches here on the SECOND entry -- i.e. we are now
        # INSIDE the faked session the FAKEROOTKEY guard above re-exec'd us
        # into. PROVE whether chown faking actually works before dpkg relies
        # on it: fake a root:shadow (gid 42) chown -- the exact ownership
        # pam_extrausers_chkpwd needs, and the first non-zero GID that made
        # dpkg EINVAL on the sysv backend -- on a throwaway probe and read it
        # back. `0:42` => faking works (the tcp daemon is alive and
        # intercepting); a chown error or a stat showing the real gid => the
        # daemon is not intercepting and dpkg will EINVAL again. Everything is
        # `|| true`-guarded so this can never abort the build under `set -eu`.
        echo "UBX-DIAG(compose): fakeroot self-test -- FAKEROOTKEY=''${FAKEROOTKEY:-<unset>}" >&2
        ubx_probe=/.ubx-compose/.ubx-fakeroot-selftest
        : > "$ubx_probe" 2>/dev/null || true
        chown 0:42 "$ubx_probe" 2>&1 | sed 's/^/UBX-DIAG(compose): self-test chown: /' >&2 || true
        echo "UBX-DIAG(compose): self-test stat = $(stat -c '%u:%g' "$ubx_probe" 2>/dev/null || echo '<stat failed>') (expect 0:42 if faking works)" >&2
        rm -f "$ubx_probe" 2>/dev/null || true
        # --- end SELF-TEST ----------------------------------------------

        # A fresh /proc for THIS pid namespace -- several maintainer
        # scripts (ldconfig, update-alternatives, adduser, ...) read it.
        mount -t proc proc /proc

        # dpkg --unpack every declared package FIRST (this registers each
        # package's *.templates under /var/lib/dpkg/info/, and runs
        # preinst) BEFORE preseeding: debconf-set-selections needs a
        # question's Type, and the only place that is reliably known is
        # the template the package itself just registered. This mirrors
        # the standard debootstrap/provisioning idiom: unpack everything,
        # seed debconf, THEN configure everything.
        #
        # R1 determinism (issue #22): this is an EXPLICIT, Nix-generated
        # list of `dpkg --unpack` invocations (`unpackLines`, defined
        # alongside `debCopyLines` above), in exactly the order `packages`
        # was declared — not a `for deb in *.deb` shell glob. dpkg appends
        # each newly-unpacked package's stanza to /var/lib/dpkg/status (and
        # creates /var/lib/dpkg/info/<pkg>.*) in unpack order, so pinning
        # this order also pins those files' content, independent of
        # whatever filesystem/locale glob-matching behavior would
        # otherwise apply.
        #
        # GitHub issue #48: dpkg unpacks every declared package NORMALLY
        # now -- no scan, no --path-exclude, no separate content-restore
        # pass. Every chown(2)/chmod(2) dpkg's own tarobject() attempts
        # (including a non-root owner, EINVAL under this chroot's
        # single-id-mapped user namespace; and a setuid/setgid/sticky bit,
        # EPERM -- see this file's header for the concrete CI failures
        # that used to require the retired scan/restore interim) is
        # transparently faked-successful by the fakeroot session this
        # script re-exec'd itself into above -- dpkg itself neither knows
        # nor cares that it isn't really running as a privileged root.
        ${unpackLines}

        # Expand the 3-field preseed records into debconf-set-selections'
        # required 4-field form ("owner question type value") by looking
        # up each question's Type from the template file dpkg --unpack
        # just registered; default to "string" for a question with no
        # known template (debconf itself falls back the same way when
        # asked to store an answer for an unregistered question).
        # `grep [^[:space:]]`, not `[ -s ]`: the staging heredoc writes a
        # trailing newline even for an EMPTY preseed set (proven by CI run
        # 29785981711: that lone blank line became a degenerate
        # "<TAB>string<TAB>" record debconf-set-selections rejects with
        # "parse error on line 1"), and awk skips any other blank line for
        # the same reason.
        if grep -q '[^[:space:]]' /.ubx-compose/preseed.txt; then
          awk -F'\t' '
            BEGIN { OFS = "\t" }
            /^[[:space:]]*$/ { next }
            {
              pkg = $1; q = $2; v = $3
              type = "string"
              tf = "/var/lib/dpkg/info/" pkg ".templates"
              found = 0
              while ((getline line < tf) > 0) {
                if (line == "Template: " q) { found = 1; continue }
                if (found && index(line, "Type: ") == 1) {
                  type = substr(line, 7); break
                }
                if (found && line == "") { found = 0 }
              }
              close(tf)
              print pkg, q, type, v
            }
          ' /.ubx-compose/preseed.txt > /.ubx-compose/preseed.selections
          debconf-set-selections /.ubx-compose/preseed.selections
        fi

        # GitHub issue #48 follow-on -- setuid maintainer-script helpers.
        # Some postinsts (e.g. dhcpcd-base -> adduser) exec the setuid helper
        # `chfn` (and `chsh`) to set a system user's GECOS/shell. A setuid
        # binary cannot be exec'd under this fakeroot + single-id
        # `unshare --user` sandbox -- the kernel returns EACCES on the execve
        # -- so `dpkg --configure -a` aborts in that postinst (CI:
        # `Cannot exec /bin/chfn: Permission denied`, dhcpcd-base postinst
        # exit 82). Neutralize just those two helpers to /bin/true for the
        # configure pass, then restore the real binaries so the SHIPPED image
        # is unchanged: a system user's GECOS/shell is cosmetic, and the mv
        # back preserves each file's inode so its faked root:root ownership
        # (recorded in the fakeroot db by dev/inode) still applies. Fully
        # self-contained -- touches no dpkg state and is reversed before the
        # rootfs is packed, so R1 determinism is preserved.
        ubx_setuid_saved=/.ubx-compose/.setuid-helpers-saved
        mkdir -p "$ubx_setuid_saved"
        for ubx_h in chfn chsh; do
          if [ -f "/usr/bin/$ubx_h" ] && [ ! -L "/usr/bin/$ubx_h" ]; then
            mv "/usr/bin/$ubx_h" "$ubx_setuid_saved/$ubx_h"
            ln -s /bin/true "/usr/bin/$ubx_h"
          fi
        done

        dpkg --configure -a

        for ubx_h in chfn chsh; do
          if [ -e "$ubx_setuid_saved/$ubx_h" ]; then
            rm -f "/usr/bin/$ubx_h"
            mv "$ubx_setuid_saved/$ubx_h" "/usr/bin/$ubx_h"
          fi
        done
        rm -rf "$ubx_setuid_saved"

        # R1 determinism (issue #22): canonical final `ldconfig`
        # regeneration. libc6's own postinst/triggers already invoke
        # ldconfig automatically, one or more times, as part of
        # `dpkg --configure -a` above; an extra, explicit, LAST invocation
        # here collapses that into one canonical run over the fully-
        # configured tree's final library set — the closest this file can
        # get to a reproducible /etc/ld.so.cache without reimplementing
        # ldconfig's own cache-writing logic. Unconditionally SAFE (cannot
        # change composed-system behavior): ldconfig is explicitly designed
        # to be re-run at any time and is idempotent over a fixed library
        # set. It is a best-EFFORT fix, not a proof — see this file's
        # header "NOT normalized" note on /etc/ld.so.cache for the
        # documented fallback (delete it) if the two-run CI comparison
        # still flags this file afterward.
        ldconfig

        # R1 determinism (issue #22): ldconfig's OWN change-detection cache
        # (distinct from /etc/ld.so.cache above) — a pure performance
        # optimization recording the mtime/inode metadata ldconfig observed
        # on its library search-path directories, consulted only to decide
        # whether a FUTURE ldconfig run can skip rescanning them. Its
        # content is therefore literally a transcript of THIS build's own
        # real (pre-epoch-reset) directory stat() results — exactly the
        # kind of build-specific data R1 targets — and it carries no
        # configuration-relevant information: deleting it just means the
        # next ldconfig invocation (at first real boot, or an admin's) does
        # one full rescan instead of a skip, which is what every fresh
        # Ubuntu install already does anyway (the cache doesn't exist until
        # ldconfig has run once). `-f`: present or not depending on exactly
        # which triggers ran above.
        rm -f /var/cache/ldconfig/aux-cache

        # R1 determinism (issue #22): debconf's OWN backup copies of
        # config.dat/templates.dat (written before debconf overwrites the
        # live file, for crash recovery) — pure backups of a database this
        # same build just wrote moments earlier, read by nothing at
        # runtime. The live *.dat files themselves are NOT touched here —
        # see this file's header "NOT normalized" note for why (accepted
        # residual risk, mitigated but not proven by the PERL_HASH_SEED
        # pin above).
        rm -f /var/cache/debconf/*.dat-old

        # Compose-time staging is not part of the composed system.
        rm -rf /.ubx-compose

        # R1 normalization (see this file's header): dpkg's own action log
        # is a literal timestamp transcript of this build.
        rm -f /var/log/dpkg.log /var/log/dpkg.log.*

        # R1 mtime normalization, IN-CHROOT by necessity: `find -exec
        # touch` spawns touch as a child by absolute path, which outside
        # this chroot dies on the missing /lib64 ELF interpreter (the
        # BOOTSTRAP CAVEAT; proven by CI run 29786396413's
        # "find: '.../usr/bin/touch': No such file or directory" from the
        # previous, post-chroot placement of this step). In here every
        # child exec resolves against this rootfs's own real loader. The
        # /dev bind mounts and /proc must be unmounted FIRST (dev binds
        # before /proc -- umount needs /proc/self/mountinfo to look
        # mounts up) so touch reaches the underlying regular mountpoint
        # files rather than the outer sandbox's (unmapped-owner, EPERM)
        # device nodes, and so no live mount's mtime leaks into the
        # comparison. `-h`: touch symlinks themselves, never their
        # targets. Nothing after this point may redirect to /dev/null --
        # its bind mount is gone.
        for d in null zero full random urandom tty; do
          umount "/dev/$d" || true
        done
        umount /proc
        find / -exec touch -h -d @0 {} +
        UBX_INNER_EOF
        ubxrun "$UBX_BASE/bin/chmod" +x "$out/.ubx-compose/configure.sh"

        # enter.sh -- runs INSIDE the fresh user+mount+pid namespaces but
        # BEFORE chroot(2): the only vantage point that can still see BOTH
        # the outer build sandbox's /dev (bind-mount sources) and $out
        # (bind-mount targets). Namespace-root's CAP_SYS_ADMIN covers
        # `mount --bind` within its own private mount namespace; the
        # mounts live exactly as long as that namespace and never reach
        # the registered store path -- only the empty regular-file
        # mountpoints do (see the /dev note inside configure.sh above for
        # why bind mounts, not mknod). The touch creating each mountpoint
        # runs as namespace-root too, so CAP_DAC_OVERRIDE (over this
        # mapped-uid-owned tree) lets it write into the store-canonical
        # 0555 dev/ directory. Env note: $out and the UBX_* variables are
        # ordinary builder environment variables, inherited across
        # unshare, so this quoted heredoc leaves them for ENTER.SH's own
        # runtime to expand. `exec` must spell the loader invocation out
        # literally -- exec cannot target a shell function.
        ubxrun "$UBX_BASE/bin/cat" > "$out/.ubx-compose/enter.sh" <<'UBX_ENTER_EOF'
        set -eu
        ubxrun() {
          "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" "$@"
        }
        for d in null zero full random urandom tty; do
          [ -e "$out/dev/$d" ] || ubxrun "$UBX_BASE/usr/bin/touch" "$out/dev/$d"
          ubxrun "$UBX_BASE/usr/bin/mount" --bind "/dev/$d" "$out/dev/$d"
        done
        exec "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" "$UBX_BASE/usr/sbin/chroot" "$out" \
          /bin/sh /.ubx-compose/configure.sh
        UBX_ENTER_EOF
        ubxrun "$UBX_BASE/bin/chmod" +x "$out/.ubx-compose/enter.sh"

        # -- HARDENING (issue #9; follow-up to nix/stdenv.nix's HARDENING
        # NOTE) -----------------------------------------------------------
        #
        # Everything above ran with the raw-loader trick (`ubxrun`, i.e.
        # no real /lib64) because it only needed to read some inputs and
        # write into $out. Maintainer scripts are a different story: they
        # are arbitrary Debian shell/perl code that assumes a normal FHS
        # root (exec other binaries by bare name, source
        # /usr/share/debconf/confmodule by absolute path, etc.) -- so from
        # here on they run inside a REAL `chroot($out)`, not the
        # raw-loader shim.
        #
        # `unshare --user --map-root-user` creates a fresh user namespace
        # where the CALLING (unprivileged, per-derivation Nix build) uid
        # is mapped to namespace-uid 0 -- exactly the "user namespaces are
        # available in the Nix sandbox" mechanism this issue's design
        # guidance calls for. That namespace-root grants CAP_SYS_CHROOT
        # (for chroot(2) itself) and CAP_SYS_ADMIN (for `mount -t proc`
        # above) WITHIN THIS BUILD'S OWN NAMESPACES ONLY -- no host
        # privilege is needed or granted. `--mount` gives chroot(2) a
        # private mount namespace (mounting /proc inside $out cannot leak
        # into, or outlive, this one build). `--pid --fork` gives the
        # chrooted process tree its own PID namespace (so the freshly
        # mounted /proc reports THIS tree's processes, matching what a
        # maintainer script expects of a normal system).
        #
        # CI VERIFICATION NOTE: this is the first time anything in this
        # project nests a user namespace inside Nix's own build sandbox.
        # The PM's design guidance for this issue states user namespaces
        # are available in the Nix sandbox on CI's ubuntu-24.04 runners and
        # locally; this repository's own dev harness cannot exercise
        # `unshare --user` at all (no `nix` binary, and this exact
        # invocation fails with "Operation not permitted" when tried
        # directly in that harness — most likely a seccomp/AppArmor
        # restriction specific to that sandboxed environment, not
        # necessarily present on a GitHub Actions ubuntu-24.04 runner or a
        # real dev machine). If CI's first run of `.#compose-proof`
        # surfaces an unshare/user-namespace permission error, that is
        # this exact assumption failing in practice and needs a follow-up
        # fix here (a `sudo`-backed alternative, or CI runner
        # configuration) -- mirroring how nix/stdenv.nix's own bootstrap
        # took several real CI iterations to get right (see that file's
        # "BOOTSTRAP CAVEAT" and its git-blame for the CI run numbers).
        #
        # The `unshare`/`bash enter.sh`/`chroot` chain itself still needs
        # `ubxrun`-style loader wrapping (all dynamically-linked
        # ubuntu-base binaries, invoked BEFORE the chroot happens; enter.sh
        # bind-mounts /dev in between -- see its staging comment above) --
        # but `/.ubx-compose/configure.sh`
        # runs AFTER chroot(2) has already repointed the process's root at
        # $out, so ITS dynamic loader lookups (/lib64/ld-linux-...)
        # resolve inside $out's own copy of ubuntu-base, same as a real
        # Ubuntu system. Nothing inside configure.sh needs `ubxrun`/
        # `$UBX_LD` at all -- that is the entire point of this hardening
        # step, and the concrete difference from nix/stdenv.nix's raw-
        # loader approach.
        ubxrun "$UBX_BASE/usr/bin/unshare" --user --map-root-user --mount --pid --fork -- \
          "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" "$UBX_BASE/bin/bash" \
          "$out/.ubx-compose/enter.sh"

        # Compose-time staging is not part of the composed system (the
        # chrooted script above already removes it from ITS OWN view of
        # $out, i.e. from $out itself, but remove again here defensively
        # in case that step was ever skipped/failed partway).
        ubxrun "$UBX_BASE/bin/rm" -rf "$out/.ubx-compose"

        # GitHub issue #48: /.ubx-fakeroot-state (the saved fakeroot
        # ownership/mode database configure.sh's fakeroot re-exec wrote
        # via `-s`) is only WRITTEN at that fakeroot session's own final
        # process exit -- which happens when the `unshare ... enter.sh`
        # invocation above returns, i.e. AFTER configure.sh's own in-chroot
        # epoch mtime-reset pass (`find / -exec touch -h -d @0 {} +`) has
        # already run. It would otherwise be the one file under $out whose
        # mtime still carries this build's real wall-clock time --
        # asserted to actually exist (a missing state file means the
        # fakeroot session never completed, a real build failure worth
        # catching loudly here rather than downstream in squashfsImage)
        # and explicitly epoch-touched here, from OUTSIDE the chroot, to
        # close that one gap.
        [ -f "$out/.ubx-fakeroot-state" ] || {
          echo "composeRootfs: $out/.ubx-fakeroot-state is missing -- the fakeroot session never saved its state" >&2
          exit 1
        }

        # GitHub issue #48 / issue #22 R1 determinism: NORMALIZE the raw
        # fakeroot save-file into a deterministic, inode-INDEPENDENT
        # manifest. See this file's header "NOT normalized -> NORMALIZED"
        # note for the full rationale; in short: fakeroot's own `-s` output
        # keys every record by the real (dev, inode) pair of the file on
        # THIS build's store filesystem, and those inode numbers are
        # allocated non-deterministically per build (the store fs's own
        # free-inode allocator, not our unpack order), so the raw file's
        # bytes differ across two independent builds and fail CI's strict R1
        # `--rebuild` check -- in the key VALUES themselves, not merely
        # record order, so a plain sort could never fix it.
        #
        # This runs from OUTSIDE the chroot, AFTER the fakeroot session has
        # fully exited (the `unshare ... enter.sh` above returned, which is
        # what makes fakeroot flush its `-s` save-file), and BEFORE the
        # epoch mtime-touch just below -- exactly the one vantage point that
        # sees the completed raw file. Every tool here is a dynamically-
        # linked ubuntu-base binary invoked through the loader wrapper
        # (`ubxrun`), same BOOTSTRAP CAVEAT as everything else pre-chroot;
        # scratch files go in the builder's cwd (a writable Nix build temp
        # dir, NOT $out), so they never enter the registered store path.
        #
        # The rewrite: for every file in the tree, join its real inode to
        # the raw record with that inode, and emit `<relative path>\t<the
        # record's owner/mode tail>` -- i.e. drop the leading
        # `dev=..,ino=..,` (the ONLY non-deterministic part) and keep
        # fakeroot's OWN verbatim `mode=..,uid=..,gid=..,nlink=..,rdev=..`
        # text (so we never have to re-serialize those fields ourselves).
        # Sorted `LC_ALL=C` by path -> byte-identical across builds given
        # the same (already pinned) tree. squashfsImage's pack.sh rebuilds
        # a real (dev,inode)-keyed fakeroot save-file from this manifest
        # against the store path's own actual inodes -- see its own comment.
        ubxrun "$UBX_BASE/bin/cat" > ubx-fakeroot-normalize.awk <<'UBX_NORMALIZE_AWK'
        # Args: <raw fakeroot save-file> <find "%i\t%P" output>. Emits
        # `<path>\t<owner/mode tail>` for each tree file whose real inode
        # has a raw record. Raw record shape (fakeroot-sysv, stable for
        # 15+ years): dev=<hex>,ino=<dec>,mode=<oct>,uid=<dec>,gid=<dec>,
        # nlink=<dec>,rdev=<hex> -- dev and ino are ALWAYS the first two
        # fields, which is all this transform relies on (any extra trailing
        # fields a future fakeroot adds are preserved verbatim in the tail).
        BEGIN { FS = "\t" }
        FNR == NR {
          line = $0
          if (line !~ /^dev=[^,]+,ino=[0-9]+,/) next
          ino = line; sub(/^dev=[^,]+,ino=/, "", ino); sub(/,.*/, "", ino)
          tail = line; sub(/^dev=[^,]+,ino=[^,]+,/, "", tail)
          rec[ino] = tail
          next
        }
        { ino = $1; path = $2; if (path != "" && (ino in rec)) print path "\t" rec[ino] }
        UBX_NORMALIZE_AWK

        # Locate the CONCRETE awk binary, not the bare `/usr/bin/awk` name:
        # that is an update-alternatives symlink to the ABSOLUTE path
        # `/etc/alternatives/awk`, which -- exactly like the `fakeroot`/
        # `faked` alternatives symlinks this file's own fakeroot-discovery
        # block documents -- does NOT resolve out here PRE-chroot (there is
        # no real `/etc/alternatives` root yet; that only works once chroot
        # repoints `/`). `find`/`sort`/`wc`/`touch` used here are ordinary
        # coreutils/findutils REGULAR files, so they need no such discovery;
        # only awk does. `read` is a bash builtin (no child exec), so no
        # loader wrapping and no pipe (which would fork a bare-name child).
        ubxrun "$UBX_BASE/usr/bin/find" "$UBX_BASE" -path '*/bin/*' -type f \( -name mawk -o -name gawk -o -name original-awk \) > ubx-awk-path
        read -r ubx_awk < ubx-awk-path || true
        [ -n "$ubx_awk" ] || {
          echo "composeRootfs: could not locate a concrete awk (mawk/gawk) under $UBX_BASE to normalize the fakeroot save-file" >&2
          exit 1
        }

        # `%P` = path relative to the start point (no leading slash), so the
        # manifest's keys match pack.sh's own `find /mnt/rootfs -printf %P`.
        # Prune the save-file itself (its own inode is never in the db --
        # fakeroot writes `-s` at session exit, after all stats -- but prune
        # keeps the intent explicit and the manifest self-consistent).
        ubxrun "$UBX_BASE/usr/bin/find" "$out" -path "$out/.ubx-fakeroot-state" -prune -o -printf '%i\t%P\n' > ubx-fakeroot-inos
        ubxrun "$ubx_awk" -f ubx-fakeroot-normalize.awk "$out/.ubx-fakeroot-state" ubx-fakeroot-inos > ubx-fakeroot-manifest
        # Export (not a var-prefix on the ubxrun function -- that would not
        # reliably reach `sort`'s own environment) so the byte-exact record
        # ordering is locale-independent; C collation is what makes the
        # sorted manifest reproducible across machines/runners.
        export LC_ALL=C
        ubxrun "$UBX_BASE/usr/bin/sort" ubx-fakeroot-manifest > "$out/.ubx-fakeroot-state"

        # Loud guard: a real dpkg unpack chmod/chown-touches (hence records)
        # hundreds of files, so an EMPTY manifest here means the find/awk
        # join silently produced nothing (a bug worth catching now rather
        # than as a silently-wrong squashfs later -- compose-image-proof
        # only checks the image's magic, not its ownership fidelity).
        ubx_manifest_n="$(ubxrun "$UBX_BASE/usr/bin/wc" -l < "$out/.ubx-fakeroot-state")"
        [ "$ubx_manifest_n" -gt 0 ] || {
          echo "composeRootfs: normalized fakeroot manifest is empty -- the inode/path join produced no records (raw save-file present but nothing correlated)" >&2
          exit 1
        }
        ubxrun "$UBX_BASE/bin/rm" -f ubx-fakeroot-normalize.awk ubx-fakeroot-inos ubx-fakeroot-manifest ubx-awk-path

        ubxrun "$UBX_BASE/usr/bin/touch" -h -d @0 "$out/.ubx-fakeroot-state"

        # R1 mtime normalization (reset every mtime to the Unix epoch so
        # two independent builds are directly comparable with `diff -r`)
        # happens at the END of configure.sh, inside the chroot -- see the
        # comment there for why it cannot run out here (find -exec's child
        # touch cannot exec without a real /lib64).
      '';
    };

  # -- toolsFHS ---------------------------------------------------------
  #
  # Unpacks one or more archive-locked packages' DATA (not just control,
  # unlike nix/archive.nix's archive-fetch-proof) into a single merged FHS
  # tree, WITHOUT running any maintainer scripts -- this is for pure
  # library/binary tools consumed by the *build system itself* (the
  # squashfs image step below), not for composing a system. Uses the same
  # `--fsys-tarfile | tar -x` pattern nix/archive.nix's control-extraction
  # already established (`dpkg-deb -x`/`--extract` spawns `tar` as a child
  # by bare name, which per the BOOTSTRAP CAVEAT dies outside a chroot;
  # `--fsys-tarfile` streams the tarball via libdpkg with no child exec, so
  # WE can extract it ourselves through the loader).
  toolsFHS =
    { name, packages, system ? "x86_64-linux" }:
    let
      missing = builtins.filter (p: !(debs ? ${p})) packages;
      checked =
        if missing == [ ]
        then packages
        else throw "toolsFHS: package(s) not in the locked archive set: ${builtins.concatStringsSep ", " missing}";
      n = builtins.length checked;
      indices = builtins.genList (i: i) n;
      envName = i: "UBX_TOOL_${toString i}";
      nameAt = i: builtins.elemAt checked i;
      env = builtins.listToAttrs (map (i: { name = envName i; value = debs.${nameAt i}; }) indices);
      # `varRef` as a plain Nix string, not a `${...}` splice of the env
      # var name — see composeRootfs's `debCopyLines` comment for why.
      extractLines = builtins.concatStringsSep "\n" (map
        (i:
          let varRef = "$" + envName i;
          in ''
            ubxrun "$UBX_BASE/usr/bin/dpkg-deb" --fsys-tarfile "${varRef}" \
              | ubxrun "$UBX_BASE/usr/bin/tar" -xf - -C "$out"
          '')
        indices);
    in
    runInUbuntuBase {
      inherit system env;
      name = "toolsfhs-${name}";
      script = ''
        ubxrun() { "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" "$@"; }
        ubxrun "$UBX_BASE/bin/mkdir" -p "$out"
        ${extractLines}
      '';
    };

  # -- squashfsImage --------------------------------------------------------
  #
  # { name, rootfs, system } -> $out/rootfs.squashfs, a read-only squashfs
  # image of an already-composed rootfs tree (typically a `composeRootfs`
  # output), built with `mksquashfs` sourced from the locked Ubuntu archive
  # (archive.lock.json's `squashfs-tools` + `liblzo2-2` entries -- see that
  # file's own comments for why exactly these two and not more).
  #
  # GitHub issue #48: mksquashfs runs under fakeroot with the owner/mode
  # database composeRootfs's own build produced at `rootfs`'s own
  # "/.ubx-fakeroot-state" -- loading it via `-i` is what lets mksquashfs's
  # own stat(2) calls transparently see each path's TRUE owner/mode, with
  # no pseudo-file (mksquashfs -pf) pass or scan step at all (fully
  # retiring the scan-based interim's mechanism). NB (issue #22 R1
  # determinism): that
  # state file is no longer a raw fakeroot save-file but a deterministic,
  # inode-INDEPENDENT path-keyed manifest (fakeroot's raw (dev,inode)-keyed
  # form is inherently non-reproducible across builds -- see this file's
  # header note); pack.sh reconstructs a real (dev,inode)-keyed save-file
  # from it against /mnt/rootfs's actual inodes right before the `-i` load
  # (see its own comment for exactly how and why that is also MORE robust
  # than loading composeRootfs's build-time inodes ever was).
  #
  # fakeroot's own frontend is a shell script that execs further child
  # processes (faked, then the wrapped command) by bare/absolute path, so
  # -- exactly like composeRootfs's maintainer scripts -- it needs a REAL
  # FHS root (chroot), not the raw-loader trick every OTHER step in this
  # file uses. `rootfs` and `tools` (mksquashfs's own store path) are both
  # read-only Nix inputs by the time this derivation runs, so neither can
  # be chrooted into directly (no writable mountpoint could be created
  # inside either) -- a fresh, writable copy of $UBX_BASE is used as the
  # chroot root instead, mirroring composeRootfs's OWN "cp $UBX_BASE,
  # chmod u+w, chroot" pattern exactly, with `rootfs`/`tools` bind-mounted
  # in read-only and the produced image copied back out afterward.
  #
  # CI VERIFICATION NOTE (mirrors composeRootfs's own note on `unshare
  # --user`): this is a NEW use of that same hardening pattern, one level
  # further removed from what issue #9's original CI runs actually
  # exercised -- if CI's first real build of this surfaces a mount/chroot
  # permission error here, that is this exact extension failing in
  # practice and needs a follow-up fix, not a mystery.
  squashfsImage =
    { name, rootfs, system ? "x86_64-linux" }:
    let
      tools = toolsFHS {
        inherit system;
        name = "squashfs-${name}";
        # `libfakeroot` explicit for the same reason fakerootTools lists it
        # (toolsFHS pulls no deps; the LD_PRELOAD payload is a separate deb).
        packages = [ "squashfs-tools" "liblzo2-2" "fakeroot" "libfakeroot" ];
      };
    in
    runInUbuntuBase {
      inherit system;
      name = "image-${name}";
      env = { inherit rootfs tools; };
      script = ''
        ubxrun() { "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" "$@"; }
        ubxrun "$UBX_BASE/bin/mkdir" -p "$out"

        # A fresh, writable FHS scratch tree to chroot into -- see this
        # binding's own header comment above for why $rootfs/$tools
        # (both read-only store paths by now) cannot be chrooted into
        # directly. Ownership dropped on copy for the identical reason
        # composeRootfs's own copy of $UBX_BASE does (see that
        # derivation's "Deliberately drop ownership on copy" comment).
        ubxrun "$UBX_BASE/bin/mkdir" -p "$out/.ubx-pack"
        ubxrun "$UBX_BASE/bin/cp" -r --preserve=mode,timestamps,links --no-preserve=ownership \
          "$UBX_BASE/." "$out/.ubx-pack/"
        ubxrun "$UBX_BASE/bin/chmod" u+w "$out/.ubx-pack"

        # Unlike composeRootfs's fresh `.ubx-compose` (a name not present in
        # ubuntu-base), `.ubx-pack` is populated by literally copying
        # $UBX_BASE's own tree above -- and ubuntu-base ships a real `/mnt`
        # directory, so the `--preserve=mode` copy stamps its canonical 0555
        # onto `$out/.ubx-pack/mnt` too. The `chmod u+w` just above only
        # reaches `.ubx-pack` itself, not that nested `mnt`, so the mount
        # points created next still land inside a read-only directory.
        # Proven by CI run 30199686173: `mkdir: cannot create directory
        # '.../.ubx-pack/mnt/rootfs': Permission denied` (and same for
        # `tools`/`out`). Same 0555-preserved-copy failure mode composeRootfs
        # documents above for `$out` itself -- restore owner-write here too.
        ubxrun "$UBX_BASE/bin/chmod" u+w "$out/.ubx-pack/mnt"
        ubxrun "$UBX_BASE/bin/mkdir" -p "$out/.ubx-pack/mnt/rootfs" "$out/.ubx-pack/mnt/tools" "$out/.ubx-pack/mnt/out"

        # pack.sh -- runs INSIDE the chroot, same "write to a file, not a
        # quoted argument" reasoning composeRootfs's own configure.sh
        # comment documents (nested quoting from find's own `\(...\)`
        # test expression, here).
        ubxrun "$UBX_BASE/bin/cat" > "$out/.ubx-pack/pack.sh" <<'UBX_PACK_EOF'
        set -eu
        # Mirrors configure.sh's own PATH export above: a chroot inherits
        # whatever PATH the outer builder happened to have (no nix-store
        # paths exist inside this chroot at all), so bare-name lookups
        # below (find, head, ...) resolve against an effectively empty
        # PATH unless one is set explicitly here. Fix for CI run
        # 30199884603: "/pack.sh: 26: find: not found" / "head: not found".
        export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        # squashfs-tools' own runtime deps (liblz4-1, liblzma5, libzstd1,
        # zlib1g) are already inside ubuntu-base; only liblzo2-2 (and
        # fakeroot's own small dep set) live under /mnt/tools instead --
        # both its lib dirs go on LD_LIBRARY_PATH, which a REAL chroot's
        # dynamic linker honors normally (no --library-path CLI trick
        # needed here, unlike the raw pre-chroot ubxrun steps elsewhere in
        # this file -- see nix/stdenv.nix's BOOTSTRAP CAVEAT for why that
        # trick exists at all). BOTH $tools lib dirs are listed: a deb's
        # data tar may address the merged-/usr layout from either side
        # (liblzo2-2 ships './lib/x86_64-linux-gnu/liblzo2.so.2', counting
        # on a usrmerge symlink toolsFHS's flat extraction doesn't have --
        # see composeRootfs's sibling comment, CI run 29786592587, for the
        # original proof of this).
        export LD_LIBRARY_PATH="/mnt/tools/usr/lib/x86_64-linux-gnu:/mnt/tools/lib/x86_64-linux-gnu"

        [ -f /mnt/rootfs/.ubx-fakeroot-state ] || {
          echo "pack.sh: /mnt/rootfs/.ubx-fakeroot-state is missing -- composeRootfs did not save fakeroot state for this rootfs" >&2
          exit 1
        }

        # Same "discover, don't hardcode" reasoning -- and the same tcp-first
        # / sysv-fallback backend choice, `*/bin/*`/`-L` handling of the
        # alternatives symlinks, manpages, and library symlink -- as
        # composeRootfs's own fakeroot re-exec block above; see its comment
        # (WHY TCP, NOT SYSV) for the full rationale. mksquashfs runs here as
        # a CLIENT of a faked session too, so it must reach a working daemon;
        # under this file's userns sandbox that means the tcp backend, and
        # pack must use the SAME backend compose's `-s` save-file was written
        # by (both tcp).
        ubx_fakeroot_backend=tcp
        ubx_fakeroot_bin="$(find /mnt/tools -path '*/bin/*' -type f -name 'fakeroot-tcp' | head -n1)"
        ubx_faked_bin="$(find /mnt/tools -path '*/bin/*' -type f -name 'faked-tcp' | head -n1)"
        ubx_libfakeroot="$(find -L /mnt/tools -type f -name 'libfakeroot-tcp.so' | head -n1)"
        if [ -z "$ubx_fakeroot_bin" ] || [ -z "$ubx_faked_bin" ] || [ -z "$ubx_libfakeroot" ]; then
          ubx_fakeroot_backend=sysv
          ubx_fakeroot_bin="$(find /mnt/tools -path '*/bin/*' -type f -name 'fakeroot-sysv' | head -n1)"
          ubx_faked_bin="$(find /mnt/tools -path '*/bin/*' -type f -name 'faked-sysv' | head -n1)"
          ubx_libfakeroot="$(find -L /mnt/tools -type f -name 'libfakeroot-sysv.so' | head -n1)"
        fi
        [ -n "$ubx_libfakeroot" ] || ubx_libfakeroot="$(find -L /mnt/tools -type f -name 'libfakeroot-*.so' | head -n1)"
        if [ -z "$ubx_fakeroot_bin" ] || [ -z "$ubx_faked_bin" ] || [ -z "$ubx_libfakeroot" ]; then
          echo "pack.sh: could not locate fakeroot-tcp/faked-tcp/libfakeroot-tcp.so (nor the -sysv fallback) under /mnt/tools (backend='$ubx_fakeroot_backend' fakeroot='$ubx_fakeroot_bin' faked='$ubx_faked_bin' libfakeroot='$ubx_libfakeroot')" >&2
          exit 1
        fi

        # GitHub issue #48 -- same LD_PRELOAD-must-actually-load fix as
        # composeRootfs's fakeroot re-exec block (see its comment): resolve
        # the sysv .so SYMLINK to the concrete real ELF file and preload
        # THAT, and add its own directory to LD_LIBRARY_PATH (the base
        # /mnt/tools lib dirs are already there, from the export above, for
        # mksquashfs's liblzo2 -- but libfakeroot lives in a `libfakeroot/`
        # SUBDIR of those, which is not otherwise searched). If mksquashfs
        # runs without fakeroot faking stat(2), every path is captured with
        # its Nix-canonicalized owner/mode instead of the composed one.
        ubx_libfakeroot_real="$(readlink -f "$ubx_libfakeroot")"
        [ -n "$ubx_libfakeroot_real" ] && ubx_libfakeroot="$ubx_libfakeroot_real"
        export LD_LIBRARY_PATH="$(dirname "$ubx_libfakeroot")''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        # Same issue #48 fix as composeRootfs's block (see its FAKEROOTDONTTRYCHOWN
        # comment): skip the real chown/fchownat under the single-id userns so
        # mksquashfs's faked session never EINVALs on an unmapped gid while the
        # faked ownership db it reads via -i stays correct.
        export FAKEROOTDONTTRYCHOWN=1

        # --- DIAGNOSTIC (issue #48; REMOVE once CI is green) ------------
        # Mirrors composeRootfs's own fakeroot-diag block (see it for the
        # rationale + the `command -v readelf` / `|| true` robustness notes).
        echo "UBX-DIAG(pack): backend        = $ubx_fakeroot_backend" >&2
        echo "UBX-DIAG(pack): fakeroot_bin    = $ubx_fakeroot_bin" >&2
        echo "UBX-DIAG(pack): faked_bin       = $ubx_faked_bin" >&2
        echo "UBX-DIAG(pack): lib(real)       = $ubx_libfakeroot" >&2
        echo "UBX-DIAG(pack): LD_LIBRARY_PATH = $LD_LIBRARY_PATH" >&2
        echo "UBX-DIAG(pack): ls -laL of lib file + its dir:" >&2
        ls -laL "$ubx_libfakeroot" "$(dirname "$ubx_libfakeroot")" >&2 || true
        echo "UBX-DIAG(pack): readelf -d of preload lib (if readelf present):" >&2
        if command -v readelf >/dev/null 2>&1; then
          readelf -d "$ubx_libfakeroot" >&2 || true
        else
          echo "UBX-DIAG(pack): readelf not present in chroot, skipping" >&2
        fi
        echo "UBX-DIAG(pack): ldd of preload lib:" >&2
        ldd "$ubx_libfakeroot" >&2 || true
        echo "UBX-DIAG(pack): preload probe (any ld.so warning below => IGNORED):" >&2
        LD_PRELOAD="$ubx_libfakeroot" /bin/true || true
        echo "UBX-DIAG(pack): preload probe done" >&2
        # --- end DIAGNOSTIC ---------------------------------------------

        # GitHub issue #48 / issue #22 R1 determinism -- cross-derivation
        # (dev,inode) reconstruction. `/mnt/rootfs/.ubx-fakeroot-state` is
        # NOT a raw fakeroot save-file anymore: composeRootfs normalized it
        # into a deterministic, inode-INDEPENDENT manifest
        # (`<path>\t<mode=..,uid=..,gid=..,nlink=..,rdev=..>`, one line per
        # composed file that fakeroot recorded, sorted LC_ALL=C -- see that
        # builder's own "normalize the fakeroot save-file" block for why the
        # raw inode-keyed form could never be made reproducible).
        #
        # fakeroot's `-i` load matches a record to a file STRICTLY by the
        # real (st_dev, st_ino) the caller's own lstat(2) returns; the
        # save-file format carries no path. So we rebuild a genuine
        # (dev,inode)-keyed save-file HERE, against the inodes /mnt/rootfs
        # ACTUALLY has at pack time: `find` reports each file's device
        # (%D, decimal) and inode (%i) and path (%P), and awk re-prepends
        # `dev=<hex>,ino=<dec>,` (the exact fakeroot-sysv key syntax) onto
        # the manifest's verbatim owner/mode tail. This is strictly more
        # robust than loading composeRootfs's own build-time inodes would
        # have been: it depends on NOTHING about whether Nix preserved those
        # inodes into the registered store path (store optimise/hardlinking,
        # or any copy, would have silently broken a raw-save-file `-i` here).
        find /mnt/rootfs -path /mnt/rootfs/.ubx-fakeroot-state -prune -o -printf '%D\t%i\t%P\n' > /mnt/out/.ubx-fakeroot-inos
        awk -F'\t' '
          FNR == NR { rec[$1] = $2; next }
          { dev = $1; ino = $2; path = $3; if (path in rec) printf "dev=%x,ino=%s,%s\n", dev, ino, rec[path] }
        ' /mnt/rootfs/.ubx-fakeroot-state /mnt/out/.ubx-fakeroot-inos > /mnt/out/.ubx-fakeroot-realdb

        # Loud guard: every manifest path came FROM this very store tree at
        # compose time, so all of them must still resolve here -- a mismatch
        # means the reconstruction dropped records (a silently-wrong image
        # otherwise, since compose-image-proof checks only the squashfs
        # magic, not ownership).
        manifest_n=$(wc -l < /mnt/rootfs/.ubx-fakeroot-state)
        realdb_n=$(wc -l < /mnt/out/.ubx-fakeroot-realdb)
        [ "$manifest_n" = "$realdb_n" ] || {
          echo "pack.sh: reconstructed $realdb_n of $manifest_n fakeroot records -- manifest path/inode mismatch against /mnt/rootfs" >&2
          exit 1
        }

        # `-i`: load the reconstructed real (dev,inode)-keyed database, so
        # mksquashfs's OWN stat(2) calls against every path under
        # /mnt/rootfs transparently see the TRUE owner/mode -- no -pf, no
        # pseudo-file manifest. `.ubx-fakeroot-state` (and the scratch
        # `.ubx-fakeroot-{inos,realdb}` under /mnt/out, which never enter
        # the image anyway) is excluded from the packed image's content --
        # it is composeRootfs's own bookkeeping, not part of the real
        # Ubuntu system /mnt/rootfs otherwise represents.
        "$ubx_fakeroot_bin" --lib "$ubx_libfakeroot" --faked "$ubx_faked_bin" \
          -i /mnt/out/.ubx-fakeroot-realdb -- \
          /mnt/tools/usr/bin/mksquashfs /mnt/rootfs /mnt/out/rootfs.squashfs \
          -mkfs-time 0 -all-time 0 -no-progress -processors 1 \
          -e .ubx-fakeroot-state
        UBX_PACK_EOF
        ubxrun "$UBX_BASE/bin/chmod" +x "$out/.ubx-pack/pack.sh"

        # enter.sh -- bind-mounts rootfs/tools into the scratch tree, then
        # chroots and runs pack.sh. Mirrors composeRootfs's OWN enter.sh
        # exactly (same unshare/map-root-user/chroot pattern). No explicit
        # `-o ro` on the bind mounts (a plain `mount --bind` does not
        # honor `-o ro` in one step -- it needs a second `mount -o
        # remount,ro,bind`, which is unverified to succeed inside this
        # nested user+mount namespace): $rootfs/$tools are already
        # read-only Nix store paths in practice regardless of the bind
        # mount's own flag, and nothing pack.sh runs writes to either
        # mountpoint. /mnt/out needs no bind mount at all -- it is already
        # a plain writable directory inside this same copied, writable
        # scratch tree.
        ubxrun "$UBX_BASE/bin/cat" > "$out/.ubx-pack/enter.sh" <<'UBX_PACK_ENTER_EOF'
        set -eu
        ubxrun() { "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" "$@"; }
        ubxrun "$UBX_BASE/usr/bin/mount" --bind "$rootfs" "$out/.ubx-pack/mnt/rootfs"
        ubxrun "$UBX_BASE/usr/bin/mount" --bind "$tools" "$out/.ubx-pack/mnt/tools"
        exec "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" "$UBX_BASE/usr/sbin/chroot" "$out/.ubx-pack" \
          /bin/sh /pack.sh
        UBX_PACK_ENTER_EOF
        ubxrun "$UBX_BASE/bin/chmod" +x "$out/.ubx-pack/enter.sh"

        ubxrun "$UBX_BASE/usr/bin/unshare" --user --map-root-user --mount --pid --fork -- \
          "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" "$UBX_BASE/bin/bash" \
          "$out/.ubx-pack/enter.sh"

        ubxrun "$UBX_BASE/bin/cp" "$out/.ubx-pack/mnt/out/rootfs.squashfs" "$out/rootfs.squashfs"
        # The `.ubx-pack` scratch tree is a copy of ubuntu-base, so it carries
        # ubuntu's own restrictive directory modes (e.g. dpkg info/, var/cache,
        # var/log entries whose containing dirs lack owner-write). `rm -rf` then
        # fails `Permission denied` removing their contents (CI run
        # 30199980867). The earlier `chmod u+w .../mnt` fix only covered the
        # nested mount points; generalize it to the whole tree right before the
        # delete. This is safe: the /mnt/rootfs and /mnt/tools bind mounts lived
        # only inside enter.sh's `unshare --mount` namespace and have already
        # vanished with it, so this chmod (and the rm) touch only the local
        # writable copy, never the read-only Nix store rootfs/tools. Capital `X`
        # restores search/traverse on directories so the recursion can descend.
        ubxrun "$UBX_BASE/bin/chmod" -R u+rwX "$out/.ubx-pack"
        ubxrun "$UBX_BASE/bin/rm" -rf "$out/.ubx-pack"
      '';
    };
in
{
  flake.lib.compose = { inherit renderPreseed composeRootfs toolsFHS squashfsImage; };

  systems = [ "x86_64-linux" ];

  perSystem = { system, ... }:
    let
      # compose-proof (issue #9 task item 1): a small rootfs built from
      # ubuntu-base plus two already-locked packages (htop, hello) with no
      # preseed. Neither ships a preinst/postinst (verified against the
      # actual fetched .debs), so this proof's job is narrower than
      # compose-preseed-proof's: it demonstrates the compose MECHANISM
      # itself — dpkg --unpack/--configure completing successfully inside
      # the hardened chroot and leaving a self-consistent dpkg database
      # ("install ok installed" for both, not stuck half-installed/
      # unpacked) — while compose-preseed-proof (below) is what proves an
      # actual maintainer SCRIPT ran (tzdata's postinst has real logic).
      # Together they cover both signals the issue's CI guidance calls
      # for: "dpkg database consistent" and "a package's postinst effect
      # present".
      composeProof = composeRootfs {
        inherit system;
        name = "compose-proof";
        # htop's libnl dependencies must be composed IN-SET: composeRootfs
        # stages exactly the named debs (dependency closure is the
        # lockfile's/#20's job, not composition's), and CI run 29786182993
        # proved dpkg --configure correctly refuses a dependency-incomplete
        # set (htop left unconfigured without libnl-3-200/-genl-3-200 --
        # its only dependencies not already inside ubuntu-base). That
        # refusal is composition working as intended: the fix is a
        # complete declared set, not a weaker proof.
        packages = [ "htop" "hello" "libnl-3-200" "libnl-genl-3-200" ];
      };

      # compose-preseed-proof (issue #9 task item 2): tzdata's postinst
      # writes /etc/timezone and symlinks /etc/localtime purely from the
      # debconf answers tzdata/Areas + tzdata/Zones/<Area> (see
      # archive.lock.json's tzdata entry for why it was chosen: minimal
      # deps, well-known preseed idiom). "America/New_York" is NOT
      # tzdata's own built-in Etc/UTC fallback, so a match here could only
      # come from the preseed actually reaching the maintainer script.
      composePreseedProof = composeRootfs {
        inherit system;
        name = "compose-preseed-proof";
        packages = [ "tzdata" ];
        preseed = {
          tzdata = {
            "tzdata/Areas" = "America";
            "tzdata/Zones/America" = "New_York";
          };
        };
      };

      # compose-image-proof (issue #9 task item 3): the read-only image
      # artifact, built from compose-proof's already-composed tree.
      composeImageProof = squashfsImage {
        inherit system;
        name = "compose-proof";
        rootfs = composeProof;
      };
    in
    {
      packages.compose-proof = composeProof;
      packages.compose-preseed-proof = composePreseedProof;
      packages.compose-image-proof = composeImageProof;
    };
}
