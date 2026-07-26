# nix/users.nix — the users primitive: declaration surface + eval-time
# validation + JSON manifest rendering (SPEC.md §4.3 "Users" row, §6, §7,
# §8.1, §11 M4; GitHub issues #28 (M2) and #80 (M4, password login from a
# secret-sourced hash)).
#
# -- What this file is, and isn't ------------------------------------------
#
# SPEC.md §6 lists `users` as one of the closed, parity-audited primitives
# and gives its shape as:
#   ubuntnix.users.gunnar = {
#     groups = [ "sudo" ]; shell = "/usr/bin/bash";
#     hashedPasswordSecret = "gunnarPassword";       # -> secrets index
#   };
# `hashedPasswordSecret` was OUT OF SCOPE for M2 (issue #28) — SPEC.md §11
# M2 spelled out "users primitive (interim auth via SSH keys — secret-backed
# passwords complete in M4)" — that issue added `authorizedKeys` (a plain
# list of SSH public key strings) as the M2 interim auth surface instead,
# and left the password-hash field for M4. This file's M4 addition (issue
# #80) is exactly `hashedPasswordSecret` below: a REFERENCE (the declared
# secret's own NAME, e.g. "gunnarPassword") into `secrets/index.nix`
# (nix/secrets.nix's own declaration surface), never the hash itself — see
# "hashedPasswordSecret: a reference, never a value" further down for the
# structural reason this manifest can carry that name completely safely.
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
#         "authorizedKeys": [ "ssh-ed25519 AAAA... comment", ... ],
#         "hashedPasswordSecret": <str|null> },
#       ... sorted by name (Nix attrset key enumeration -- builtins.attrNames
#       -- is already alphabetical; see "Determinism" below)
#     ],
#     "groups": [
#       { "name": ..., "gid": <int|null>, "system": <bool> },
#       ... sorted by name
#     ]
#   }
# `hashedPasswordSecret`, when non-null, is the declared secret's own NAME
# (SPEC.md §6's own example: `"gunnarPassword"`) -- see
# "hashedPasswordSecret: a reference, never a value" below for why this
# manifest field is completely safe to render even though a real hash sits
# behind that name at activation time. bin/ubx-users' own `plan` is where
# that reference actually gets resolved to a real filesystem path
# (`secrets.<name>.path`, SPEC.md §8.1) and turned into a real convergence
# action -- see that script's header, "Password hashes (hashedPasswordSecret,
# issue #80)".
# `home: null` means "let the planner default it to /home/<name>" (kept
# here rather than baked in, so the planner's own default is the single
# source of truth bin/ubx-users' own header documents — see that file).
# Every `uid`/`gid` left `null` means "the planner auto-allocates one",
# per-user/per-group; `system` (mirrors `useradd -r` / `groupadd -r`)
# decides which range the planner allocates from (bin/ubx-users' own
# SYS_UID_MIN/MAX vs UID_MIN/MAX constants — see that file).
#
# -- hashedPasswordSecret: a reference, never a value -----------------------
#
# Exactly nix/secrets.nix's own "THE ABSOLUTE INVARIANT" (see that file's
# header): SPEC.md §8.1's "no secret material ever enters a store object —
# enforced by the API shape (references, not values)" applies here
# identically. `hashedPasswordSecret` is declared with
# `lib.types.nullOr (lib.types.strMatching secretNameRe)` -- a plain Nix
# STRING (the secret's own declared attribute name in `secrets/index.nix`,
# e.g. `"gunnarPassword"`), never `lib.types.path` and never anything that
# could coerce to the secret's real file contents. There is no field here
# shaped like nix/secrets.nix's own `src` (the one field that file's own
# manifest deliberately never renders) -- because there is nothing OF that
# shape to declare in the first place: a user only ever names a secret,
# never a path into `secrets/` directly. Rendering this field into the
# manifest (`renderManifestJSON`, `builtins.toJSON`) therefore only ever
# forces a short, harmless attribute-name string -- structurally
# indistinguishable, invariant-wise, from `groups` or `shell` above.
#
# -- Cross-referencing a REAL declared secret --------------------------------
#
# SPEC.md's own example table (§6) writes `hashedPasswordSecret =
# "gunnarPassword"; # -> secrets index` -- implying the name must actually
# resolve to something `secrets/index.nix` (nix/secrets.nix) declares.
# This file has no access to that index by default (nix/users.nix and
# nix/secrets.nix are two independent dendritic files -- see either
# file's own header -- and neither is wired to a real
# `options.ubuntnix.*` yet, so there is no single real machine
# configuration this file could import a secrets index FROM even if it
# wanted to). `mkManifest` therefore accepts an OPTIONAL third argument,
# `declaredSecretNames` (a list of strings -- typically
# `builtins.attrNames declaredSecretsIndex`, or
# `builtins.attrNames (import ./secrets/index.nix)`, or
# `builtins.attrNames (flake.lib.secrets.mkManifest declaredSecretsIndex).secrets`'s
# own `name`s): when a real caller (a future machine flake's own module
# glue) has BOTH indices in scope, passing this list makes every declared
# `hashedPasswordSecret` cross-checked HERE, at eval time, with a clear
# `throw` naming the offending user and secret name on a miss (mirrors
# this file's own `checkManifest`, one throw enumerating every violation).
# Left at its default `null` (this file's own `exampleManifest` below, and
# any caller with no secrets index in scope), the check is skipped here
# entirely and deferred to `bin/ubx-users plan`'s own `--secrets-manifest`
# cross-check against the REAL secrets manifest at rebuild-planning time
# (SPEC.md's own two-layer "declare at eval, converge for real at plan"
# split every other primitive in this project already follows) -- see that
# script's header for the plan-time half of this same validation, which is
# NOT optional there (a `hashedPasswordSecret` with no `--secrets-manifest`
# passed at all, or one not found in it, is always a hard `plan` error).
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

  # secretNameRe -- a declared secret's own name grammar, mirroring
  # nix/secrets.nix's own `nameRe` EXACTLY (a plain Nix attribute
  # identifier -- SPEC.md §8.1's own `proToken`/`gunnarPassword` example --
  # deliberately NOT this file's own lowercase-only username `nameRe`
  # above). Duplicated rather than imported: nix/secrets.nix exposes its
  # `secretType` under `flake.lib.secrets`, not this bare regex string, and
  # this file's own header already documents why it otherwise has no
  # access to that file's declarations at all (see "Cross-referencing a
  # REAL declared secret").
  secretNameRe = "^[A-Za-z_][A-Za-z0-9_-]{0,63}$";

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
          planner/executor. M2 auth surface (issue #28) -- kept alongside
          `hashedPasswordSecret` below (M4, issue #80), not replaced by
          it: a user may declare either, both, or neither.
        '';
      };
      hashedPasswordSecret = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching secretNameRe);
        default = null;
        description = ''
          The NAME of a secret declared in `secrets/index.nix`
          (nix/secrets.nix's own declaration surface, SPEC.md §8.1) whose
          materialized content is this user's crypt(3) password hash
          (SPEC.md §6's own example: `hashedPasswordSecret =
          "gunnarPassword";`). A REFERENCE only -- see this file's header,
          "hashedPasswordSecret: a reference, never a value" -- the actual
          hash is sourced by bin/ubx-users' `plan`/`apply-passwords` from
          the referenced secret's real runtime delivery path
          (`secrets.<name>.path`, i.e. `/run/secrets/<name>`, materialized
          by bin/ubx-secrets-apply, GitHub issue #78) at APPLY time only --
          it is never read, embedded, or forced by this file, and
          therefore never enters this manifest or any Nix store object.

          This file cannot cross-check the referenced name against a real
          declared secrets index at eval time (no `ubuntnix.secrets`
          input is threaded into `mkManifest` here -- see this file's own
          two-job header: it only validates `users`/`groups`, standalone).
          The syntactic check above (a legal secret name, per
          nix/secrets.nix's own `nameRe`) is everything this file can do;
          the semantic check -- "does a secret by this name actually exist
          in the declared secrets manifest" -- is deferred to bin/ubx-users'
          `plan --secrets-manifest FILE`, a real plan-time validation
          against the actual secrets manifest (see that script's own
          header, "Password hashes"), which is where the missing/
          unreferenced-secret error this option's own acceptance criteria
          demands is actually raised.
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
  checkManifest = users: groups: declaredSecretNames:
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

      # -- hashedPasswordSecret cross-check (M4, issue #80) -- only ever
      # run when a caller actually passed `declaredSecretNames` (see this
      # file's header, "Cross-referencing a REAL declared secret"): a
      # user declaring `hashedPasswordSecret = "foo";` where "foo" is not
      # among the caller-supplied declared secret names is a clear,
      # eval-time error naming both the offending user and secret.
      usersWithSecret = lib.filterAttrs (_: u: u.hashedPasswordSecret != null) users;
      missingSecretRefs =
        if declaredSecretNames == null
        then { }
        else
          lib.filterAttrs
            (_: u: !(builtins.elem u.hashedPasswordSecret declaredSecretNames))
            usersWithSecret;
    in
    (map (n: ''ubuntnix.users."${n}": not a valid username (must match ${nameRe})'') badUserNames)
    ++ (map (n: ''ubuntnix.groups."${n}": not a valid group name (must match ${nameRe})'') badGroupNames)
    ++ (lib.mapAttrsToList
      (uid: names: "duplicate explicit uid ${uid} declared by: ${builtins.concatStringsSep ", " (builtins.sort (a: b: a < b) names)}")
      duplicateUidGroups)
    ++ (lib.mapAttrsToList
      (gid: names: "duplicate explicit gid ${gid} declared by: ${builtins.concatStringsSep ", " (builtins.sort (a: b: a < b) names)}")
      duplicateGidGroups)
    ++ (lib.mapAttrsToList
      (n: u: ''ubuntnix.users."${n}".hashedPasswordSecret = "${u.hashedPasswordSecret}": no such secret declared in the secrets index'')
      missingSecretRefs);

  # mkManifest -- the file's main entry point: `{ users, groups }` (SPEC.md
  # §6 shape) -> the validated, JSON-ready manifest attrset. `throw`s with
  # every violation found (checkManifest above) on a bad declaration,
  # exactly like nix/archive.nix's `validate`/nix/compose.nix's
  # `renderPreseed`. `declaredSecretNames`, left at its default `null`,
  # skips the hashedPasswordSecret eval-time cross-check entirely -- see
  # this file's header, "Cross-referencing a REAL declared secret", and
  # checkManifest above.
  mkManifest = { users ? { }, groups ? { }, declaredSecretNames ? null }:
    let
      evaled = evalDeclared { inherit users groups; };
      errors = checkManifest evaled.users evaled.groups declaredSecretNames;
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
        # SPEC.md §6's own example field -- exercised here (declaredSecretNames
        # left at its default `null`, so this reference is NOT cross-checked at
        # eval time; see this file's header, "Cross-referencing a REAL declared
        # secret") purely to force hashedPasswordSecret through
        # renderManifestJSON's own toJSON call under CI's "flake" job, exactly
        # like every other field here.
        hashedPasswordSecret = "gunnarPassword";
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
