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
      unpackLines = builtins.concatStringsSep "\n" (map
        (i: ''dpkg --unpack "/.ubx-compose/debs/${toString i}.deb"'')
        indices);

      preseedText = renderPreseed preseed;
    in
    runInUbuntuBase {
      inherit system;
      name = "rootfs-${name}";
      env = debEnv;
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

        dpkg --configure -a

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
  # (archive.lock.json's `squashfs-tools` + `liblzo2-2` entries, added by
  # this issue -- see that file's own comments for why exactly these two
  # and not more). No maintainer scripts run here, so no chroot is needed
  # for this step -- mksquashfs just reads `rootfs` as a plain input tree.
  squashfsImage =
    { name, rootfs, system ? "x86_64-linux" }:
    let
      tools = toolsFHS { inherit system; name = "squashfs-${name}"; packages = [ "squashfs-tools" "liblzo2-2" ]; };
    in
    runInUbuntuBase {
      inherit system;
      name = "image-${name}";
      env = { inherit rootfs tools; };
      script = ''
        ubxrun() { "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" "$@"; }
        ubxrun "$UBX_BASE/bin/mkdir" -p "$out"
        # squashfs-tools' own runtime deps (liblz4-1, liblzma5, libzstd1,
        # zlib1g) are already inside ubuntu-base (see archive.lock.json's
        # comment on the squashfs-tools entry); only liblzo2-2 lives in
        # `tools` instead -- both directories are on one combined
        # --library-path. BOTH $tools lib dirs must be listed: a deb's
        # data tar may address the merged-/usr layout from either side
        # (liblzo2-2 ships './lib/x86_64-linux-gnu/liblzo2.so.2',
        # counting on the usrmerge symlink a real root has -- toolsFHS's
        # flat extraction has no such symlink, proven by CI run
        # 29786592587: mksquashfs failed to load liblzo2.so.2 with only
        # the usr/lib path on the search path).
        "$UBX_LD" --library-path "$UBX_LIBRARY_PATH:$tools/usr/lib/x86_64-linux-gnu:$tools/lib/x86_64-linux-gnu" \
          "$tools/usr/bin/mksquashfs" "$rootfs" "$out/rootfs.squashfs" \
          -mkfs-time 0 -all-time 0 -no-progress -processors 1
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
