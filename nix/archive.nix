# nix/archive.nix — the archive lockfile schema + snapshot-pinned deb
# fetching (SPEC.md §4.4; GitHub issue #7, milestone M1).
#
# SPEC.md §4.4's reproducibility model pins the deb universe two-tier:
#   - **public pockets** (archive.ubuntu.com / security.ubuntu.com): a
#     snapshot.ubuntu.com timestamp plus resolved (package, version, sha256)
#     tuples. Snapshots are retained upstream "at least 2 years", so the
#     hash + retained artifact is the durable trust root; the timestamp only
#     drives *resolution* against the snapshot service.
#   - **esm pockets** (esm.ubuntu.com): no snapshot service exists for
#     these (research outcome, R4), so they're pinned directly by (package,
#     version, sha256) and fetched at build/rebuild time with the machine's
#     or CI's own Ubuntu Pro token — that lands at milestone M4. This file
#     declares the tier's shape now (so the lockfile format doesn't need to
#     change shape later) but the `esm` tier is INTENTIONALLY EMPTY: there
#     is no fetching logic for it here, on purpose. Do not "helpfully" wire
#     it up before M4 lands the Pro-token plumbing (SPEC.md §8.2).
#
# -- The lockfile -------------------------------------------------------
#
# ../archive.lock.json (repo root, not under nix/) is the pinned data:
# plain JSON rather than a .nix file so it's readable both by
# `builtins.fromJSON` here AND by ordinary tooling/tests that have no `nix`
# binary (this harness itself is one such consumer — see
# tests/unit/040-archive-lockfile.sh, which validates its shape with
# python3's json module alone). Its schema:
#
#   {
#     "version": 1,                        # lockfile format version
#     "public": {
#       "snapshot": "20260715T000000Z",    # snapshot.ubuntu.com timestamp
#       "series": "noble",
#       "packages": [
#         { "name": ..., "version": ..., "arch": "amd64",
#           "component": "main", "path": "pool/main/...deb",
#           "sha256": <64 hex>, "size": <bytes> },
#         ...
#       ]
#     },
#     "esm": { "packages": [] }            # M4; empty by design until then
#   }
#
# Every `sha256` in the committed lockfile was independently verified by
# downloading the referenced .deb from snapshot.ubuntu.com and hashing the
# bytes locally with python3's hashlib — the snapshot service's own
# Packages index is corroborating evidence, not the trust root; the
# locally-recomputed digest is what was recorded (mirrors nix/stdenv.nix's
# "Trust root" methodology for the ubuntu-base tarball). `validate` (below)
# additionally asserts this schema in Nix itself, `throw`ing loudly on any
# violation; tests/unit/040-archive-lockfile.sh is the harness-side
# complement (python3, since this dev environment has no `nix` binary to
# exercise `validate` against directly — that's CI-only).
#
# -- The fetcher: <nix/fetchurl.nix>, not builtins.fetchurl -------------
#
# nix/stdenv.nix uses `builtins.fetchurl` for its ONE trust-root fetch (the
# ubuntu-base tarball) — a Nix language primop that fetches eagerly *at
# evaluation time*. That's fine for one fetch everything else in this
# project's build graph depends on regardless, but it's the wrong shape
# here: this lockfile is expected to grow to the project's full declared
# deb closure, and forcing every pinned .deb to be fetched merely by
# running `nix flake check`/`flake show` (eval-only operations) would be
# both slow and needless network I/O for debs nothing actually asked to
# build yet.
#
# `<nix/fetchurl.nix>` is Nix's OTHER built-in fetcher: a `.nix` expression
# shipped inside Nix itself, resolved through the "nix" entry Nix always
# adds to its expression search path — a hardcoded entry compiled into the
# `nix` binary pointing at Nix's own data directory, unrelated to a
# user-supplied `NIX_PATH` env var or any nixpkgs channel, which is why it
# remains reachable under flakes' pure evaluation even though ordinary
# `<...>` lookups sourced from `NIX_PATH` are not. Unlike
# `builtins.fetchurl`, importing it just returns an ordinary derivation —
# nothing is fetched until something actually builds it, functionally
# equivalent to the package-set fetcher this project is forbidden from
# using (SPEC.md §1.3/§3), except reimplemented as a Nix-internal
# primitive instead of a nixpkgs-authored one. Its accepted arguments:
# `url`, `sha256` (hex digest — the documented shorthand this file uses,
# mirroring nix/stdenv.nix's own pin style; there is also a lower-level
# `outputHash`/`outputHashAlgo` pair it accepts but does not need here),
# and `name` (defaults to the url's basename; set explicitly below via
# `sanitizeStoreName` since Nix store names are restricted to
# `[A-Za-z0-9+._?=-]` and nothing guarantees every future pool-path
# basename stays inside that set). See tests/unit/021-flake-purity.sh's
# narrow carve-out for this exact `<nix/fetchurl.nix>` spelling (only that
# one exact spelling is exempted; any package-set-qualified or bare/
# unqualified spelling of the same word still trips the purity guard) and
# tests/unit/041-archive-flake-wiring.sh for the static checks that keep
# this file's wiring honest without a `nix` binary to actually evaluate it
# here.
#
# -- What this file does NOT do ------------------------------------------
#
# It only fetches the fixed-output .deb artifacts and proves it can. Actual
# rootfs composition — unpacking debs, running maintainer scripts inside
# the ubuntu-native stdenv sandbox (SPEC.md §4.1, issue #6) — belongs to a
# different M1 issue, not this one.
{ config, ... }:
let
  # The Ubuntu-native stdenv's builder abstraction (nix/stdenv.nix), read
  # from the TOP-LEVEL module scope (this `{ config, ... }:` function head,
  # NOT `perSystem`'s own `config` argument, which is a different,
  # per-system-scoped value) — `config.flake.lib` is the merged `flake.lib`
  # attrset every dendritic file contributes to (the option is declared
  # once, in nix/lib.nix); dendritic files may freely read each other's
  # contributions this way, with the module system's laziness resolving
  # the fixpoint.
  inherit (config.flake.lib.stdenv) runInUbuntuBase;

  # ../archive.lock.json — see this file's header for the schema.
  rawLockfile = builtins.fromJSON (builtins.readFile ../archive.lock.json);

  # validate — asserts the schema documented above and `throw`s a single
  # message enumerating EVERY violation found (not just the first) on any
  # mismatch, so a broken archive.lock.json fails Nix evaluation loudly
  # rather than surfacing as an obscure attribute-missing error deep
  # inside `fetchDeb`/`debs`. `lockfile` below is `validate rawLockfile`,
  # so merely evaluating `flake.lib.archive.lockfile` (or anything derived
  # from it) exercises this check; also exposed directly under
  # `flake.lib.archive.validate` so a future `ubx update` can run the same
  # check against a candidate lockfile before writing it. This harness has
  # no `nix` binary to run this against directly (see tests/unit/021's
  # header for the same caveat) — tests/unit/041-archive-flake-wiring.sh
  # statically confirms this function exists and can actually fail (greps
  # for a real `throw`); tests/unit/040-archive-lockfile.sh is the
  # harness-side schema guard (python3), enforcing the identical shape.
  # CI's "flake" job is what actually evaluates this for real.
  validate = lf:
    let
      sha256Re = "[0-9a-f]{64}";
      snapshotRe = "[0-9]{8}T[0-9]{6}Z";
      requiredPublicFields = [ "name" "version" "arch" "component" "path" "sha256" "size" ];
      requiredEsmFields = [ "name" "version" "sha256" ];

      hasPublicPackages = lf ? public && lf.public ? packages && builtins.isList lf.public.packages;
      hasEsmPackages = lf ? esm && lf.esm ? packages && builtins.isList lf.esm.packages;

      checkPkg = label: requiredFields: pkg:
        let
          missing = builtins.filter (f: !(pkg ? ${f})) requiredFields;
          hasAll = missing == [ ];
          sha256Ok = !hasAll || (builtins.isString pkg.sha256 && builtins.match sha256Re pkg.sha256 != null);
          sizeOk = !(pkg ? size) || (builtins.isInt pkg.size && pkg.size > 0);
          pathOk = !(pkg ? path) || (builtins.isString pkg.path && builtins.match ".*[.]deb" pkg.path != null);
        in
        (if hasAll then [ ] else [ "${label} missing required field(s): ${builtins.concatStringsSep ", " missing}" ])
        ++ (if hasAll && !sha256Ok then [ "${label} has a malformed sha256 (want 64 lowercase hex chars): ${toString pkg.sha256}" ] else [ ])
        ++ (if sizeOk then [ ] else [ "${label} has an invalid size (want a positive integer): ${toString (pkg.size or null)}" ])
        ++ (if pathOk then [ ] else [ "${label} path does not end in .deb: ${toString (pkg.path or null)}" ]);

      errors =
        (if lf ? version && lf.version == 1 then [ ] else [ "version must be 1, got ${toString (lf.version or null)}" ])
        ++ (if lf ? public && lf.public ? snapshot && builtins.isString lf.public.snapshot && builtins.match snapshotRe lf.public.snapshot != null
        then [ ]
        else [ "public.snapshot must match ${snapshotRe} (e.g. 20260715T000000Z), got ${toString (lf.public.snapshot or null)}" ])
        ++ (if hasPublicPackages then [ ] else [ "public.packages is missing or not a list" ])
        ++ (if hasPublicPackages && lf.public.packages == [ ] then [ "public.packages must not be empty" ] else [ ])
        ++ (if hasEsmPackages then [ ] else [ "esm.packages is missing or not a list (the tier must exist, even empty, per SPEC.md §4.4)" ])
        ++ (if hasPublicPackages then builtins.concatLists (map (checkPkg "public package" requiredPublicFields) lf.public.packages) else [ ])
        ++ (if hasEsmPackages then builtins.concatLists (map (checkPkg "esm package" requiredEsmFields) lf.esm.packages) else [ ]);
    in
    if errors == [ ]
    then lf
    else
      throw ''
        archive.lock.json failed schema validation (SPEC.md §4.4):
        ${builtins.concatStringsSep "\n" (map (e: "  - ${e}") errors)}'';

  lockfile = validate rawLockfile;

  # The snapshot-pinned base URL every public-tier package is fetched
  # under (SPEC.md §4.4): https://snapshot.ubuntu.com/ubuntu/<timestamp>/.
  snapshotUrl = "https://snapshot.ubuntu.com/ubuntu/${lockfile.public.snapshot}";

  # A pool path's basename (e.g. "htop_3.3.0-4build1_amd64.deb") is
  # already a valid Nix store name for every entry in the committed
  # lockfile (Debian's own filename convention excludes the epoch prefix
  # that can appear in a package's Version field — e.g. zlib1g's
  # "1:1.3.dfsg-..." Version has no colon in its .deb filename) — but
  # store names are restricted to `[A-Za-z0-9+._?=-]`, and neither the
  # lockfile schema nor the snapshot service's own path shape *guarantees*
  # every future entry stays inside that set (historic archive layouts
  # have used `%3a`-style percent escapes for epochs in directory
  # components, and `~` shows up in Debian pre-release version strings
  # that occasionally leak into filenames). `builtins.replaceStrings` is a
  # Nix language primitive (no nixpkgs involved) that defensively maps the
  # handful of characters known to be both plausible-in-a-filename and
  # illegal-in-a-store-name onto `_`, so a future lockfile entry with one
  # of those can't produce an eval-time "invalid store path name" error.
  sanitizeStoreName = s: builtins.replaceStrings [ ":" "%" "~" ] [ "_" "_" "_" ] s;

  # fetchDeb — one pinned public-tier lockfile entry -> a fixed-output
  # derivation of the fetched .deb bytes, verified against its pinned
  # sha256 by Nix itself at build time (this is what
  # archive-hash-mismatch-proof, below, deliberately breaks). `entry` is
  # shaped like one element of `lockfile.public.packages`.
  fetchDeb = entry:
    import <nix/fetchurl.nix> {
      url = "${snapshotUrl}/${entry.path}";
      sha256 = entry.sha256;
      name = sanitizeStoreName (baseNameOf entry.path);
    };

  # name -> fetched-deb derivation, for every PUBLIC-tier lockfile entry.
  # (Not the esm tier — see this file's header; there is nothing to fetch
  # there yet, by design, until M4.)
  debs = builtins.listToAttrs (map
    (entry: {
      name = entry.name;
      value = fetchDeb entry;
    })
    lockfile.public.packages);
in
{
  # Exposed under flake.lib (option declared once, in nix/lib.nix; every
  # dendritic file just contributes its own named attribute — same pattern
  # nix/stdenv.nix uses for flake.lib.stdenv and nix/ubx.nix for
  # flake.lib.ubx).
  flake.lib.archive = { inherit lockfile validate snapshotUrl fetchDeb debs; };

  systems = [ "x86_64-linux" ];

  perSystem = { system, ... }: {
    # archive-fetch-proof (issue #7 task item 3): depends on EVERY pinned
    # public-tier deb (forcing Nix to actually fetch-and-verify each one
    # against its pinned sha256) and writes a deterministic manifest of
    # what it found: a fixed marker, the pinned snapshot timestamp/series,
    # one line per deb with its name/version/filename plus a sha256sum
    # RECOMPUTED INSIDE THE SANDBOX (not just Nix's own fixed-output
    # verification — an independent proof the bytes are what they claim to
    # be), and the first fetched deb's extracted control file (proving the
    # ubuntu-native stdenv can actually parse a real fetched archive, not
    # just move bytes around). Deterministic by construction — every
    # input (the fetched store paths, the lockfile data) is itself
    # deterministic, so there is nothing timestamp- or host-dependent to
    # leak into $out.
    #
    # Built via runInUbuntuBase (nix/stdenv.nix). `sha256sum` and
    # `dpkg-deb` are dynamically-linked ubuntu-base binaries, so — per
    # nix/stdenv.nix's own "BOOTSTRAP CAVEAT" — they're invoked through the
    # documented loader pattern, `"$UBX_LD" --library-path
    # "$UBX_LIBRARY_PATH" "$UBX_BASE/usr/bin/<bin>" <args>`, rather than by
    # bare name.
    # SANDBOXING NOTE: `runInUbuntuBase`'s OWN builder derivation runs
    # fully sandboxed (nix/stdenv.nix: "unlike `unpacked` above, this
    # derivation runs fully sandboxed" — it is NOT the `__noChroot` one).
    # But `archive-fetch-proof` still transitively NEEDS relaxed
    # sandboxing to build at all: `runInUbuntuBase` sets its `builder`
    # attribute to `ubuntuBase.unpacked`'s own `ld-linux` binary path, so
    # `ubuntuBase.unpacked` — the ONE `__noChroot = true` derivation in
    # this whole project (nix/stdenv.nix's "Bootstrap" comment) — becomes
    # a build dependency of every `runInUbuntuBase` derivation, this one
    # included (doubly so here, since this script also directly execs
    # ubuntu-base's own `sha256sum`/`dpkg-deb`). Nix must build that
    # dependency before it can build this derivation, and building it
    # requires the same `--option sandbox relaxed` flag `.#stdenv-proof`
    # needed — so CI's build step for this proof passes it too, exactly
    # like the stdenv-proof step (see .github/workflows/ci.yml).
    # `archive-hash-mismatch-proof` below, by contrast, calls
    # `<nix/fetchurl.nix>` directly with no `runInUbuntuBase` involved at
    # all, so it has no such dependency and needs no relaxed sandboxing.
    #
    # Each deb's store path is threaded through as an ENV ATTR
    # (`env.DEB_<i>`), never spliced directly into the `script` string:
    # `runInUbuntuBase` passes `script` through `builtins.toFile`, which
    # (per nix/stdenv.nix's own "NOTE" comment on this exact constraint)
    # refuses to embed a string carrying derivation-output context — only
    # derivation ENV ATTRS may reference another derivation's output.
    # Indexed names (`DEB_0`, `DEB_1`, ...) rather than name-derived ones
    # keep this agnostic to whether a future package name is even a valid
    # shell identifier.
    packages.archive-fetch-proof =
      let
        entries = lockfile.public.packages;
        n = builtins.length entries;
        indices = builtins.genList (i: i) n;
        entryAt = i: builtins.elemAt entries i;
        envName = i: "DEB_${toString i}";

        env = builtins.listToAttrs (map
          (i: { name = envName i; value = debs.${(entryAt i).name}; })
          indices);

        proofLines = builtins.concatStringsSep "\n" (map
          (i:
            let
              entry = entryAt i;
              # A plain Nix string ("$DEB_0", ...) — not a derivation
              # reference — so splicing it into `script` below carries no
              # forbidden string context; only `env`, above, references
              # the actual derivation outputs.
              varRef = "$" + envName i;
            in
            # Per nix/stdenv.nix's BOOTSTRAP CAVEAT, dynamically-linked
            # ubuntu-base binaries may only be invoked through the
            # "$UBX_LD" loader pattern — a bare `basename`/`cut` here
            # fails with "cannot execute: required file not found" (CI
            # run 29742349438 caught exactly that). Rather than paying
            # two more loader invocations, both are replaced with bash
            # parameter expansion (`''${var##*/}`, `''${var%% *}`) —
            # shell builtins are explicitly unaffected by the caveat.
            ''
              {
                debpath="${varRef}"
                echo "deb name=${entry.name} version=${entry.version} store=${varRef}"
                echo "deb filename=''${debpath##*/}"
                sumline=$("$UBX_LD" --library-path "$UBX_LIBRARY_PATH" \
                  "$UBX_BASE/usr/bin/sha256sum" "${varRef}")
                echo "deb sha256sum=''${sumline%% *}"
              } >> "$out"'')
          indices);

        # Parsing just the FIRST fetched deb is enough to prove the
        # ubuntu-native stdenv can handle a real fetched archive (issue #7
        # task item 3); doing it for every deb would be pure repetition of
        # the same proof.
        #
        # Why `--ctrl-tarfile | tar -xOf - ./control` and not the obvious
        # `dpkg-deb --info`: `--info` makes dpkg-deb SPAWN `tar` itself
        # (execvp by bare name), and per nix/stdenv.nix's BOOTSTRAP CAVEAT
        # a dynamically-linked ubuntu-base binary exec'd by bare name dies
        # in the sandbox on its missing ELF interpreter — dpkg-deb's child
        # exec is out of our reach, so no loader pattern can save it (CI
        # run 29742475984: "unable to execute tar"). `--ctrl-tarfile`
        # instead decompresses the control tarball INTERNALLY (libdpkg, no
        # child processes) and streams it to stdout; we then run `tar`
        # ourselves — through the loader, as the caveat requires — to
        # extract ./control. Net effect is stronger, not weaker: both
        # dpkg-deb (real .deb ar/zstd parsing) and tar (real tarball
        # extraction) demonstrably work on a fetched archive, and the
        # extracted control file provides the `Package:` line CI asserts.
        firstVarRef = "$" + envName 0;
        firstEntry = entryAt 0;
      in
      runInUbuntuBase {
        inherit system env;
        name = "archive-fetch-proof";
        script = ''
          {
            echo "MARKER=ubuntnix-archive-fetch-proof-v1"
            echo "snapshot=${lockfile.public.snapshot}"
            echo "series=${lockfile.public.series}"
          } > "$out"
          ${proofLines}
          {
            echo "== control (${firstEntry.name}) =="
            "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" \
              "$UBX_BASE/usr/bin/dpkg-deb" --ctrl-tarfile "${firstVarRef}" \
              | "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" \
                "$UBX_BASE/usr/bin/tar" -xOf - ./control
          } >> "$out"
        '';
      };

    # archive-hash-mismatch-proof (issue #7 task item 3, negative case).
    #
    # !!! DELIBERATELY BROKEN — DO NOT "FIX" THIS !!!
    #
    # Fetches a REAL pinned deb's URL but with an intentionally WRONG
    # sha256 (64 zeros, which no real content will ever hash to). This
    # derivation MUST FAIL to build with Nix's own "hash mismatch in
    # fixed-output derivation" error — that failure is the entire point:
    # CI's "flake" job (.github/workflows/ci.yml) asserts the build FAILS
    # and that its output contains "hash mismatch", as the negative-path
    # proof that a corrupted/tampered/wrong-pin .deb is rejected rather
    # than silently accepted. If this ever builds successfully, the hash
    # verification this whole lockfile design depends on has silently
    # broken — that is a regression to fix in the fetcher, not in this
    # derivation.
    packages.archive-hash-mismatch-proof =
      let
        entry = builtins.elemAt lockfile.public.packages 0;
      in
      import <nix/fetchurl.nix> {
        url = "${snapshotUrl}/${entry.path}";
        sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
        name = "archive-hash-mismatch-proof-deliberately-wrong-hash";
      };
  };
}
