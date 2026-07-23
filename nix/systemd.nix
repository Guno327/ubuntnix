# nix/systemd.nix — the systemd units/services primitive: declaration
# surface + eval-boundary validation + render (SPEC.md §4.3 switching-table
# row 1 "`/etc`, systemd units/services | generate + diff + restart changed
# units (switch-to-configuration equivalent)", §6 "ubuntnix.systemd.units",
# "ubuntnix.systemd.services.X.enable"; GitHub issue #27, milestone M2).
#
# -- What this file is, and what it deliberately is NOT ----------------------
#
# Exactly the same shape and the same reasoning nix/etc.nix's own header
# gives (this file is its direct sibling — read that header first if you
# haven't): a `validate` function (the eval-boundary enforcement the
# primitive-core design calls for) and a `render` function (pure-ish —
# routes every declared unit's bytes through a real Nix store object, never
# spliced as raw shell text) exposed under `flake.lib.systemd`, ready for a
# future `ubuntnix.systemd` module option to call once real module
# evaluation exists (see nix/etc.nix's header for why there is no real
# `options.ubuntnix.*` evaluator yet — same caveat applies verbatim here).
# `perSystem.packages.systemd-proof` (bottom) exercises `render` end to end
# against a small fixture declaration, the same role `etc-proof` plays for
# nix/etc.nix.
#
# This file does NOT diff two generations' unit state against a real,
# running systemd (that's bin/ubx-systemd's job — a pure, on-device
# shell/python planner, per this project's standing rule that logic able to
# run without a `nix` binary belongs in tested shell/python, not the Nix
# layer) and does NOT itself call `systemctl` (that's bin/ubx-systemd-apply,
# a thin executor). What THIS file produces — a content tree plus a JSON
# manifest — is exactly the artifact those two on-device tools consume; see
# "Interface with bin/ubx-systemd / bin/ubx-systemd-apply" below.
#
# -- The declaration surface (SPEC.md §6) -------------------------------
#
# Two attrsets, mirroring the SPEC.md §6 example almost verbatim:
#
#   ubuntnix.systemd.units."myapp.service" = {
#     text = ''
#       [Unit]
#       Description=my app
#       [Service]
#       ExecStart=/usr/bin/myapp
#     '';
#     # source = ./files/myapp.service;   # exactly one of text/source
#     enable = true;                       # default true
#     mask   = false;                      # default false
#   };
#
#   ubuntnix.systemd.services.cups = {
#     enable = false;   # packaged-unit state only -- no content here; the
#     mask   = false;   # unit file itself ships with the `cups` package.
#   };
#
# `units.<name>` declares a FULL unit whose CONTENT this project owns (a
# custom `.service`/`.socket`/`.timer`/... file, content-addressed and
# rendered exactly like nix/etc.nix's entries — see "Rendering" below).
# `services.<name>` declares STATE ONLY for a unit some Ubuntu package
# already ships (SPEC.md §6's own `ubuntnix.systemd.services.cups.enable =
# false` example): no content, a bare service name (no `.service` suffix —
# this primitive always resolves it to exactly that class, since a
# packaged-state-only declaration for anything other than a `.service` unit
# has no SPEC.md example and is out of this issue's scope; a future issue
# can widen `services` to other classes if a real need shows up).
#
# `entries` throughout this file is `{ units; services; }` — `units` an
# attrset name -> `{ text | source; enable?; mask?; }`, `services` an
# attrset bare-name -> `{ enable?; mask?; }`.
#
# -- Unit classes and the refuse-restart rule (issue #27 scope) -------------
#
# Every unit name's suffix maps to a systemd unit "class"; some classes'
# semantics make an automatic restart on content change actively dangerous
# or simply meaningless, so this project's planner (bin/ubx-systemd) NEVER
# blindly restarts them — it plans a diagnostic "refuse-restart" action
# instead (installs the new file, reloads the daemon, but leaves running
# state alone for a human to act on deliberately). The class table (kept as
# data here AND mirrored in bin/ubx-systemd's header — the same
# dual-enforcement posture nix/etc.nix takes for machine-local mutable
# exceptions):
#
#   service, timer, path, scope   -- RESTART-SAFE: a content change is
#                                     applied by stopping and starting the
#                                     unit again; this is exactly what
#                                     "switch-to-configuration" means for
#                                     an ordinary service.
#   socket, mount, swap, target,
#   device, slice                -- REFUSE-RESTART:
#     socket   -- restarting a listening socket unit can drop
#                 already-accepted, in-flight connections and briefly
#                 unbind the address; the safe systemd idiom is to leave a
#                 changed socket unit's *running* instance alone until the
#                 next deliberate restart/reboot.
#     mount    -- restarting (remounting) can fail outright with EBUSY
#                 while anything holds the mountpoint open, and unmounting
#                 live storage out from under running processes is
#                 destructive by construction.
#     swap     -- analogous to mount: toggling swap live changes memory
#                 pressure characteristics; not a switch-to-configuration
#                 decision to make unattended.
#     target   -- a target has no executable state of its own (no
#                 ExecStart); "restarting" one only re-fires the units that
#                 depend on it, which is never what a content-only change
#                 (e.g. a reordered `Wants=`) should trigger by itself.
#     device   -- kernel/udev-managed; not something this tool starts or
#                 stops at all.
#     slice    -- a pure cgroup grouping node, like target: no executable
#                 state to restart.
#
# -- Eval-boundary validation (`validate`) -------------------------------
#
# Every declared entry (in EITHER `units` or `services`) is checked, and
# EVERY violation across the whole declaration is collected into one
# `throw` (never just the first — same posture as nix/etc.nix's `validate`,
# which this mirrors almost exactly):
#   - `units.<name>`: name must be a real unit name -- `[A-Za-z0-9:_.@-]+`
#     followed by exactly one recognized suffix from the class table above
#     (rules out both unsafe characters and an unrecognized/missing
#     class -- this project only ever plans against classes it has a
#     documented rule for);
#   - `units.<name>`: exactly one of `text`/`source` (both or neither is an
#     error -- identical rule to nix/etc.nix's etc entries);
#   - `services.<name>`: name is a BARE service name (no `.`, no suffix --
#     it is always resolved to `<name>.service` internally) matching the
#     same safe-character grammar;
#   - `services.<name>`: `text`/`source` are refused outright (a packaged
#     unit's content is not this project's to declare -- use `units` for
#     a unit this project fully owns);
#   - `enable`/`mask` (both attrsets, wherever set) must be booleans;
#   - no name collision between `units` and `services` once both are
#     resolved to their final `<name>.class` form (e.g. declaring both
#     `units."cups.service"` and `services.cups` is a conflict — two
#     declarations for the same unit, states possibly disagreeing).
#
# -- Rendering (`render`) -------------------------------------------------
#
# Mirrors nix/etc.nix's `render` almost exactly (see that file's header,
# "Rendering", for the full reasoning -- content routed through
# `builtins.toFile`/a source path, never spliced as raw shell text; hashed
# in pure Nix with `builtins.hashString`/`builtins.hashFile`). Output:
#
#   $out/manifest.json     the JSON manifest (schema below)
#   $out/tree/<name>       one regular file per `units.<name>` entry with
#                          content (services entries have none -- nothing
#                          is written under tree/ for them)
#
# -- The manifest schema --------------------------------------------------
#
#   { "version": 1,
#     "units": [
#       { "name": "myapp.service",   # full unit name, always suffixed
#         "class": "service",        # the suffix, minus the leading "."
#         "refuseRestart": false,    # true iff class is in the refuse set
#         "hasContent": true,        # true for a `units.*` entry
#         "sha256": "<64 hex>",      # content hash, or null if !hasContent
#         "enable": true,
#         "mask": false },
#       ... sorted by name (attrset key enumeration is already alphabetical
#       -- see "Determinism" below) ]
#   }
#
# `bin/ubx-systemd` consumes exactly this shape for BOTH its
# `--old-manifest`/`--new-manifest` inputs (its `--observed-manifest` is
# the analogous shape but with `enabled`/`masked`/`active` observed booleans
# in place of the declared `enable`/`mask` -- see that script's own header
# for the full three-manifest contract, which mirrors bin/ubx-etc's).
#
# -- Determinism --------------------------------------------------------
#
# Nix attribute sets are internally kept in sorted-by-name order, so
# `builtins.attrNames` on `units`/`services` already comes back
# alphabetically sorted -- the manifest's `units` array is therefore
# stably ordered by construction, mirroring nix/etc.nix's own "Ordering is
# deterministic for free" comment.
{ config, inputs, ... }:
let
  lib = inputs.nixpkgs.lib;

  inherit (config.flake.lib.stdenv) runInUbuntuBase;

  # -- unit class table (see header, "Unit classes and the refuse-restart
  # rule") -- kept as one attrset mapping suffix -> refuseRestart, so both
  # `validate`/`render` below and bin/ubx-systemd's own mirrored table stay
  # readable side by side.
  unitClasses = {
    service = false;
    timer = false;
    path = false;
    scope = false;
    socket = true;
    mount = true;
    swap = true;
    target = true;
    device = true;
    slice = true;
  };
  suffixes = builtins.attrNames unitClasses;

  # classOf "myapp.service" -> "service"; null if the name doesn't end in
  # one of the recognized suffixes at all.
  classOf = name:
    let
      matching = builtins.filter (s: lib.hasSuffix ".${s}" name) suffixes;
    in
    if matching == [ ] then null else builtins.head matching;

  # Safe-character grammar for the part of a unit name before its suffix --
  # systemd itself allows a broader set, but this project only needs to be
  # at least as strict as a safe Nix store name component once "@"/":"
  # variants are set aside (this project's units don't currently declare
  # templated `@` instances; a real need can widen this later).
  unitNameRe = "^[A-Za-z0-9._-]+\\.(${builtins.concatStringsSep "|" suffixes})$";
  bareNameRe = "^[a-z_][a-z0-9_-]*$";

  unitNameOk = n: builtins.isString n && builtins.match unitNameRe n != null;
  bareNameOk = n: builtins.isString n && builtins.match bareNameRe n != null;

  boolOk = v: builtins.isBool v;

  # -- ubuntnix.systemd.units.<name> validation --------------------------
  checkUnitEntry = name: e:
    let
      hasText = e ? text;
      hasSource = e ? source;
      enable = e.enable or true;
      mask = e.mask or false;
      nameOk = unitNameOk name;
    in
    (if nameOk then [ ] else [ "ubuntnix.systemd.units.\"${toString name}\": not a valid unit name (want [A-Za-z0-9._-]+ followed by one of: ${builtins.concatStringsSep ", " suffixes})" ])
    ++ (if hasText && hasSource then [ "ubuntnix.systemd.units.\"${name}\": both text and source are set (exactly one is required)" ] else [ ])
    ++ (if !hasText && !hasSource then [ "ubuntnix.systemd.units.\"${name}\": neither text nor source is set (exactly one is required)" ] else [ ])
    ++ (if boolOk enable then [ ] else [ "ubuntnix.systemd.units.\"${name}\": enable must be a boolean" ])
    ++ (if boolOk mask then [ ] else [ "ubuntnix.systemd.units.\"${name}\": mask must be a boolean" ]);

  # -- ubuntnix.systemd.services.<name> validation -----------------------
  checkServiceEntry = name: e:
    let
      hasText = e ? text;
      hasSource = e ? source;
      enable = e.enable or true;
      mask = e.mask or false;
      nameOk = bareNameOk name;
    in
    (if nameOk then [ ] else [ "ubuntnix.systemd.services.\"${toString name}\": not a valid bare service name (want ${bareNameRe}, no suffix -- it always resolves to <name>.service)" ])
    ++ (if hasText || hasSource then [ "ubuntnix.systemd.services.\"${name}\": text/source are not accepted here -- this is packaged-unit STATE ONLY (enable/mask); declare full unit content under ubuntnix.systemd.units instead" ] else [ ])
    ++ (if boolOk enable then [ ] else [ "ubuntnix.systemd.services.\"${name}\": enable must be a boolean" ])
    ++ (if boolOk mask then [ ] else [ "ubuntnix.systemd.services.\"${name}\": mask must be a boolean" ]);

  # -- cross-attrset collision check --------------------------------------
  resolvedUnitNames = units: builtins.attrNames units;
  resolvedServiceNames = services: map (n: "${n}.service") (builtins.attrNames services);

  checkCollisions = units: services:
    let
      us = resolvedUnitNames units;
      ss = resolvedServiceNames services;
      dupes = builtins.filter (n: builtins.elem n us) ss;
    in
    map (n: "\"${n}\" is declared by both ubuntnix.systemd.units and ubuntnix.systemd.services -- exactly one declaration per unit is allowed") dupes;

  validate = entries:
    let
      units = entries.units or { };
      services = entries.services or { };
      errors =
        (builtins.concatLists (map (n: checkUnitEntry n units.${n}) (builtins.attrNames units)))
        ++ (builtins.concatLists (map (n: checkServiceEntry n services.${n}) (builtins.attrNames services)))
        ++ (checkCollisions units services);
    in
    if errors == [ ]
    then entries
    else
      throw ''
        ubuntnix.systemd failed eval-boundary validation (SPEC.md §4.3, §6; nix/systemd.nix):
        ${builtins.concatStringsSep "\n" (map (e: "  - ${e}") errors)}'';

  # -- rendering (see header, "Rendering") -------------------------------
  sanitizeStoreName = name: builtins.replaceStrings [ "/" "@" ":" ] [ "_" "_" "_" ] name;

  normalizeUnitEntry = name: e:
    let
      enable = e.enable or true;
      mask = e.mask or false;
      isText = e ? text;
      content =
        if isText
        then builtins.toFile "ubuntnix-systemd-${sanitizeStoreName name}" e.text
        else e.source;
      sha256 =
        if isText
        then builtins.hashString "sha256" e.text
        else builtins.hashFile "sha256" e.source;
      class = classOf name;
    in
    {
      inherit name enable mask content sha256;
      class = class;
      refuseRestart = unitClasses.${class};
      hasContent = true;
    };

  normalizeServiceEntry = name: e:
    let
      enable = e.enable or true;
      mask = e.mask or false;
      fullName = "${name}.service";
    in
    {
      name = fullName;
      inherit enable mask;
      content = null;
      sha256 = null;
      class = "service";
      refuseRestart = false;
      hasContent = false;
    };

  render =
    { system ? "x86_64-linux"
    , name ? "systemd"
    , entries
    }:
    let
      validated = validate entries;
      units = validated.units or { };
      services = validated.services or { };

      normalizedUnits = map (n: normalizeUnitEntry n units.${n}) (builtins.attrNames units);
      normalizedServices = map (n: normalizeServiceEntry n services.${n}) (builtins.attrNames services);
      # Concatenated then sorted by name -- units/services are declared in
      # two separate attrsets, so unlike nix/etc.nix's single-attrset case
      # this file needs one explicit sort to get a single, fully
      # name-ordered manifest array (checkCollisions above already
      # guarantees no two entries share a name).
      allNormalized = builtins.sort (a: b: a.name < b.name) (normalizedUnits ++ normalizedServices);

      manifest = {
        version = 1;
        units = map (e: { inherit (e) name class refuseRestart hasContent sha256 enable mask; }) allNormalized;
      };
      manifestFile = builtins.toFile "${name}-manifest.json" (builtins.toJSON manifest);

      contentEntries = builtins.filter (e: e.hasContent) allNormalized;
      srcEnv = builtins.listToAttrs (lib.imap0
        (i: e: { name = "SYSTEMD_SRC_${toString i}"; value = e.content; })
        contentEntries);

      copyLines = builtins.concatStringsSep "\n" (lib.imap0
        (i: e: ''
          ubxrun "$UBX_BASE/bin/cp" "$SYSTEMD_SRC_${toString i}" "$out/tree/${e.name}"
        '')
        contentEntries);
    in
    runInUbuntuBase {
      inherit system;
      name = "${name}-systemd";
      env = srcEnv // { SYSTEMD_MANIFEST = manifestFile; };
      script = ''
        ubxrun() {
          "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" "$@"
        }

        ubxrun "$UBX_BASE/bin/mkdir" -p "$out/tree"
        ${copyLines}
        ubxrun "$UBX_BASE/bin/cp" "$SYSTEMD_MANIFEST" "$out/manifest.json"
      '';
    };
in
{
  # Exposed under flake.lib (option declared once, in nix/lib.nix; every
  # dendritic file just contributes its own named attribute -- same
  # pattern nix/etc.nix uses for flake.lib.etc).
  flake.lib.systemd = {
    inherit validate render unitClasses classOf;
  };

  systems = [ "x86_64-linux" ];

  perSystem = { system, ... }: {
    # systemd-proof (issue #27): renders a small fixture declaration end to
    # end (validate -> content-addressed store objects -> tree + JSON
    # manifest), exercising both a fully-owned unit (`units`) and a
    # packaged-state-only entry (`services`) -- mirrors nix/etc.nix's
    # etc-proof. As with that proof, a NEGATIVE case (a bad declaration
    # actually throwing) is deliberately NOT wired up as a `packages.*`
    # output -- see nix/etc.nix's own comment on `etc-proof` for why
    # (poisoning `nix flake check` for the whole flake); every rejection
    # path instead has a real `throw` proven to exist by a static grep
    # (tests/unit/121-systemd-flake-wiring.sh), the same posture
    # tests/unit/111-etc-flake-wiring.sh already takes for nix/etc.nix.
    packages.systemd-proof = render {
      inherit system;
      name = "systemd-proof";
      entries = {
        units = {
          "ubuntnix-example.service" = {
            text = ''
              [Unit]
              Description=ubuntnix example service (systemd-proof fixture)

              [Service]
              ExecStart=/usr/bin/true

              [Install]
              WantedBy=multi-user.target
            '';
          };
        };
        services = {
          cups = { enable = false; };
        };
      };
    };
  };
}
