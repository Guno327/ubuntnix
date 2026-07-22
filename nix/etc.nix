# nix/etc.nix — generated `/etc` per generation, plus the machine-local
# mutable exceptions that never go through it (SPEC.md §4.2 "generated
# `/etc`", §4.3 switching-table row 1, §6 the `ubuntnix.etc."path"`
# primitive; GitHub issue #26, milestone M2).
#
# -- What this file is, and what it deliberately is NOT ----------------------
#
# There is no `modules/` tree and no real module-evaluation surface yet
# (docs/gen_reference.py's own header: "ubuntnix is pre-M1: there is no
# flake yet... no modules/ tree"; nix/ubx.nix's header lists "a 'system
# modules' output class" among the things NOT declared until a milestone
# gives it something real to compose into). This file follows the exact
# same shape nix/archive.nix and nix/compose.nix already established for
# that situation: a `validate` function (the eval-boundary enforcement
# SPEC.md's primitive-core design calls for) and a `render` function
# (pure-ish — see "Rendering" below) exposed under `flake.lib.etc`, ready
# for a future `ubuntnix.etc` module option to call once real module
# evaluation exists. `perSystem.packages.etc-proof` (bottom) exercises
# both against a small fixture declaration, the same role
# `archive-fetch-proof`/`compose-proof` play for their own files.
#
# This file does NOT decide symlink-vs-copy for the RUNNING machine's
# `/etc` (that's activation's job — see bin/ubx-etc-apply's header for that
# decision and its justification) and does NOT compute a diff between two
# generations (that's bin/ubx-etc's job — a pure, on-device shell/python
# planner, per this project's standing rule that logic able to run without
# a `nix` binary belongs in tested shell/python, not the Nix layer). What
# THIS file produces — a content tree plus a JSON manifest — is exactly
# the artifact those two on-device tools consume; see "Interface with
# bin/ubx-etc / bin/ubx-etc-apply" below for the exact contract.
#
# -- The declaration surface (SPEC.md §6) -------------------------------
#
#   ubuntnix.etc."ssh/sshd_config" = {
#     text = ''...'';               # exactly one of text/source
#     # source = ./files/sshd_config;
#     owner = "root";                # default "root"
#     group = "root";                # default "root"
#     mode  = "0644";                # default "0644"
#   };
#
# The attribute name is a RELATIVE path under `/etc` (no leading `/etc` or
# `/`, matching the SPEC example's `"ssh/sshd_config"` — not
# `"/etc/ssh/sshd_config"`). `entries` throughout this file is exactly that
# attrset — attribute name -> `{ text | source; owner?; group?; mode?; }`.
#
# -- Eval-boundary validation (`validate`) -------------------------------
#
# Every declared entry is checked, and EVERY violation across the whole
# attrset is collected into one `throw` (never just the first — same
# posture as nix/archive.nix's `validate`, which this mirrors almost
# exactly), covering:
#   - path safety: relative (no leading `/`), no empty/`.`/`..` segment
#     (rules out `/etc/../etc/shadow`-style traversal AND a bare leading
#     `/` in one pass — see `pathOk` below for why splitting on `/` and
#     checking every segment catches both at once), and restricted to
#     `[A-Za-z0-9._-]` per segment (also keeps every path a safe Nix store
#     name component once `/` is replaced with `_`, and a safe JSON string
#     with zero escaping to worry about — see "Rendering" below);
#   - exactly one of `text`/`source` (both set, or neither, is an error);
#   - `owner`/`group` look like real Unix names (`[a-z_][a-z0-9_-]*`);
#   - `mode` is exactly 4 octal digits (`0[0-7]{3}`, e.g. `"0644"` —
#     matches the SPEC example's own quoted-string style; a bare Nix
#     integer would silently octal/decimal-confuse `0644` vs `644`, which
#     is exactly why the surface takes a string);
#   - the path does not name a machine-local mutable exception (see
#     "Machine-local mutable exceptions" below) — declaring one is an
#     eval-time error here, per this issue's scope item 3, independent of
#     and in addition to bin/ubx-etc's own defense-in-depth refusal at
#     planning time.
#
# -- Machine-local mutable exceptions (SPEC.md §4.2, §4.3) -------------------
#
# The enumeration lives in ONE place, committed as data:
# `../etc.exceptions.json` (repo root, sibling to `archive.lock.json` /
# `archive.packages.json` — same reasoning those two give for plain
# committed JSON over a `.nix` file: readable by both `builtins.fromJSON`
# HERE and by plain shell/python tooling with no `nix` binary at all,
# which is exactly what bin/ubx-etc and bin/ubx-etc-apply are). This file
# reads it (via `validateExceptions`, which asserts its own schema —
# including "a `sensitive` entry's mode must not be world-readable", the
# issue's own requirement — the same way `nix/archive.nix`'s `validate`
# asserts `archive.lock.json`'s shape) and folds its `path`s into
# `validate` above. `../etc.exceptions.json` documents, per entry, exactly
# why it can't be flake-declared; that reasoning is not duplicated here.
#
# `flake.lib.etc.exceptions` exposes the validated list; `exceptionPaths`/
# `isExceptionPath` are the derived lookups `validate` uses. Nothing here
# treats this list as exhaustive beyond what SPEC.md §4.2 asks for ("an
# enumerated short list... machine-id, SSH host keys, adjtime, ...") — see
# that file's own header for the audit this covers.
#
# -- Rendering (`render`) -------------------------------------------------
#
# `render { system; name; entries; }` first calls `validate entries`, then
# for each entry:
#   - `text` entries become their own tiny store object via
#     `builtins.toFile` (content known at eval time, hashed with
#     `builtins.hashString "sha256"` — pure Nix, no shell involved);
#   - `source` entries reference the given path/derivation-output directly
#     (hashed with `builtins.hashFile "sha256"` — also pure Nix; if
#     `source` is a derivation's output path this forces that derivation
#     to build during evaluation, same as any other Nix expression that
#     reads a derivation output's content rather than just its path).
# Deliberately NOT done via a shell `cat`-heredoc embedding raw declared
# text (the way this project's other composers, e.g. nix/compose.nix's
# preseed staging, sometimes do for their OWN generated, punctuation-light
# data): arbitrary user-declared `text` could coincidentally contain
# whatever heredoc delimiter was chosen, silently truncating or corrupting
# the rendered file. Routing every entry's bytes through a real Nix store
# object and only ever `cp`-ing already-realized store paths into the
# output tree (see `copyLines` below) sidesteps that whole class of bug —
# the render script's own text never contains a single byte of declared
# content, only paths.
#
# The manifest (`{ version = 1; entries = [ { path; sha256; owner; group;
# mode; }, ... ]; }`) is likewise fully computable in pure Nix (every
# field is either validated/defaulted data or a hash computed above), so
# it too is serialized with `builtins.toJSON` and shipped into the
# derivation as a `builtins.toFile`-backed env attr rather than assembled
# by shell — one less place to get JSON-escaping wrong. `builtins.toJSON`
# emits compact (non-pretty) JSON; unlike `archive.lock.json` this
# manifest is a BUILD OUTPUT, never hand-edited or diffed by a human in
# review, so there is no reason to spend effort on pretty-printing it
# (bin/ubx-etc parses it with python3's `json` module either way — see
# that script's header for why JSON, not this project's usual flat
# KEY=value manifest convention, is the right shape here).
#
# Ordering is deterministic for free: Nix attribute sets are always
# iterated in sorted-by-name order (`builtins.attrNames`), so both the
# copy script and the manifest's `entries` list come out path-sorted with
# no explicit sort step — mirrors nix/archive.nix's `debs` relying on the
# same property.
#
# The actual `cp`/`mkdir` work reuses nix/compose.nix's already-proven
# "ubxrun" pattern verbatim (loader-wrapped ubuntu-base coreutils —
# nix/stdenv.nix's "BOOTSTRAP CAVEAT"): every external binary this script
# calls is a real Canonical-archive binary from `ubuntuBase.unpacked`,
# invoked through its own ELF interpreter, never a nixpkgs tool (SPEC.md
# §1.3; tests/unit/021-flake-purity.sh statically enforces this). Each
# entry's content store path is threaded through as an indexed env attr
# (`ETC_SRC_<i>`), never spliced into the script text — the same
# constraint nix/archive.nix's `archive-fetch-proof` documents
# (`builtins.toFile`-backed scripts may not carry derivation-output
# context inline; only derivation ENV ATTRS may).
#
# The rendered tree's OWN on-disk file permissions (whatever `cp` leaves
# them at — typically the store's usual read-only bits) are NOT meaningful
# and are never consulted by anything downstream: `owner`/`group`/`mode`
# live exclusively in `manifest.json`, and it is the EXECUTOR
# (bin/ubx-etc-apply), acting on real `/etc` with real privileges, that
# ever applies them to a real file. This mirrors nix/stdenv.nix's own
# "the resulting tree's ownership bits are not meant to be a meaningful
# part of what's pinned" precedent.
#
# -- Interface with bin/ubx-etc / bin/ubx-etc-apply --------------------------
#
# `render`'s `$out` has exactly two things activation tooling depends on
# (a stable, minimal contract on purpose):
#   $out/manifest.json     the JSON manifest described above
#   $out/tree/<path>       one regular file per declared entry, content
#                           only — no meaningful permission bits (see
#                           above); `<path>` matches the manifest's `path`
#                           field exactly (relative, `/`-separated)
# `$out` itself is what a generation's manifest (bin/ubx-generations'
# `GEN_ETC_REF` field, already reserved for exactly this — see that
# script's header, "Extensible sections") is expected to reference once a
# later issue wires `ubx rebuild` end to end; nothing here writes that
# field itself (issue #26 is this file, bin/ubx-etc, bin/ubx-etc-apply —
# not the `ubx rebuild` verb, which is later work per bin/ubx-generations'
# own header: "Activation and real deletion are `ubx` verb work for a
# later issue").
{ config, inputs, ... }:
let
  lib = inputs.nixpkgs.lib;

  inherit (config.flake.lib.stdenv) runInUbuntuBase;

  # -- machine-local mutable exceptions: schema + load -----------------------
  #
  # See this file's header, "Machine-local mutable exceptions".
  rawExceptionsData = builtins.fromJSON (builtins.readFile ../etc.exceptions.json);

  modeRe = "0[0-7]{3}";
  modeOk = m: builtins.isString m && builtins.match modeRe m != null;

  checkExceptionEntry = e:
    let
      hasAll = e ? path && e ? owner && e ? group && e ? mode && e ? sensitive && e ? reason;
      label = if e ? path then "exception \"${toString e.path}\"" else "an exception entry";
      modeValid = hasAll && modeOk e.mode;
      # World ("other") permission digit is the mode string's LAST
      # character (e.g. "0600" -> "0"); 4/5/6/7 all have the read bit
      # (0b100) set. Sensitive entries (host keys) must never have it.
      worldDigit = if modeValid then builtins.substring 3 1 e.mode else "";
      worldReadable = builtins.elem worldDigit [ "4" "5" "6" "7" ];
    in
    (if hasAll then [ ] else [ "${label} is missing one of the required fields (path/owner/group/mode/sensitive/reason)" ])
    ++ (if hasAll && !modeValid then [ "${label} has a malformed mode (want 4 octal digits, e.g. \"0600\"): ${toString e.mode}" ] else [ ])
    ++ (if hasAll && modeValid && (e.sensitive == true) && worldReadable
    then [ "${label} is marked sensitive but its mode ${e.mode} is world-readable — SPEC.md §4.2's 'never world-readable when sensitive' requirement" ]
    else [ ]);

  validateExceptions = data:
    let
      entries = data.exceptions or [ ];
      errors =
        (if builtins.isList entries then [ ] else [ "etc.exceptions.json's 'exceptions' field must be a list" ])
        ++ (if builtins.isList entries then builtins.concatLists (map checkExceptionEntry entries) else [ ]);
    in
    if errors == [ ]
    then entries
    else
      throw ''
        etc.exceptions.json failed schema validation (SPEC.md §4.2, §4.3):
        ${builtins.concatStringsSep "\n" (map (e: "  - ${e}") errors)}'';

  exceptions = validateExceptions rawExceptionsData;
  exceptionPaths = map (e: e.path) exceptions;
  isExceptionPath = path: builtins.elem path exceptionPaths;

  # -- ubuntnix.etc entry validation (see header, "Eval-boundary validation") --
  #
  # Splitting on "/" and requiring every segment to be non-empty, not "."
  # or "..", and drawn from a safe character class catches a leading "/"
  # (empty first segment), a trailing "/" (empty last segment), "//"
  # (empty middle segment), and "../"-style traversal all in one pass —
  # deliberately not three separate checks that could disagree at the
  # edges (e.g. "does 'foo/../bar' count as absolute?" never has to be
  # answered because ".." is rejected outright, full stop).
  segmentOk = seg: seg != "" && seg != "." && seg != ".." && builtins.match "[A-Za-z0-9._-]+" seg != null;
  pathOk = path: builtins.isString path && path != "" && builtins.all segmentOk (lib.splitString "/" path);

  ownerRe = "[a-z_][a-z0-9_-]*";
  ownerOk = s: builtins.isString s && builtins.match ownerRe s != null;

  checkEtcEntry = path: e:
    let
      hasText = e ? text;
      hasSource = e ? source;
      owner = e.owner or "root";
      group = e.group or "root";
      mode = e.mode or "0644";
      pOk = pathOk path;
    in
    (if pOk then [ ] else [ "ubuntnix.etc.\"${toString path}\": path must be relative, with no empty/'.'/'..' segment, using only [A-Za-z0-9._-] per segment (no leading '/', no traversal)" ])
    ++ (if hasText && hasSource then [ "ubuntnix.etc.\"${path}\": both text and source are set (exactly one is required)" ] else [ ])
    ++ (if !hasText && !hasSource then [ "ubuntnix.etc.\"${path}\": neither text nor source is set (exactly one is required)" ] else [ ])
    ++ (if ownerOk owner then [ ] else [ "ubuntnix.etc.\"${path}\": owner \"${toString owner}\" is not a valid user name (want [a-z_][a-z0-9_-]*)" ])
    ++ (if ownerOk group then [ ] else [ "ubuntnix.etc.\"${path}\": group \"${toString group}\" is not a valid group name (want [a-z_][a-z0-9_-]*)" ])
    ++ (if modeOk mode then [ ] else [ "ubuntnix.etc.\"${path}\": mode \"${toString mode}\" must be 4 octal digits as a string, e.g. \"0644\"" ])
    ++ (if pOk && isExceptionPath path then [ "ubuntnix.etc.\"${path}\": this path is a machine-local mutable exception (see etc.exceptions.json) and cannot be declared here — SPEC.md §4.2/§4.3" ] else [ ]);

  validate = entries:
    let
      errors = builtins.concatLists (map (path: checkEtcEntry path entries.${path}) (builtins.attrNames entries));
    in
    if errors == [ ]
    then entries
    else
      throw ''
        ubuntnix.etc failed eval-boundary validation (SPEC.md §4.2, §6; nix/etc.nix):
        ${builtins.concatStringsSep "\n" (map (e: "  - ${e}") errors)}'';

  # -- rendering (see header, "Rendering") -----------------------------------
  #
  # Store names may only contain [A-Za-z0-9+._?=-]; every path accepted by
  # `pathOk` above already satisfies that once "/" is mapped to "_".
  sanitizeStoreName = path: builtins.replaceStrings [ "/" ] [ "_" ] path;

  normalizeEntry = path: e:
    let
      owner = e.owner or "root";
      group = e.group or "root";
      mode = e.mode or "0644";
      isText = e ? text;
      content =
        if isText
        then builtins.toFile "ubuntnix-etc-${sanitizeStoreName path}" e.text
        else e.source;
      sha256 =
        if isText
        then builtins.hashString "sha256" e.text
        else builtins.hashFile "sha256" e.source;
    in
    { inherit path owner group mode content sha256; };

  render =
    { system ? "x86_64-linux"
    , name ? "etc"
    , entries
    }:
    let
      validated = validate entries;
      normalized = map (path: normalizeEntry path validated.${path}) (builtins.attrNames validated);

      manifest = {
        version = 1;
        entries = map (e: { inherit (e) path sha256 owner group mode; }) normalized;
      };
      manifestFile = builtins.toFile "${name}-manifest.json" (builtins.toJSON manifest);

      # Indexed env attrs (ETC_SRC_0, ETC_SRC_1, ...) rather than
      # name-derived ones: agnostic to whether a future declared path is
      # even a legal derivation env-attr name, and matches
      # nix/archive.nix's `archive-fetch-proof` DEB_<i> precedent for the
      # exact same "toFile-backed script text can't carry derivation-
      # output context; env attrs can" constraint.
      srcEnv = builtins.listToAttrs (lib.imap0
        (i: e: { name = "ETC_SRC_${toString i}"; value = e.content; })
        normalized);

      copyLines = builtins.concatStringsSep "\n" (lib.imap0
        (i: e: ''
          ubxrun "$UBX_BASE/bin/mkdir" -p "$out/tree/${builtins.dirOf e.path}"
          ubxrun "$UBX_BASE/bin/cp" "$ETC_SRC_${toString i}" "$out/tree/${e.path}"
        '')
        normalized);
    in
    runInUbuntuBase {
      inherit system;
      name = "${name}-etc";
      env = srcEnv // { ETC_MANIFEST = manifestFile; };
      script = ''
        ubxrun() {
          "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" "$@"
        }

        ubxrun "$UBX_BASE/bin/mkdir" -p "$out/tree"
        ${copyLines}
        ubxrun "$UBX_BASE/bin/cp" "$ETC_MANIFEST" "$out/manifest.json"
      '';
    };
in
{
  # Exposed under flake.lib (option declared once, in nix/lib.nix; every
  # dendritic file just contributes its own named attribute — same
  # pattern nix/archive.nix uses for flake.lib.archive).
  flake.lib.etc = {
    inherit validate render exceptions exceptionPaths isExceptionPath;
  };

  systems = [ "x86_64-linux" ];

  perSystem = { system, ... }: {
    # etc-proof (issue #26): renders a small fixture declaration end to
    # end (validate -> content-addressed store objects -> tree + JSON
    # manifest) and is asserted against in CI (.github/workflows/ci.yml's
    # "flake" job) the same way archive-fetch-proof/compose-proof prove
    # their own files. A NEGATIVE proof (a bad declaration actually
    # throwing) is deliberately NOT wired up as a `packages.*` output the
    # way archive-hash-mismatch-proof is for nix/archive.nix: `validate`
    # throws at EVALUATION time (a pure Nix `throw`), not at BUILD time
    # (a fixed-output hash mismatch, as in that case) — exposing a
    # throwing call under `packages` would poison `nix flake check`
    # itself (which evaluates every output's shape) for the WHOLE flake,
    # not just fail one targeted `nix build`. Every rejection path
    # instead has a real `throw` proven to exist by a static grep
    # (tests/unit/111-etc-flake-wiring.sh), the same posture
    # tests/unit/041-archive-flake-wiring.sh already takes for
    # nix/archive.nix's own `validate`.
    packages.etc-proof = render {
      inherit system;
      name = "etc-proof";
      entries = {
        "motd" = {
          text = "Welcome to ubuntnix.\n";
        };
        "app/config.json" = {
          text = builtins.toJSON { greeting = "hi"; };
          owner = "root";
          group = "root";
          mode = "0640";
        };
      };
    };
  };
}
