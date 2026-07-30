# nix/home.nix — the per-user "home" primitive: declarative $HOME files
# (incl. XDG config, since those are just paths under $HOME) and per-user
# systemd --user services, using the SAME module-machinery shape
# nix/etc.nix / nix/systemd.nix already established for the system layer
# (SPEC.md §9 "Per-user configuration (home modules)", §4.3 switching-table
# row "Home files, user services | home-module activation into writable
# `/home` | none"; GitHub issue #98, milestone M5).
#
# -- What this file is, and what it deliberately is NOT ----------------------
#
# Exactly the shape nix/etc.nix's own header establishes (this file is its
# direct sibling — read that file's header first if you haven't, and
# nix/systemd.nix's right after, since this file is best understood as
# "nix/etc.nix's file-entry primitive and nix/systemd.nix's unit-entry
# primitive, each re-scoped per declared user"): a `validate` function
# (eval-boundary enforcement) and a `render` function (pure-ish — every
# declared entry's bytes are routed through a real Nix store object, never
# spliced as raw shell text — identical reasoning to nix/etc.nix's own
# "Rendering" section) exposed under `flake.lib.home`, ready for a future
# `ubuntnix.home` module option to call once real module evaluation exists
# (nix/etc.nix's "no modules/ tree yet" caveat applies verbatim here).
# `perSystem.packages.home-proof` (bottom) exercises `render` end to end
# against a small fixture declaration, the same role `etc-proof`/
# `systemd-proof` play for their own files.
#
# This file does NOT diff two generations' home state against a real
# filesystem, does NOT call `install`/`chown`/`systemctl --user`, and does
# NOT decide symlink-vs-copy for a running machine's real `/home` — that is
# bin/ubx-home's (a pure, on-device planner) and bin/ubx-home-apply's (a
# thin executor) job, mirroring bin/ubx-etc/bin/ubx-etc-apply and
# bin/ubx-systemd/bin/ubx-systemd-apply's own split exactly. What THIS file
# produces — a content tree plus a JSON manifest — is exactly the artifact
# those two on-device tools consume; see "Interface with bin/ubx-home /
# bin/ubx-home-apply" below.
#
# Per-user *software* (snaps/debs) is explicitly OUT of this file's scope —
# SPEC.md §9 is unambiguous: "per-user software is system-level (snaps/
# debs) selected per-user via modules; no per-user binary installation
# exists in this model." This primitive only ever materializes FILES and
# SERVICE UNITS into a user's own $HOME; it has no notion of installing a
# package.
#
# -- The declaration surface (SPEC.md §9) --------------------------------
#
#   ubuntnix.home.gunnar.files."\.bashrc" = {
#     text = ''...'';                # exactly one of text/source
#     # source = ./files/bashrc;
#     mode  = "0644";                # default "0644"
#   };
#   ubuntnix.home.gunnar.files.".config/foo/config.toml" = {
#     text = ''...'';
#   };
#
#   ubuntnix.home.gunnar.services."backup.service" = {
#     text = ''
#       [Unit]
#       Description=example per-user backup timer target
#       [Service]
#       ExecStart=/usr/bin/true
#     '';
#     enable = true;                 # default true
#     mask   = false;                # default false
#   };
#
# `ubuntnix.home` is keyed by declared username (SPEC.md §9: "same module
# machinery as the system layer, dendritic files contribute to both" — this
# primitive is deliberately independent of nix/users.nix's own `userType`,
# the same way nix/systemd.nix's `services` needs no cross-import from
# nix/users.nix either; both are self-contained dendritic files per this
# project's own layout rule, SPEC.md §2 G8).
#
# Unlike nix/etc.nix's entries, a home file entry has NO owner/group knob:
# SPEC.md §9's own activation contract is "materializes home files with
# correct ownership into /home/<user>" — a home file is ALWAYS owned by the
# user whose namespace declared it, full stop, so there is nothing for a
# declaration to override (a knob that could only ever safely be set to one
# value is not a knob worth having — same reasoning nix/systemd.nix's
# `services.<name>` gives for refusing `text`/`source`: fewer things a
# declaration can get wrong).
#
# Unlike nix/systemd.nix's TWO declaration surfaces (`units`, fully-owned
# content, vs `services`, packaged-state-only), a home service is ALWAYS
# fully-owned content — a user has no "packaged unit" analog to toggle
# state on (SPEC.md §9's own "no per-user binary installation" rules out
# ever having installed one to toggle in the first place) — so
# `ubuntnix.home.<user>.services` only ever takes nix/systemd.nix's `units`
# shape, never its `services` shape.
#
# -- Unit classes: restart-safe only (a deliberately narrower table) --------
#
# nix/systemd.nix's own class table includes several classes
# (socket/mount/swap/target/device/slice) whose *system* semantics justify
# a refuse-restart escape hatch (see that file's header for the full
# reasoning). None of those make sense as a PER-USER primitive scoped to
# `systemctl --user`: a user session has no mount/swap/device units at all,
# and a bare user target/slice has no executable state a home declaration
# would ever need to author directly. This file therefore only recognizes
# the three classes that are both meaningful under `systemctl --user` AND
# already restart-safe in nix/systemd.nix's own table: `service`, `timer`,
# `path`. There is consequently no refuse-restart concept here at all (see
# bin/ubx-home's own header for the planner-side consequence: no
# `refuse-restart` action ever exists in a home plan).
#
# -- Eval-boundary validation (`validate`) -------------------------------
#
# Every declared user's `files`/`services` entries are checked, and EVERY
# violation across the WHOLE declaration is collected into one `throw`
# (never just the first — same posture nix/etc.nix's/nix/systemd.nix's own
# `validate` take):
#   - the username itself must look like a real username (mirrors
#     nix/users.nix's own `nameRe` — duplicated rather than imported, for
#     the same "dendritic files are self-contained" reason
#     nix/users.nix's own header gives for duplicating nix/secrets.nix's
#     `nameRe` rather than importing it);
#   - `files.<path>`: relative, no empty/'.'/'..' segment, safe character
#     class (identical rule and identical reasoning to nix/etc.nix's own
#     `pathOk` — duplicated here rather than imported, since this project's
#     dendritic files do not cross-import each other's internals, only
#     their exposed `flake.lib.*` surface, and even that only from a real
#     module-evaluation caller neither file has yet);
#   - `files.<path>`: exactly one of `text`/`source`;
#   - `files.<path>`: `mode` is 4 octal digits;
#   - `services.<name>`: a valid unit name ending in one of `.service`/
#     `.timer`/`.path` (see "Unit classes" above);
#   - `services.<name>`: exactly one of `text`/`source`;
#   - `services.<name>`: `enable`/`mask` are booleans.
#
# -- Rendering (`render`) -------------------------------------------------
#
# Mirrors nix/etc.nix's `render` almost exactly (see that file's header,
# "Rendering", for the full reasoning) — content routed through
# `builtins.toFile`/a source path, hashed with `builtins.hashString`/
# `builtins.hashFile`, copied into the output tree via the shared
# `runInUbuntuBase` "ubxrun" pattern, never spliced as raw shell text.
#
# -- Interface with bin/ubx-home / bin/ubx-home-apply ------------------------
#
# `render`'s `$out` mirrors nix/etc.nix's own two-thing contract:
#   $out/manifest.json                     the JSON manifest (schema below)
#   $out/tree/<user>/files/<path>          one regular file per files entry
#   $out/tree/<user>/services/<name>       one regular file per services entry
#
# The manifest schema:
#   { "version": 1,
#     "users": [
#       { "name": "gunnar",
#         "files": [ { "path": ".bashrc", "sha256": <64 hex>, "mode": "0644" },
#                    ... sorted by path ],
#         "services": [ { "name": "backup.service", "class": "service",
#                          "sha256": <64 hex>, "enable": true, "mask": false },
#                        ... sorted by name ] },
#       ... sorted by username ] }
#
# `bin/ubx-home` consumes exactly this shape for BOTH its
# `--old-manifest`/`--new-manifest` inputs, mirroring bin/ubx-etc's/
# bin/ubx-systemd's own two-generation-manifests-plus-one-observed-manifest
# contract (see that script's own header for the full three-manifest
# planning story and the observed-manifest schema it additionally defines).
#
# -- Determinism --------------------------------------------------------
#
# Nix attribute sets are internally kept in sorted-by-name order, so
# `builtins.attrNames` on `users`, and on each user's own `files`/
# `services`, already comes back alphabetically sorted — every array in the
# manifest above is therefore stably ordered by construction, with no
# explicit sort step, mirroring nix/etc.nix's/nix/systemd.nix's own
# "Ordering/Determinism is deterministic for free" comments.
{ config, inputs, ... }:
let
  lib = inputs.nixpkgs.lib;

  inherit (config.flake.lib.stdenv) runInUbuntuBase;

  # -- username grammar -- mirrors nix/users.nix's own `nameRe` verbatim
  # (see this file's header for why it's duplicated, not imported).
  userNameRe = "^[a-z_][a-z0-9_-]{0,31}$";
  userNameOk = n: builtins.isString n && builtins.match userNameRe n != null;

  modeRe = "0[0-7]{3}";
  modeOk = m: builtins.isString m && builtins.match modeRe m != null;

  # -- file path grammar -- identical to nix/etc.nix's own pathOk/segmentOk
  # (see that file's header, "Eval-boundary validation", for the full
  # reasoning; duplicated here for the same "dendritic files are
  # self-contained" reason given above).
  segmentOk = seg: seg != "" && seg != "." && seg != ".." && builtins.match "[A-Za-z0-9._-]+" seg != null;
  pathOk = path: builtins.isString path && path != "" && builtins.all segmentOk (lib.splitString "/" path);

  # -- unit class table -- see this file's header, "Unit classes:
  # restart-safe only", for why this table is deliberately narrower than
  # nix/systemd.nix's own.
  suffixes = [ "service" "timer" "path" ];
  unitNameRe = "^[A-Za-z0-9._-]+\\.(${builtins.concatStringsSep "|" suffixes})$";
  unitNameOk = n: builtins.isString n && builtins.match unitNameRe n != null;

  classOf = name:
    let matching = builtins.filter (s: lib.hasSuffix ".${s}" name) suffixes;
    in if matching == [ ] then null else builtins.head matching;

  boolOk = v: builtins.isBool v;

  # -- per-file validation (mirrors nix/etc.nix's checkEtcEntry, minus the
  # owner/group checks this file's declaration surface never accepts) ------
  checkFileEntry = user: path: e:
    let
      hasText = e ? text;
      hasSource = e ? source;
      mode = e.mode or "0644";
      pOk = pathOk path;
    in
    (if pOk then [ ] else [ "ubuntnix.home.\"${user}\".files.\"${toString path}\": path must be relative, with no empty/'.'/'..' segment, using only [A-Za-z0-9._-] per segment" ])
    ++ (if hasText && hasSource then [ "ubuntnix.home.\"${user}\".files.\"${path}\": both text and source are set (exactly one is required)" ] else [ ])
    ++ (if !hasText && !hasSource then [ "ubuntnix.home.\"${user}\".files.\"${path}\": neither text nor source is set (exactly one is required)" ] else [ ])
    ++ (if modeOk mode then [ ] else [ "ubuntnix.home.\"${user}\".files.\"${path}\": mode \"${toString mode}\" must be 4 octal digits as a string, e.g. \"0644\"" ]);

  # -- per-service validation (mirrors nix/systemd.nix's checkUnitEntry) ---
  checkServiceEntry = user: name: e:
    let
      hasText = e ? text;
      hasSource = e ? source;
      enable = e.enable or true;
      mask = e.mask or false;
      nameOk = unitNameOk name;
    in
    (if nameOk then [ ] else [ "ubuntnix.home.\"${user}\".services.\"${toString name}\": not a valid unit name (want [A-Za-z0-9._-]+ followed by one of: ${builtins.concatStringsSep ", " suffixes})" ])
    ++ (if hasText && hasSource then [ "ubuntnix.home.\"${user}\".services.\"${name}\": both text and source are set (exactly one is required)" ] else [ ])
    ++ (if !hasText && !hasSource then [ "ubuntnix.home.\"${user}\".services.\"${name}\": neither text nor source is set (exactly one is required)" ] else [ ])
    ++ (if boolOk enable then [ ] else [ "ubuntnix.home.\"${user}\".services.\"${name}\": enable must be a boolean" ])
    ++ (if boolOk mask then [ ] else [ "ubuntnix.home.\"${user}\".services.\"${name}\": mask must be a boolean" ]);

  checkUserEntry = user: decl:
    let
      files = decl.files or { };
      services = decl.services or { };
      userOk = userNameOk user;
    in
    (if userOk then [ ] else [ "ubuntnix.home.\"${toString user}\": not a valid username (must match ${userNameRe})" ])
    ++ (builtins.concatLists (map (p: checkFileEntry user p files.${p}) (builtins.attrNames files)))
    ++ (builtins.concatLists (map (n: checkServiceEntry user n services.${n}) (builtins.attrNames services)));

  validate = users:
    let
      errors = builtins.concatLists (map (u: checkUserEntry u users.${u}) (builtins.attrNames users));
    in
    if errors == [ ]
    then users
    else
      throw ''
        ubuntnix.home failed eval-boundary validation (SPEC.md §9; nix/home.nix):
        ${builtins.concatStringsSep "\n" (map (e: "  - ${e}") errors)}'';

  # -- rendering ------------------------------------------------------------
  sanitizeStoreName = s: builtins.replaceStrings [ "/" "@" ":" ] [ "_" "_" "_" ] s;

  normalizeFileEntry = user: path: e:
    let
      mode = e.mode or "0644";
      isText = e ? text;
      content =
        if isText
        then builtins.toFile "ubuntnix-home-${sanitizeStoreName user}-${sanitizeStoreName path}" e.text
        else e.source;
      sha256 =
        if isText
        then builtins.hashString "sha256" e.text
        else builtins.hashFile "sha256" e.source;
    in
    { inherit path mode content sha256; };

  normalizeServiceEntry = user: name: e:
    let
      enable = e.enable or true;
      mask = e.mask or false;
      isText = e ? text;
      content =
        if isText
        then builtins.toFile "ubuntnix-home-svc-${sanitizeStoreName user}-${sanitizeStoreName name}" e.text
        else e.source;
      sha256 =
        if isText
        then builtins.hashString "sha256" e.text
        else builtins.hashFile "sha256" e.source;
    in
    { inherit name enable mask content sha256; class = classOf name; };

  normalizeUser = user: decl:
    let
      files = decl.files or { };
      services = decl.services or { };
    in
    {
      name = user;
      files = map (p: normalizeFileEntry user p files.${p}) (builtins.attrNames files);
      services = map (n: normalizeServiceEntry user n services.${n}) (builtins.attrNames services);
    };

  render =
    { system ? "x86_64-linux"
    , name ? "home"
    , users
    }:
    let
      validated = validate users;
      normalizedUsers = map (u: normalizeUser u validated.${u}) (builtins.attrNames validated);

      manifest = {
        version = 1;
        users = map
          (u: {
            inherit (u) name;
            files = map (f: { inherit (f) path sha256 mode; }) u.files;
            services = map (s: { inherit (s) name class sha256 enable mask; }) u.services;
          })
          normalizedUsers;
      };
      manifestFile = builtins.toFile "${name}-manifest.json" (builtins.toJSON manifest);

      # Every file/service entry across every user, flattened with its own
      # destination tree path, indexed exactly like nix/etc.nix's own
      # ETC_SRC_<i> env attrs (see that file's header for why: a toFile-
      # backed script's own text can't carry derivation-output context
      # inline, only derivation ENV ATTRS may).
      allContent = builtins.concatMap
        (u:
          (map (f: { dest = "${u.name}/files/${f.path}"; inherit (f) content; }) u.files)
          ++ (map (s: { dest = "${u.name}/services/${s.name}"; inherit (s) content; }) u.services))
        normalizedUsers;

      srcEnv = builtins.listToAttrs (lib.imap0
        (i: e: { name = "HOME_SRC_${toString i}"; value = e.content; })
        allContent);

      copyLines = builtins.concatStringsSep "\n" (lib.imap0
        (i: e: ''
          ubxrun "$UBX_BASE/bin/mkdir" -p "$out/tree/${builtins.dirOf e.dest}"
          ubxrun "$UBX_BASE/bin/cp" "$HOME_SRC_${toString i}" "$out/tree/${e.dest}"
        '')
        allContent);
    in
    runInUbuntuBase {
      inherit system;
      name = "${name}-home";
      env = srcEnv // { HOME_MANIFEST = manifestFile; };
      script = ''
        ubxrun() {
          "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" "$@"
        }

        ubxrun "$UBX_BASE/bin/mkdir" -p "$out/tree"
        ${copyLines}
        ubxrun "$UBX_BASE/bin/cp" "$HOME_MANIFEST" "$out/manifest.json"
      '';
    };
in
{
  flake.lib.home = {
    inherit validate render classOf suffixes;
  };

  systems = [ "x86_64-linux" ];

  perSystem = { system, ... }: {
    # home-proof (issue #98): renders a small fixture declaration (one user,
    # one file, one service) end to end, exercising both files and
    # services -- mirrors nix/etc.nix's etc-proof / nix/systemd.nix's
    # systemd-proof. A NEGATIVE case (a bad declaration actually throwing)
    # is deliberately NOT wired up as a `packages.*` output either -- see
    # nix/etc.nix's own comment on `etc-proof` for why (poisoning `nix
    # flake check` for the whole flake); every rejection path instead has a
    # real `throw` proven to exist by a static grep
    # (tests/unit/182-home-flake-wiring.sh), the same posture
    # tests/unit/111-etc-flake-wiring.sh already takes for nix/etc.nix.
    packages.home-proof = render {
      inherit system;
      name = "home-proof";
      users = {
        gunnar = {
          files = {
            ".bashrc" = {
              text = "# ubuntnix home-proof fixture\nexport EDITOR=vim\n";
            };
            ".config/foo/config.toml" = {
              text = "greeting = \"hi\"\n";
              mode = "0640";
            };
          };
          services = {
            "ubuntnix-home-example.service" = {
              text = ''
                [Unit]
                Description=ubuntnix per-user example service (home-proof fixture)

                [Service]
                ExecStart=/usr/bin/true
              '';
            };
          };
        };
      };
    };
  };
}
