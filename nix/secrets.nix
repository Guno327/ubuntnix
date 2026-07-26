# nix/secrets.nix — the secrets primitive: declaration surface + eval-time
# validation + JSON manifest rendering (SPEC.md §8.1 "Secrets (decided
# design)", §6, §4.3 "Switching and convergence"; GitHub issue #78,
# milestone M4). THE foundational secrets primitive: every other M4 secrets
# consumer (git-crypt onboarding #79, password-hash consumption #80, Pro
# token #82) sources from what this file + bin/ubx-secrets/bin/ubx-secrets-apply
# establish here.
#
# -- What this file is, and isn't -------------------------------------------
#
# Exactly the same two-job split nix/users.nix's own header documents (this
# file follows that file's shape almost line for line — see its header for
# the full rationale, only summarized here):
#   1. declares the secrets index TYPE (SPEC.md §8.1's `secrets/index.nix`
#      shape) and validates a declared index attrset against it at the EVAL
#      boundary, via `lib.evalModules`;
#   2. renders the validated index to a flat, deterministic JSON manifest.
# It does NOT decide what is currently materialized under /run/secrets, nor
# copy/chown/chmod a single byte of real secret material — that is entirely
# bin/ubx-secrets' (planner) and bin/ubx-secrets-apply's (executor) job, kept
# pure/tested and root-privileged respectively, mirroring the etc/users/snap
# split this project already established (see those files' own headers).
#
# -- THE ABSOLUTE INVARIANT: no secret material ever enters a store object --
#
# SPEC.md §8.1: "Activation-only, absolute: no secret material ever enters a
# store object — enforced by the API shape (references, not values). There
# is no embed-in-store escape hatch." Concretely, here:
#
#   - `src` (SPEC.md's own example: `src = ./pro-token;`) is declared with
#     `lib.types.path` so a real index can point at a real file under
#     `secrets/` exactly like the SPEC example shows, BUT this file's
#     rendered manifest NEVER includes `src`, or any coercion of it, in the
#     JSON it emits. A bare Nix path value held in an attrset is never
#     copied into the store merely by being referenced — only STRINGIFYING
#     it (`toString`, string interpolation, `builtins.toJSON` on a value
#     containing it) forces that copy. Since `mkManifest`/`renderManifestJSON`
#     below construct the JSON-bound attrset with an explicit, closed field
#     list (`name`/`owner`/`group`/`mode`/`dst`/`environmentVariable` only —
#     see "The manifest schema" below) that never mentions `src`, `src` is
#     simply never forced, and therefore never touches the store. This is a
#     structural guarantee, not a promise kept by discipline alone.
#   - tests/unit/160-secrets-purity-guard.sh is the machine-checked half of
#     this: it greps this file's own CODE (comments excluded) for the
#     literal JSON key spelling of src (must never appear as a quoted JSON
#     key — the manifest-construction field list above is the only place
#     src could leak in) and, on the bin/ubx-secrets planner side, asserts
#     `validate_manifest` REJECTS a hand-crafted manifest fixture carrying an
#     extra `value`/`material`/`src` key at all (defense in depth: even a
#     tampered/hand-crafted manifest.json that somehow smuggled material in
#     is refused before planning proceeds).
#   - Real secret BYTES are resolved at ACTIVATION time only, off the
#     git-crypt-decrypted working tree (SPEC.md §8.1's own "plaintext in the
#     working tree for keyholders"), by bin/ubx-secrets-apply's
#     `--secrets-dir DIR` option, keyed by declared NAME (`DIR/<name>`) —
#     exactly the same "plan carries no bytes, a separate --*-dir supplies
#     content at apply time" convention bin/ubx-etc-apply's `--content-dir`
#     and bin/ubx-snap-apply's `--payload-dir` already establish (see both
#     of those scripts' headers). `src`'s own literal filename (e.g.
#     `./pro-token` vs. the declared attribute name `proToken`) is therefore
#     NOT consulted by today's pipeline at all — a documented, tracked gap
#     for GitHub issue #79 (git-crypt onboarding) to close once a real
#     decrypted-tree-relative resolution step exists, mirroring
#     bin/ubx-snap-apply's own "documented assumption" posture for its
#     payload/assertion resolution.
#
# -- The declaration surface (SPEC.md §8.1) ---------------------------------
#
#   secrets/index.nix:
#   {
#     proToken = { src = ./pro-token; owner = "root"; mode = "0400"; };
#     apiToken = { src = ./api-token; owner = "root"; mode = "0400";
#                  environmentVariable = "API_TOKEN"; };
#     wgKey    = { src = ./wg0.key;   owner = "root"; mode = "0400";
#                  dst = "/etc/wireguard/wg0.key"; };
#   }
#
# `dst`, left null, means "let the planner/executor default it to
# `/run/secrets/<name>`" (kept out of this file, exactly like nix/users.nix's
# `home: null` -- the planner/executor's own default is the single source of
# truth; see bin/ubx-secrets' header). The REAL managed material always
# lives at the canonical tmpfs path `/run/secrets/<name>` regardless of
# `dst`; a non-default `dst` is delivered as a symlink to that canonical
# copy (SPEC.md §8.1: "Setting `dst` places the secret (as a symlink to the
# managed material) at a fixed path") -- see bin/ubx-secrets-apply's own
# header for exactly how that symlink (and its loud persistent-fs warning)
# is materialized.
#
# -- The manifest schema -----------------------------------------------------
#
# `renderManifestJSON (mkManifest declaredIndex)` produces:
#   {
#     "version": 1,
#     "secrets": [
#       { "name": ..., "owner": "root", "group": "root", "mode": "0400",
#         "dst": "/run/secrets/proToken", "environmentVariable": null },
#       ... sorted by name (Nix attrset key enumeration is already
#       alphabetical -- see nix/users.nix's own "Determinism" section for
#       why no explicit sort call is needed)
#     ]
#   }
# `dst` is always the EFFECTIVE path (SPEC.md's `secrets.<name>.path`):
# either the declared `dst` verbatim, or the default
# `/run/secrets/<name>` when left null. `group` defaults to `owner` when
# left null (this file's own addition -- SPEC.md's example never sets it,
# but the manifest schema this issue's own acceptance criteria demands
# always carries one).
{ config, inputs, ... }:
let
  lib = inputs.nixpkgs.lib;

  # Secret name grammar: UNLIKE nix/users.nix's own `nameRe` (which mirrors
  # shadow-utils' lowercase-only username grammar), a secret's declared
  # name is a plain Nix attribute identifier (SPEC.md §8.1's own example:
  # `proToken`, `apiToken`, `wgKey` -- camelCase, deliberately not a Unix
  # account name at all). This still keeps every name a safe JSON key, a
  # safe shell-visible token, and a safe `DIR/<name>` filename component for
  # bin/ubx-secrets-apply's own `--secrets-dir` convention.
  nameRe = "^[A-Za-z_][A-Za-z0-9_-]{0,63}$";

  modeRe = "^[0-7]{3,4}$";

  # Unix user/group-name grammar, mirrors nix/etc.nix's own `ownerRe`.
  ownerRe = "^[a-z_][a-z0-9_-]*$";

  envVarRe = "^[A-Za-z_][A-Za-z0-9_]*$";

  # -- secretType -------------------------------------------------------------
  #
  # Reusable submodule TYPE (not yet wired to a real `options.ubuntnix.*` --
  # see nix/users.nix's own `userType` comment for why that is expected and
  # fine: a future machine flake's module system is expected to import this
  # type directly for its own `options.ubuntnix.secrets`).
  secretType = lib.types.submodule {
    options = {
      src = lib.mkOption {
        type = lib.types.path;
        description = ''
          The material file inside secrets/ (SPEC.md §8.1's own example:
          `src = ./pro-token;`). NEVER rendered into this file's JSON
          manifest -- see this file's header, "THE ABSOLUTE INVARIANT".
          Real activation resolves the underlying bytes by declared NAME,
          not by this field's own filename -- see the header's own
          "Real secret BYTES are resolved at ACTIVATION time only" note.
        '';
      };
      owner = lib.mkOption {
        type = lib.types.strMatching ownerRe;
        default = "root";
        description = "Unix user that owns the materialized secret file.";
      };
      group = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching ownerRe);
        default = null;
        description = "Unix group that owns the materialized secret file. Left null, defaults to `owner`.";
      };
      mode = lib.mkOption {
        type = lib.types.strMatching modeRe;
        default = "0400";
        description = "Octal file mode string (e.g. \"0400\") applied to the materialized secret file.";
      };
      dst = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "^/.*");
        default = null;
        description = ''
          Effective delivery path (SPEC.md §8.1's `secrets.<name>.path`).
          Left null, defaults to `/run/secrets/<name>` (tmpfs). The real
          managed material always lives at the canonical
          `/run/secrets/<name>` copy regardless of this field; a non-default
          `dst` is delivered as a SYMLINK to that canonical copy (see
          bin/ubx-secrets-apply's header for the persistent-filesystem
          warning this triggers when `dst` is not itself on tmpfs).
        '';
      };
      environmentVariable = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching envVarRe);
        default = null;
        description = ''
          Setting this makes activation additionally render
          `/run/secrets/<name>.env` (same owner, mode 0400) containing
          `ENV_VAR=<value>`, exposed as `secrets.<name>.envFile` (SPEC.md
          §8.1). Left null, no env form is rendered.
        '';
      };
    };
  };

  # evalDeclared -- runs a declared secrets index attrset (SPEC.md §8.1's
  # `secrets/index.nix` shape) through the real Nix module system,
  # self-contained -- see nix/users.nix's own `evalDeclared` for why this
  # needs no external machine flake to exercise real option type-checking/
  # defaulting.
  evalDeclared = secrets:
    (lib.evalModules {
      modules = [{
        options.secrets = lib.mkOption { type = lib.types.attrsOf secretType; default = { }; };
        config = { inherit secrets; };
      }];
    }).config.secrets;

  # effectiveDst -- SPEC.md §8.1's `secrets.<name>.path`: the declared `dst`
  # verbatim, or the default `/run/secrets/<name>` tmpfs path.
  effectiveDst = name: s: if s.dst != null then s.dst else "/run/secrets/${name}";

  # effectiveGroup -- `group` defaults to `owner` when left null (this
  # file's header, "The manifest schema").
  effectiveGroup = s: if s.group != null then s.group else s.owner;

  # checkManifest -- cross-field checks the submodule TYPE above cannot
  # express by itself: attribute-set KEYS (the declared names themselves)
  # and "no two secrets deliver to the same effective path" both need the
  # whole set at once, not one entry in isolation. Mirrors nix/users.nix's
  # own `checkManifest`: one throw enumerating EVERY violation found, not
  # just the first.
  checkManifest = secrets:
    let
      names = builtins.attrNames secrets;
      badNames = builtins.filter (n: builtins.match nameRe n == null) names;

      dstOf = n: effectiveDst n secrets.${n};
      dstGroups = lib.groupBy dstOf names;
      duplicateDstGroups = lib.filterAttrs (_: ns: builtins.length ns > 1) dstGroups;
    in
    (map (n: ''ubuntnix.secrets."${n}": not a valid secret name (must match ${nameRe})'') badNames)
    ++ (lib.mapAttrsToList
      (dst: ns: "duplicate effective dst \"${dst}\" declared by: ${builtins.concatStringsSep ", " (builtins.sort (a: b: a < b) ns)}")
      duplicateDstGroups);

  # mkManifest -- the file's main entry point: a declared secrets index
  # (SPEC.md §8.1 shape) -> the validated, JSON-ready manifest attrset.
  # `throw`s with every violation found (checkManifest above) on a bad
  # declaration, exactly like nix/users.nix's `mkManifest`.
  #
  # The returned per-secret attrset is built with an explicit, CLOSED field
  # list (`name`/`owner`/`group`/`mode`/`dst`/`environmentVariable`) --
  # deliberately never `evaled.${n} // { ... }` (which nix/users.nix's own
  # equivalent uses, but which would carry `src` straight through into the
  # manifest here) -- see this file's header, "THE ABSOLUTE INVARIANT", for
  # why that closed list is this file's actual structural enforcement of
  # SPEC.md §8.1's "no secret material ever enters a store object".
  mkManifest = declared:
    let
      evaled = evalDeclared declared;
      errors = checkManifest evaled;
    in
    if errors != [ ]
    then
      throw ''
        ubuntnix.secrets failed validation (SPEC.md §8.1, §6):
        ${builtins.concatStringsSep "\n" (map (e: "  - ${e}") errors)}''
    else {
      version = 1;
      secrets = map
        (n:
          let s = evaled.${n}; in
          {
            name = n;
            owner = s.owner;
            group = effectiveGroup s;
            mode = s.mode;
            dst = effectiveDst n s;
            environmentVariable = s.environmentVariable;
          })
        (builtins.attrNames evaled);
    };

  # renderManifestJSON -- pure attrset -> JSON text (trailing newline). See
  # nix/users.nix's own "Determinism" section for why no explicit sort is
  # needed: `builtins.attrNames`/`builtins.toJSON` are both already
  # deterministic over Nix's internally-sorted attrsets.
  renderManifestJSON = manifest: builtins.toJSON manifest + "\n";

  # exampleManifest -- a small, fixed declared index, matching SPEC.md
  # §8.1's own example almost verbatim, used only to FORCE this file's own
  # validate/render pipeline during ordinary flake evaluation (see
  # `secrets-manifest-proof` below) -- mirrors nix/users.nix's own
  # `exampleManifest` role exactly (see that file's header for why
  # constructing this derivation, without a real `nix build`, is enough to
  # exercise this file's logic for real under CI's "flake" job). The `src`
  # paths below point at small placeholder fixture files this repo commits
  # under nix/example-secrets/ -- NOT real secret material (see that
  # directory's own placeholder content) -- purely so `lib.types.path`
  # has a real file to type-check against; this file's own manifest never
  # reads or renders their bytes (see "THE ABSOLUTE INVARIANT" above).
  exampleManifest = mkManifest {
    proToken = {
      src = ../nix/example-secrets/pro-token;
      owner = "root";
      mode = "0400";
    };
    apiToken = {
      src = ../nix/example-secrets/api-token;
      owner = "root";
      mode = "0400";
      environmentVariable = "API_TOKEN";
    };
    wgKey = {
      src = ../nix/example-secrets/wg0.key;
      owner = "root";
      mode = "0400";
      dst = "/etc/wireguard/wg0.key";
    };
  };
in
{
  # Exposed under flake.lib (same dendritic contribution pattern
  # nix/users.nix/nix/etc.nix/nix/snap.nix each use for their own file).
  flake.lib.secrets = { inherit secretType mkManifest renderManifestJSON; };

  systems = [ "x86_64-linux" ];

  perSystem = { system, ... }:
    let
      inherit (config.flake.lib.stdenv) runInUbuntuBase;
    in
    {
      # secrets-manifest-proof: forces mkManifest/renderManifestJSON against
      # `exampleManifest` at EVAL time -- see nix/users.nix's own
      # `users-manifest-proof` for why constructing this derivation is
      # enough, without a real `nix build`, to make CI's "flake" job
      # (`flake check --no-build`) exercise this file's validation/
      # rendering logic for real.
      packages.secrets-manifest-proof = runInUbuntuBase {
        inherit system;
        name = "secrets-manifest-proof";
        script = ''
          {
            echo "MARKER=ubuntnix-secrets-manifest-proof-v1"
            cat <<'UBX_MANIFEST_EOF'
          ${renderManifestJSON exampleManifest}
          UBX_MANIFEST_EOF
          } > "$out"
        '';
      };
    };
}
