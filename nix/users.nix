# nix/users.nix — the users primitive: declaration surface + eval-time
# validation + JSON manifest rendering (SPEC.md §4.3 "Users" row, §6, §7;
# GitHub issue #28, milestone M2).
#
# -- What this file is, and isn't ------------------------------------------
#
# SPEC.md §6 lists `users` as one of the closed, parity-audited primitives
# and gives its shape as:
#   ubuntnix.users.gunnar = {
#     groups = [ "sudo" ]; shell = "/usr/bin/bash";
#     hashedPasswordSecret = "gunnarPassword";       # -> secrets index
#   };
# `hashedPasswordSecret` is explicitly OUT OF SCOPE here — SPEC.md §11 M2
# spells out "users primitive (interim auth via SSH keys — secret-backed
# passwords complete in M4)" — so this file adds `authorizedKeys` (a plain
# list of SSH public key strings) as the M2 interim auth surface instead,
# and leaves the password-hash field for M4 to add once the secrets index
# (§8.1) exists to source it from.
#
# This file does exactly two things, deliberately kept thin (the PM's own
# design guidance for this issue: "keep the nix layer thin and push logic
# into the tested planner"):
#   1. declares the `users`/`groups` submodule TYPES (option names, types,
#      defaults) and validates a declared `{ users, groups }` attrset
#      against them at the EVAL boundary — via `lib.evalModules`, the same
#      machinery a real NixOS-style option uses, rather than hand-rolled
#      type checking (that gets every option's type coercion/merging/
#      default-application behavior for free, and gives ordinary Nix module
#      system error messages on a bad declaration);
#   2. renders the validated set to a flat, deterministic JSON manifest.
# It does NOT attempt convergence against observed system state (parsing
# /etc/passwd, deciding what to create/modify, uid/gid allocation, drift
# detection, ...) — that is `bin/ubx-users`' job entirely (a pure planner,
# unit-tested under tests/unit/ with fixture passwd/group/shadow files, no
# `nix` binary needed to exercise it — this dev harness has none; see this
# repo's other nix/*.nix files' own headers for the same caveat). See
# docs/users.md for the full manifest/plan schema and the planner/executor
# split this enables (SPEC.md §4.3: "Users | converge passwd/groups state |
# none [downtime]" — the plan/execute split is what makes that testable
# without systemd, exactly like the M2 guards work, issue #31, kept guard
# logic and image-wiring separate).
#
# -- The manifest schema ----------------------------------------------------
#
# `renderManifestJSON (mkManifest { users = {...}; groups = {...}; })`
# produces:
#   {
#     "version": 1,
#     "users": [
#       { "name": ..., "uid": <int|null>, "system": <bool>,
#         "shell": "/usr/bin/bash", "home": <str|null>,
#         "createHome": <bool>, "groups": [ ... ],
#         "authorizedKeys": [ "ssh-ed25519 AAAA... comment", ... ] },
#       ... sorted by name (Nix attrset key enumeration -- builtins.attrNames
#       -- is already alphabetical; see "Determinism" below)
#     ],
#     "groups": [
#       { "name": ..., "gid": <int|null>, "system": <bool> },
#       ... sorted by name
#     ]
#   }
# `home: null` means "let the planner default it to /home/<name>" (kept
# here rather than baked in, so the planner's own default is the single
# source of truth bin/ubx-users' own header documents — see that file).
# Every `uid`/`gid` left `null` means "the planner auto-allocates one",
# per-user/per-group; `system` (mirrors `useradd -r` / `groupadd -r`)
# decides which range the planner allocates from (bin/ubx-users' own
# SYS_UID_MIN/MAX vs UID_MIN/MAX constants — see that file).
#
# -- Determinism --------------------------------------------------------
#
# Nix attribute sets are internally kept in sorted-by-name order (this is
# an implementation property of the evaluator itself, not something this
# file arranges), so `builtins.attrNames users`/`builtins.attrNames groups`
# already comes back alphabetically sorted -- the `users`/`groups` JSON
# arrays below are therefore stably ordered by construction, without an
# explicit sort call, and `builtins.toJSON` on the resulting attrsets emits
# each object's own fields in that same internal (alphabetical) order. Two
# evaluations of the same declared input are therefore guaranteed
# byte-identical, matching this repo's determinism culture (see
# nix/archive.nix's `emit_lockfile`/bin/ubx-resolve's own sort-by-name
# comments for the same property enforced on the shell/python side).
{ config, inputs, ... }:
let
  lib = inputs.nixpkgs.lib;

  # Username/group-name grammar: mirrors shadow-utils' own default
  # NAME_REGEX (/etc/login.defs, useradd(8)/groupadd(8)) closely enough for
  # this project's own purposes -- lowercase start, then lowercase
  # alphanumerics/underscore/hyphen, max 32 chars total (31 after the first
  # char) -- rather than reimplementing its full (locale-dependent) grammar.
  nameRe = "^[a-z_][a-z0-9_-]{0,31}$";

  # An authorizedKeys entry must be exactly one key LINE: at least two
  # whitespace-separated fields (type + base64 blob, optional trailing
  # comment), no embedded tab/newline. This is intentionally light --
  # exactly as conservative as nix/compose.nix's own `renderPreseed` is
  # about its own string inputs (reject the clearly-broken shapes; leave
  # deep semantic validation, e.g. "is this base64 blob actually a valid
  # Ed25519 key", to sshd itself at use time).
  keyLineRe = "^[^ \t\n]+ [^ \t\n]+.*$";

  # -- userType / groupType -------------------------------------------------
  #
  # Reusable submodule TYPES (not yet wired to a real `options.ubuntnix.*`
  # -- no machine-config evaluator consumes that surface from THIS repo yet,
  # since ubuntnix's own flake never evaluates a machine's `ubuntnix.users`
  # itself; a future machine flake's module system is expected to import
  # these types directly, e.g. `lib.types.attrsOf flake.lib.users.userType`
  # for its own `options.ubuntnix.users`). `mkManifest` below uses them the
  # same way, via its own self-contained `lib.evalModules` call, so the
  # validation behavior this file promises is real and exercised today, not
  # just declared for later.
  userType = lib.types.submodule {
    options = {
      groups = lib.mkOption {
        type = lib.types.listOf (lib.types.strMatching nameRe);
        default = [ ];
        description = "Supplementary (secondary) group names this user belongs to.";
      };
      shell = lib.mkOption {
        type = lib.types.strMatching "^/.*";
        default = "/usr/bin/bash";
        description = "Login shell -- an absolute path.";
      };
      createHome = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether the planner creates this user's home directory (useradd -m vs -M).";
      };
      home = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "^/.*");
        default = null;
        description = "Home directory, an absolute path. Left null, the planner defaults it to /home/<name>.";
      };
      uid = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "Explicit uid. Left null, the planner allocates one from the range `system` selects.";
      };
      system = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          System account (mirrors `useradd -r`): the planner allocates an
          auto uid/gid from the system range instead of the normal range
          when `uid`/a referenced group's `gid` is left unset. Has no
          effect on an explicit `uid` -- that is always honored verbatim.
        '';
      };
      authorizedKeys = lib.mkOption {
        type = lib.types.listOf (lib.types.strMatching keyLineRe);
        default = [ ];
        description = ''
          SSH public key lines materialized to
          ~<user>/.ssh/authorized_keys (0700 dir / 0600 file) by the
          planner/executor. Interim M2 auth surface -- SPEC.md §11 M2:
          hashed passwords sourced from the secrets index are M4 scope
          (`hashedPasswordSecret` in SPEC.md §6's own example is
          deliberately not declared here yet).
        '';
      };
    };
  };

  groupType = lib.types.submodule {
    options = {
      gid = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "Explicit gid. Left null, the planner allocates one from the range `system` selects.";
      };
      system = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "System group (mirrors `groupadd -r`): the planner allocates an auto gid from the system range instead of the normal range.";
      };
    };
  };

  # evalDeclared -- runs a declared `{ users, groups }` attrset (SPEC.md
  # §6's `ubuntnix.users.<name> = { ... };` shape, `ubuntnix.groups.<name>`
  # likewise for standalone group declarations -- e.g. a custom group with
  # an explicit gid that no user need reference) through the real Nix
  # module system, self-contained: no external machine flake is needed to
  # exercise real option type-checking/defaulting here.
  evalDeclared = { users ? { }, groups ? { } }:
    (lib.evalModules {
      modules = [{
        options.users = lib.mkOption { type = lib.types.attrsOf userType; default = { }; };
        options.groups = lib.mkOption { type = lib.types.attrsOf groupType; default = { }; };
        config = { inherit users groups; };
      }];
    }).config;

  # checkManifest -- cross-field checks the submodule TYPES above cannot
  # express by themselves: attribute-set KEYS (the declared names
  # themselves) aren't covered by a value type, and "no two siblings
  # collide" checks need the whole set at once, not one entry in isolation.
  # Mirrors nix/archive.nix's own `validate`: one throw enumerating EVERY
  # violation found, not just the first.
  #
  # Deliberately NOT checked here (this is the planner's job, against
  # OBSERVED system state -- Nix eval has no such state to check against):
  # whether a declared uid/gid collides with a FOREIGN, non-declared
  # account already on a real machine. See bin/ubx-users' own header for
  # that half of "uid conflict detection".
  checkManifest = users: groups:
    let
      userNames = builtins.attrNames users;
      groupNames = builtins.attrNames groups;

      badUserNames = builtins.filter (n: builtins.match nameRe n == null) userNames;
      badGroupNames = builtins.filter (n: builtins.match nameRe n == null) groupNames;

      # name -> declared uid, for every user with an EXPLICIT (non-null) uid.
      explicitUids = lib.filterAttrs (_: u: u.uid != null) users;
      uidGroups = lib.groupBy (n: toString explicitUids.${n}.uid) (builtins.attrNames explicitUids);
      duplicateUidGroups = lib.filterAttrs (_: names: builtins.length names > 1) uidGroups;

      explicitGids = lib.filterAttrs (_: g: g.gid != null) groups;
      gidGroups = lib.groupBy (n: toString explicitGids.${n}.gid) (builtins.attrNames explicitGids);
      duplicateGidGroups = lib.filterAttrs (_: names: builtins.length names > 1) gidGroups;
    in
    (map (n: ''ubuntnix.users."${n}": not a valid username (must match ${nameRe})'') badUserNames)
    ++ (map (n: ''ubuntnix.groups."${n}": not a valid group name (must match ${nameRe})'') badGroupNames)
    ++ (lib.mapAttrsToList
      (uid: names: "duplicate explicit uid ${uid} declared by: ${builtins.concatStringsSep ", " (builtins.sort (a: b: a < b) names)}")
      duplicateUidGroups)
    ++ (lib.mapAttrsToList
      (gid: names: "duplicate explicit gid ${gid} declared by: ${builtins.concatStringsSep ", " (builtins.sort (a: b: a < b) names)}")
      duplicateGidGroups);

  # mkManifest -- the file's main entry point: `{ users, groups }` (SPEC.md
  # §6 shape) -> the validated, JSON-ready manifest attrset. `throw`s with
  # every violation found (checkManifest above) on a bad declaration,
  # exactly like nix/archive.nix's `validate`/nix/compose.nix's
  # `renderPreseed`.
  mkManifest = declared:
    let
      evaled = evalDeclared declared;
      errors = checkManifest evaled.users evaled.groups;
    in
    if errors != [ ] then
      throw ''
        ubuntnix.users / ubuntnix.groups failed validation (SPEC.md §6, §4.3 "Users"):
        ${builtins.concatStringsSep "\n" (map (e: "  - ${e}") errors)}''
    else {
      version = 1;
      users = map
        (n: evaled.users.${n} // { name = n; })
        (builtins.attrNames evaled.users);
      groups = map
        (n: evaled.groups.${n} // { name = n; })
        (builtins.attrNames evaled.groups);
    };

  # renderManifestJSON -- pure attrset -> JSON text (trailing newline, for a
  # well-formed text file). See "Determinism" in this file's header for why
  # no explicit sort is needed here.
  renderManifestJSON = manifest: builtins.toJSON manifest + "\n";

  # exampleManifest -- a small, fixed declared set used only to FORCE this
  # file's own validate/render pipeline during ordinary flake evaluation
  # (see `users-manifest-proof` below): merely constructing a derivation
  # that references `renderManifestJSON exampleManifest` inside its `script`
  # forces that string, via `builtins.toFile` (nix/stdenv.nix's
  # `runInUbuntuBase`), the moment `nix flake check` (even `--no-build`,
  # CI's own "flake" job) evaluates `packages.<system>.users-manifest-proof`
  # -- no actual `nix build` is needed to exercise this. Mirrors
  # nix/archive.nix's `lockfile = validate rawLockfile;` binding forced the
  # same way, transitively, by `debs` being used inside real derivations.
  exampleManifest = mkManifest {
    users = {
      gunnar = {
        groups = [ "sudo" "docker" ];
        authorizedKeys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICLoremIpsumExampleKeyOnly gunnar@laptop"
        ];
      };
    };
    groups = {
      docker = { gid = 2000; };
    };
  };
in
{
  # Exposed under flake.lib (option declared once, in nix/lib.nix; every
  # dendritic file contributes its own named attribute -- same pattern
  # nix/stdenv.nix uses for flake.lib.stdenv, nix/archive.nix for
  # flake.lib.archive, nix/compose.nix for flake.lib.compose).
  flake.lib.users = { inherit userType groupType mkManifest renderManifestJSON; };

  systems = [ "x86_64-linux" ];

  perSystem = { system, ... }:
    let
      inherit (config.flake.lib.stdenv) runInUbuntuBase;
    in
    {
      # users-manifest-proof: forces mkManifest/renderManifestJSON against
      # `exampleManifest` (a real, if small, declared users+groups set) at
      # EVAL time -- see this file's header and exampleManifest's own
      # comment for why constructing this derivation is enough, without a
      # real `nix build`, to make CI's "flake" job (`flake check --no-build`)
      # exercise this file's validation/rendering logic for real, the same
      # way nix/archive.nix's own proofs do for the archive lockfile.
      #
      # No maintainer scripts, no chroot, no dpkg involved -- this is pure
      # string data, so `runInUbuntuBase`'s hardened-chroot machinery is
      # more than this step needs, but it's the one builder this project
      # has that doesn't reach for a forbidden nixpkgs derivation helper
      # (SPEC.md §1.3) and keeps this proof's shape consistent with every
      # other package output in this tree.
      packages.users-manifest-proof = runInUbuntuBase {
        inherit system;
        name = "users-manifest-proof";
        script = ''
          {
            echo "MARKER=ubuntnix-users-manifest-proof-v1"
            cat <<'UBX_MANIFEST_EOF'
          ${renderManifestJSON exampleManifest}
          UBX_MANIFEST_EOF
          } > "$out"
        '';
      };
    };
}
