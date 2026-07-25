# nix/snap.nix — the declared snap surface + snap lockfile schema +
# per-generation snap manifest compilation + vendored `.snap`/`.assert`
# fetching (SPEC.md §4.3 switching-table row "Snaps (add/remove/pin/
# connect/config)", §4.4 "A snap lockfile pins (name, revision, assertion
# hashes)", §4.5, §5 "verified provenance by default", §6
# `ubuntnix.snaps.<name>`; GitHub issue #60, milestone M3).
#
# -- What this file is, and what it deliberately is NOT ----------------------
#
# Exactly the same shape nix/archive.nix, nix/etc.nix, and nix/systemd.nix
# already established for "there is no real `options.ubuntnix` module
# evaluator yet" (see nix/etc.nix's header for the fuller version of this
# caveat -- it applies here verbatim): a `validate` function (the
# eval-boundary enforcement the primitive-core design calls for), a
# `compileManifest`/`renderManifest` pair (pure compilation -> a real
# per-generation JSON manifest), and `fetchSnap`/`fetchAssert`/`snaps`
# (nix/archive.nix's `fetchDeb`/`debs` pattern, applied to snaps), all
# exposed under `flake.lib.snap`, ready for a future `ubuntnix.snaps.<name>`
# module option to call once real module evaluation exists.
# `perSystem.packages.snap-proof` (bottom) exercises `validate` +
# `compileManifest` + `renderManifest` end to end against a small fixture
# declaration cross-referenced against the REAL committed snaps.lock.json
# (mirrors `etc-proof`/`systemd-proof`'s own "prove the pure/compile half
# for real, without needing live root/network/snapd" role).
#
# This file does NOT diff two generations' live snap state against a real,
# running snapd (that belongs to a future on-device planner/executor pair,
# the same "logic able to run without a `nix` binary belongs in tested
# shell/python" rule nix/etc.nix's header states) and does NOT itself call
# `snap ack`/`snap install` (SPEC.md §4.3's "converge snapd via its API;
# vendored payloads signed-sideloaded" is real-system activation, out of
# this issue's scope — see bin/ubx-snap-resolve's header for the resolver
# half this file consumes).
#
# -- The declaration surface (SPEC.md §6) -------------------------------
#
#   ubuntnix.snaps.firefox = {
#     revision = 4090;                 # optional; default null -- pins the
#                                       # exact revision `channel` must
#                                       # resolve to (SPEC.md §6's own
#                                       # example); left null, whatever
#                                       # revision the channel currently
#                                       # resolves to is accepted as-is.
#     channel = "stable";              # required; track[/risk[/branch]]
#     classic = false;                 # default false
#     connections = [ "camera" ];      # default []; plug/slot names
#     config = { ... };                # default {}; `snap set` values
#     unverifiedPublisher = false;     # default false; per-snap policy opt-in
#   };
# `entries` throughout this file is exactly that attrset — attribute name
# (the snap name) -> `{ channel; revision?; classic?; connections?;
# config?; unverifiedPublisher?; }`. This is deliberately the SAME shape
# snaps.packages.json declares (see that file's own header and
# bin/ubx-snap-resolve's). The ACTUAL pin a real generation's manifest
# carries always comes from the lockfile (below), never from this
# attribute directly — `revision` here is an optional constraint on what
# bin/ubx-snap-resolve is allowed to resolve `channel` to, re-checked
# against the lockfile at eval time too (see "Cross-referencing the
# lockfile" below) — the same relationship nix/archive.nix's `debs` has to
# `ubuntnix.debs`' flat name list, just with an extra optional pin.
#
# -- Eval-boundary validation (`validate`) -------------------------------
#
# Every declared entry is checked, and EVERY violation across the whole
# attrset is collected into one `throw` (never just the first — same
# posture as nix/archive.nix's/nix/etc.nix's own `validate`):
#   - name: a valid Snap Store name (lowercase alphanumerics/hyphens, at
#     least one letter, no leading/trailing/doubled hyphen — snapd's own
#     `ValidateName` grammar, mirrored in bin/ubx-snap-resolve's
#     NAME_RE for the identical reason: one schema, checked twice,
#     independently);
#   - `channel`: required, matches `[track/]{stable|candidate|beta|edge}
#     [/branch]`;
#   - `classic`/`unverifiedPublisher` (wherever set): booleans;
#   - `connections`: a list of valid interface-name strings;
#   - `config`: an attrset (arbitrary `snap set` values — no further
#     structural constraint, mirrors bin/ubx-snap-resolve's own looseness
#     here).
#
# -- Cross-referencing the lockfile + the verified-publisher policy ---------
#
# `compileManifest { entries; lockfile; allowUnverifiedPublishers ? false; }`
# first validates `entries`, then for EVERY declared name requires a
# matching `snaps.lock.json` entry (by name) — a declared-but-unresolved
# snap is an eval-time error ("run bin/ubx-snap-resolve"), the same
# "declaration and lockfile must agree" contract nix/archive.nix's `debs`
# implicitly assumes of `archive.lock.json`. It ALSO re-derives and
# re-enforces SPEC.md §4.5/§5's verified-publisher-by-default policy
# independently of bin/ubx-snap-resolve's own enforcement (that script's
# `emit_lockfile` already refuses to pin an unverified-and-disallowed
# snap at RESOLVE time) — the same dual-enforcement posture
# nix/systemd.nix/bin/ubx-systemd take for the refuse-restart class table:
# a declared entry whose lockfile-reported `publisherVerified` is `false`
# is rejected here UNLESS that entry's own `unverifiedPublisher` is `true`
# OR the caller's `allowUnverifiedPublishers` (the per-system default) is
# `true`.
#
# -- The per-generation snap manifest (`compileManifest`/`renderManifest`) --
#
# `compileManifest` is a PURE function (`entries`/`lockfile`/policy data in,
# a manifest attrset out — no filesystem I/O, no derivation building):
#   { version = 1;
#     snaps = [ { name; channel; revision; classic; publisher;
#                 publisherVerified; connections; config; }, ... ]; }
# sorted by name (free, via `builtins.attrNames`' sorted iteration — same
# property nix/archive.nix's `debs` and nix/etc.nix's `render` rely on).
# Deliberately does NOT embed the fetched `.snap`/`.assert` STORE PATHS:
# doing so would force `renderManifest`'s build to realize (network-fetch)
# every referenced FOD merely by evaluating the manifest, exactly the
# "flake check forces needless network I/O" problem nix/archive.nix's own
# header warns against — and per SPEC.md §4.2, the real on-device store
# lives at `/ubx`, not this evaluation's own `/nix/store`, so a raw Nix
# store path here would not even be the path a real generation's
# activation should read from. `fetchSnap`/`fetchAssert`/`snaps` (below)
# remain the SEPARATE, lazy way to reach the real fetched artifacts — the
# manifest instead carries `channel`/`revision`/`classic`/`publisher`/
# `connections`/`config`, exactly what a future on-device snap-domain
# planner (bin/ubx-snap, by analogy with bin/ubx-etc/bin/ubx-systemd) would
# actually diff against observed snapd state.
#
# `renderManifest` wraps `compileManifest`'s pure result in an actual
# derivation (`runInUbuntuBase`, mirrors nix/etc.nix's own manifest-file
# copy step) so `perSystem.packages.snap-proof` below is a real,
# `nix build`-able output — the manifest data itself is content-only
# (`builtins.toJSON`, no derivation-output context), so embedding it as an
# env attr and `cp`-ing it into `$out/manifest.json` is exactly as safe as
# nix/etc.nix's own `ETC_MANIFEST` env attr.
#
# -- Vendoring: fixed-output derivations by hash (`fetchSnap`/`fetchAssert`) -
#
# Mirrors nix/archive.nix's `fetchDeb`/`debs` exactly: one
# `snaps.lock.json` entry -> one (or two — payload AND assertion chain)
# fixed-output derivation(s) via `<nix/fetchurl.nix>`, verified against the
# pinned sha256 by Nix itself at build time. `snaps` (below) is the
# name -> `{ snap; assert; }` attrset for every LOCKFILE entry (not merely
# every declared one — mirrors `debs`' own "every pinned entry gets a
# fetcher" posture). Nothing here FORCES these to build merely by
# evaluating this file (like nix/archive.nix's own `debs`, they are
# realized only when something actually depends on their output — see that
# file's header, "so merely evaluating... forcing every pinned .deb to be
# fetched... would be both slow and needless network I/O"), but
# `perSystem.packages.snap-fetch-proof`/`snap-hash-mismatch-proof` (bottom)
# DO force it, exactly like `archive-fetch-proof`/
# `archive-hash-mismatch-proof` do for debs: the committed snaps.lock.json's
# `snap.sha256`/`assert.sha256` were independently recomputed from bytes
# actually fetched from the live Snap Store while authoring this file (see
# that file's own header), so — unlike an earlier draft of this file, when
# the lockfile only carried schema-shaped placeholder data — a real,
# CI-verified forcing proof is possible today, not just a future follow-up.
#
# -- Interface with a future bin/ubx-snap ------------------------------------
#
# `renderManifest`'s `$out/manifest.json` is exactly the artifact a future
# on-device snap-domain planner would diff against observed `snap list`/
# `snap connections` state, the same role nix/etc.nix's `$out/manifest.json`
# plays for bin/ubx-etc — and `bin/ubx-generations`' `GEN_SNAP_MANIFEST`
# field (already reserved; see that script's header, "Extensible sections")
# is exactly where a real `ubx rebuild` would point once wired.
{ config, inputs, ... }:
let
  lib = inputs.nixpkgs.lib;

  inherit (config.flake.lib.stdenv) runInUbuntuBase;

  # ../snaps.lock.json — see this file's header, and bin/ubx-snap-resolve's,
  # for the schema.
  rawLockfile = builtins.fromJSON (builtins.readFile ../snaps.lock.json);

  sha256Re = "[0-9a-f]{64}";

  checkLockEntry = e:
    let
      hasAll = e ? name && e ? channel && e ? revision && e ? classic
        && e ? publisher && e ? publisherVerified && e ? snap && e ? "assert";
      label = if e ? name then "snaps.lock.json entry \"${toString e.name}\"" else "a snaps.lock.json entry";
      snapOk = hasAll && e.snap ? sha256 && builtins.isString e.snap.sha256 && builtins.match sha256Re e.snap.sha256 != null;
      assertOk = hasAll && e."assert" ? sha256 && builtins.isString e."assert".sha256 && builtins.match sha256Re e."assert".sha256 != null;
      revisionOk = hasAll && builtins.isInt e.revision && e.revision > 0;
    in
    (if hasAll then [ ] else [ "${label} is missing one of the required fields (name/channel/revision/classic/publisher/publisherVerified/snap/assert)" ])
    ++ (if hasAll && !revisionOk then [ "${label} has an invalid revision (want a positive integer): ${toString (e.revision or null)}" ] else [ ])
    ++ (if hasAll && !snapOk then [ "${label} has a malformed snap.sha256 (want 64 lowercase hex chars)" ] else [ ])
    ++ (if hasAll && !assertOk then [ "${label} has a malformed assert.sha256 (want 64 lowercase hex chars)" ] else [ ]);

  validateLockfile = data:
    let
      entries = data.snaps or [ ];
      errors =
        (if data ? version && data.version == 1 then [ ] else [ "version must be 1, got ${toString (data.version or null)}" ])
        ++ (if builtins.isList entries then [ ] else [ "'snaps' must be a list" ])
        ++ (if builtins.isList entries && entries == [ ] then [ "'snaps' must not be empty" ] else [ ])
        ++ (if builtins.isList entries then builtins.concatLists (map checkLockEntry entries) else [ ]);
    in
    if errors == [ ]
    then entries
    else
      throw ''
        snaps.lock.json failed schema validation (SPEC.md §4.3, §4.4):
        ${builtins.concatStringsSep "\n" (map (e: "  - ${e}") errors)}'';

  lockEntries = validateLockfile rawLockfile;
  lockByName = builtins.listToAttrs (map (e: { name = e.name; value = e; }) lockEntries);

  # -- ubuntnix.snaps.<name> entry validation (see header, "Eval-boundary
  # validation") -----------------------------------------------------------
  nameRe = "[a-z0-9]+(-[a-z0-9]+)*";
  nameOk = n: builtins.isString n && builtins.match nameRe n != null && builtins.match ".*[a-z].*" n != null;

  identRe = "[a-z0-9]+(-[a-z0-9]+)*";
  identOk = s: builtins.isString s && builtins.match identRe s != null;

  riskRe = "(stable|candidate|beta|edge)";
  trackRe = "[a-z0-9][a-z0-9._-]*";
  channelRe = "(${trackRe}/)?${riskRe}(/${trackRe})?";
  channelOk = c: builtins.isString c && builtins.match channelRe c != null;

  checkSnapEntry = name: e:
    let
      classic = e.classic or false;
      connections = e.connections or [ ];
      config = e.config or { };
      unverified = e.unverifiedPublisher or false;
      channel = e.channel or null;
      # `revision`, mirroring bin/ubx-snap-resolve's own declaration schema
      # (see that script's header): optional, null by default; when set, it
      # additionally PINS the exact revision `channel` must resolve to.
      # `compileManifest` below re-derives and re-enforces this pin against
      # the lockfile's own resolved revision -- the same dual-enforcement
      # posture this file already takes for the verified-publisher policy.
      revision = e.revision or null;
      revisionOk = revision == null || (builtins.isInt revision && revision > 0);
    in
    (if nameOk name then [ ] else [ "ubuntnix.snaps.\"${toString name}\": not a valid snap name (lowercase alphanumerics/hyphens, at least one letter, no leading/trailing/doubled hyphen)" ])
    ++ (if channel != null && channelOk channel then [ ] else [ "ubuntnix.snaps.\"${name}\": channel must match [track/]{stable|candidate|beta|edge}[/branch], got ${toString channel}" ])
    ++ (if revisionOk then [ ] else [ "ubuntnix.snaps.\"${name}\": revision must be null or a positive integer, got ${toString revision}" ])
    ++ (if builtins.isBool classic then [ ] else [ "ubuntnix.snaps.\"${name}\": classic must be a boolean" ])
    ++ (if builtins.isBool unverified then [ ] else [ "ubuntnix.snaps.\"${name}\": unverifiedPublisher must be a boolean" ])
    ++ (if builtins.isList connections then [ ] else [ "ubuntnix.snaps.\"${name}\": connections must be a list" ])
    ++ (if builtins.isList connections && builtins.all identOk connections then [ ] else (if builtins.isList connections then [ "ubuntnix.snaps.\"${name}\": connections contains an invalid interface name" ] else [ ]))
    ++ (if builtins.isAttrs config then [ ] else [ "ubuntnix.snaps.\"${name}\": config must be an attrset" ]);

  validate = entries:
    let
      errors = builtins.concatLists (map (name: checkSnapEntry name entries.${name}) (builtins.attrNames entries));
    in
    if errors == [ ]
    then entries
    else
      throw ''
        ubuntnix.snaps failed eval-boundary validation (SPEC.md §4.3, §4.5, §6; nix/snap.nix):
        ${builtins.concatStringsSep "\n" (map (e: "  - ${e}") errors)}'';

  # -- compileManifest: validated entries + lockfile -> pure manifest data --
  compileManifest =
    { entries
    , lockfile ? lockEntries
    , allowUnverifiedPublishers ? false
    }:
    let
      validated = validate entries;
      lockMap = builtins.listToAttrs (map (e: { name = e.name; value = e; }) lockfile);
      names = builtins.attrNames validated;

      missing = builtins.filter (n: !(lockMap ? ${n})) names;

      policyErrors = builtins.concatLists (map
        (n:
          let
            entry = validated.${n};
            lock = lockMap.${n};
            allowed = (entry.unverifiedPublisher or false) || allowUnverifiedPublishers;
            revisionPin = entry.revision or null;
          in
          (if lock.publisherVerified || allowed
          then [ ]
          else [ "\"${n}\": publisher \"${lock.publisher}\" is not verified, and neither this snap's unverifiedPublisher nor allowUnverifiedPublishers opts in (SPEC.md §4.5/§5: verified provenance by default)" ])
          # Dual-enforcement of bin/ubx-snap-resolve's own revision-pin
          # contract (see that script's header, and checkSnapEntry above):
          # a declared `revision` must match what the lockfile actually
          # pinned for this channel -- a stale/edited-by-hand lockfile
          # disagreeing with a still-current declared pin is exactly the
          # kind of drift this eval-time re-check exists to catch.
          ++ (if revisionPin == null || revisionPin == lock.revision
          then [ ]
          else [ "\"${n}\": declared revision pin ${toString revisionPin} does not match snaps.lock.json's resolved revision ${toString lock.revision} -- run bin/ubx-snap-resolve" ]))
        (builtins.filter (n: lockMap ? ${n}) names));

      errors =
        (map (n: "\"${n}\" is declared but not present in snaps.lock.json -- run bin/ubx-snap-resolve") missing)
        ++ policyErrors;
    in
    if errors != [ ]
    then
      throw ''
        ubuntnix.snaps failed manifest compilation (SPEC.md §4.3, §4.5, §6; nix/snap.nix):
        ${builtins.concatStringsSep "\n" (map (e: "  - ${e}") errors)}''
    else {
      version = 1;
      snaps = map
        (n:
          let
            entry = validated.${n};
            lock = lockMap.${n};
          in
          {
            name = n;
            channel = entry.channel;
            revision = lock.revision;
            classic = entry.classic or false;
            publisher = lock.publisher;
            publisherVerified = lock.publisherVerified;
            connections = entry.connections or [ ];
            config = entry.config or { };
          })
        names;
    };

  # -- renderManifest: compileManifest's pure data -> a real derivation -----
  renderManifest =
    { system ? "x86_64-linux"
    , name ? "snap"
    , entries
    , lockfile ? lockEntries
    , allowUnverifiedPublishers ? false
    }:
    let
      manifest = compileManifest { inherit entries lockfile allowUnverifiedPublishers; };
      manifestFile = builtins.toFile "${name}-manifest.json" (builtins.toJSON manifest);
    in
    runInUbuntuBase {
      inherit system;
      name = "${name}-snap";
      env = { SNAP_MANIFEST = manifestFile; };
      script = ''
        "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" "$UBX_BASE/bin/cp" "$SNAP_MANIFEST" "$out"
      '';
    };

  # -- vendoring: fixed-output derivations by hash (see header) --------------
  #
  # Store names may only contain [A-Za-z0-9+._?=-]; sanitizeStoreName mirrors
  # nix/archive.nix's own (there, "/" from a pool path; here, nothing in a
  # snap name/revision pair is actually unsafe today, but the same
  # defensive replace-known-unsafe-characters posture is kept for parity
  # and future-proofing against an unexpected snap/channel/revision shape).
  sanitizeStoreName = s: builtins.replaceStrings [ ":" "%" "~" "/" ] [ "_" "_" "_" "_" ] s;

  fetchSnap = entry:
    import <nix/fetchurl.nix> {
      url = entry.snap.url;
      sha256 = entry.snap.sha256;
      name = sanitizeStoreName "${entry.name}_${toString entry.revision}.snap";
    };

  fetchAssert = entry:
    import <nix/fetchurl.nix> {
      url = entry."assert".url;
      sha256 = entry."assert".sha256;
      name = sanitizeStoreName "${entry.name}_${toString entry.revision}.assert";
    };

  # name -> { snap; assert; } for every LOCKFILE entry (mirrors
  # nix/archive.nix's `debs`: every PINNED entry gets a fetcher, whether or
  # not something currently declared references it).
  snaps = builtins.listToAttrs (map
    (entry: {
      name = entry.name;
      value = {
        snap = fetchSnap entry;
        "assert" = fetchAssert entry;
      };
    })
    lockEntries);
in
{
  # Exposed under flake.lib (option declared once, in nix/lib.nix; every
  # dendritic file just contributes its own named attribute — same pattern
  # nix/archive.nix/nix/etc.nix/nix/systemd.nix use).
  flake.lib.snap = {
    inherit validate compileManifest renderManifest;
    inherit fetchSnap fetchAssert snaps;
    lockfile = lockEntries;
    validateLockfile = validateLockfile;
  };

  systems = [ "x86_64-linux" ];

  perSystem = { system, ... }: {
    # snap-proof (issue #60): compileManifest + renderManifest evaluated end
    # to end against a small fixture declaration (one snap, hello-world)
    # cross-referenced against the REAL committed snaps.lock.json -- proves
    # validation, lockfile cross-referencing, publisher-policy enforcement,
    # and manifest rendering all actually work, without needing live
    # root/network/snapd (the same role etc-proof/systemd-proof play for
    # their own files).
    packages.snap-proof = renderManifest {
      inherit system;
      name = "snap-proof";
      entries = {
        hello-world = {
          channel = "stable";
          revision = 29;
          classic = false;
          connections = [ ];
          config = { };
        };
      };
    };

    # snap-fetch-proof (issue #60, mirrors nix/archive.nix's
    # archive-fetch-proof): depends on EVERY pinned lockfile entry's
    # `.snap`/`.assert` FODs (forcing Nix to actually fetch-and-verify each
    # one against its pinned sha256) and writes a deterministic manifest
    # recording a sha256sum RECOMPUTED INSIDE THE SANDBOX for each -- an
    # independent proof the bytes are what they claim to be, not merely
    # Nix's own fixed-output verification. Possible today (unlike an
    # earlier draft of this file) because snaps.lock.json's hashes are now
    # real, independently-verified Snap Store bytes -- see that file's own
    # header. Sandboxing/loader-pattern notes are identical to
    # archive-fetch-proof's own (see nix/archive.nix's "SANDBOXING NOTE"):
    # CI's flake job passes `--option sandbox relaxed` for the same reason.
    packages.snap-fetch-proof =
      let
        entries = lockEntries;
        n = builtins.length entries;
        indices = builtins.genList (i: i) n;
        entryAt = i: builtins.elemAt entries i;
        snapEnvName = i: "SNAP_${toString i}";
        assertEnvName = i: "ASSERT_${toString i}";

        env = builtins.listToAttrs (builtins.concatMap
          (i:
            let entry = entryAt i; in
            [
              { name = snapEnvName i; value = snaps.${entry.name}.snap; }
              { name = assertEnvName i; value = snaps.${entry.name}."assert"; }
            ])
          indices);

        proofLines = builtins.concatStringsSep "\n" (map
          (i:
            let
              entry = entryAt i;
              snapRef = "$" + snapEnvName i;
              assertRef = "$" + assertEnvName i;
            in
            ''
              {
                echo "snap name=${entry.name} revision=${toString entry.revision} store=${snapRef}"
                sumline=$("$UBX_LD" --library-path "$UBX_LIBRARY_PATH" \
                  "$UBX_BASE/usr/bin/sha256sum" "${snapRef}")
                echo "snap sha256sum=''${sumline%% *}"
                sumline=$("$UBX_LD" --library-path "$UBX_LIBRARY_PATH" \
                  "$UBX_BASE/usr/bin/sha256sum" "${assertRef}")
                echo "assert sha256sum=''${sumline%% *}"
              } >> "$out"'')
          indices);
      in
      runInUbuntuBase {
        inherit system env;
        name = "snap-fetch-proof";
        script = ''
          echo "MARKER=ubuntnix-snap-fetch-proof-v1" > "$out"
          ${proofLines}
        '';
      };

    # snap-hash-mismatch-proof (issue #60, mirrors nix/archive.nix's
    # archive-hash-mismatch-proof).
    #
    # !!! DELIBERATELY BROKEN — DO NOT "FIX" THIS !!!
    #
    # Fetches a REAL pinned snap payload's URL but with an intentionally
    # WRONG sha256 (64 zeros). This derivation MUST FAIL to build with
    # Nix's own "hash mismatch in fixed-output derivation" error -- CI's
    # "flake" job is expected to assert the build FAILS and that its output
    # names "hash mismatch", the negative-path proof that a corrupted/
    # tampered/wrong-pin `.snap` is rejected rather than silently accepted.
    packages.snap-hash-mismatch-proof =
      let
        entry = builtins.elemAt lockEntries 0;
      in
      import <nix/fetchurl.nix> {
        url = entry.snap.url;
        sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
        name = "snap-hash-mismatch-proof-deliberately-wrong-hash";
      };
  };
}
