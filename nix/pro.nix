# nix/pro.nix — the Ubuntu Pro primitive: declaration surface + eval-time
# validation + JSON manifest rendering (SPEC.md §8.2 "Ubuntu Pro", §5
# "Package policy", §11 M4; GitHub issue #82, milestone M4). Sources its
# token from the secrets primitive nix/secrets.nix/bin/ubx-secrets/
# bin/ubx-secrets-apply already established (issue #78) — this file is the
# second declared secrets CONSUMER (alongside password-hash consumption,
# issue #80), not a third parallel secrets mechanism.
#
# -- What this file is, and isn't -------------------------------------------
#
# Exactly the same two-job split nix/secrets.nix's own header documents (and
# nix/users.nix's before it): this file
#   1. declares the `ubuntnix.pro` TYPE and validates a declared attrset
#      against it at the EVAL boundary, via `lib.evalModules`;
#   2. renders the validated declaration to a flat, deterministic JSON
#      manifest.
# It does NOT decide whether Ubuntu Pro is currently attached on a real
# machine, does NOT read/store the token's own bytes, and does NOT itself
# call `pro attach`/`pro enable` — that is entirely bin/ubx-pro's (planner)
# and bin/ubx-pro-apply's (executor) job, kept pure/tested and
# root-privileged respectively, mirroring the secrets/etc/users/snap split
# this project already established (see those files' own headers).
#
# -- THE ABSOLUTE INVARIANT: the token VALUE never enters this file's output -
#
# SPEC.md §8.1 ("Activation-only, absolute: no secret material ever enters a
# store object") applies here verbatim, via the SAME secrets primitive this
# file merely CONSUMES: `ubuntnix.pro.tokenSecret` is a plain secret NAME
# (SPEC.md §8.1's `secrets.<name>`), never a token value, never a `src`
# path, never a `lib.types.path`. This file's rendered manifest carries only
# the CANONICAL, effective delivery PATH that name resolves to under the
# secrets primitive's own "canonical-copy model" (bin/ubx-secrets' header:
# every declared secret's real material always lands at
# `/run/secrets/<name>` regardless of any custom `dst`) — `tokenSecretPath`
# below is computed as a plain string ("/run/secrets/" + the declared name),
# never by reading, forcing, or otherwise touching a real secrets index or
# real secret bytes. There is structurally nothing here CAPABLE of holding a
# token value: `tokenSecret` is typed `lib.types.strMatching secretNameRe`,
# a bare identifier string, not a path or a secret-bearing type at all.
# tests/unit/171-pro-purity-guard.sh is the machine-checked half of this
# (mirrors tests/unit/160's own role for nix/secrets.nix): it greps this
# file's own CODE for anything that looks like it reads real secret material
# (`src`, `builtins.readFile` pointed at `secrets/`, etc.) and asserts none
# of it is present, plus asserts bin/ubx-pro's own planner never emits the
# token's value in a plan.
#
# -- The declaration surface (SPEC.md §8.2, §5, §11 M4) ---------------------
#
#   ubuntnix.pro = {
#     enable = true;               # default false
#     tokenSecret = "proToken";    # default "proToken" -- a secrets.<name>
#                                   # reference (SPEC.md §8.1's own example
#                                   # secret), NEVER the token itself
#     esmApps.enable = true;       # default true WHEN pro.enable (SPEC.md
#                                   # §5/§9: esm-apps patch coverage for
#                                   # universe is this project's default
#                                   # security posture once Pro is attached
#                                   # at all), else false
#     livepatch.enable = true;     # default true WHEN pro.enable (SPEC.md
#                                   # §8.2: "Livepatch enabled by default —
#                                   # kernel CVEs without reboot"), else
#                                   # false
#   };
#
# -- The manifest schema -----------------------------------------------------
#
# `renderManifestJSON (mkManifest declared)` produces:
#   { "version": 1,
#     "enable": <bool>,
#     "tokenSecretPath": "/run/secrets/<tokenSecret>",
#     "esmApps": <bool>,   -- always `false` when "enable" is false
#     "livepatch": <bool>  -- always `false` when "enable" is false
#   }
# `tokenSecretPath` is ALWAYS rendered (even when `enable` is false) as a
# plain, deterministic string derived only from the declared `tokenSecret`
# NAME — it is a reference, exactly like `secrets.<name>.path` (SPEC.md
# §8.1), never a value. bin/ubx-pro's own planner (issue #82) is the piece
# that turns "enable=true and not yet attached" into a real convergence
# action, reading the real token BYTES only at bin/ubx-pro-apply's own
# activation time, off the materialized `/run/secrets/<tokenSecret>` file —
# never from this manifest, never from this file's own evaluation.
{ config, inputs, ... }:
let
  lib = inputs.nixpkgs.lib;

  # Mirrors nix/secrets.nix's own `nameRe`: a secret's declared name is a
  # plain Nix attribute identifier, not a Unix account name.
  secretNameRe = "^[A-Za-z_][A-Za-z0-9_-]{0,63}$";

  # -- proType ------------------------------------------------------------
  proType = lib.types.submodule {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether this machine is declared to attach to Ubuntu Pro (SPEC.md §8.2).";
      };
      tokenSecret = lib.mkOption {
        type = lib.types.strMatching secretNameRe;
        default = "proToken";
        description = ''
          The NAME of the secret (SPEC.md §8.1's `secrets.<name>`) carrying
          the Ubuntu Pro attach token. NEVER a token value or a `src` path
          -- see this file's header, "THE ABSOLUTE INVARIANT". The real
          token bytes are resolved only at activation time, by
          bin/ubx-pro-apply, off the materialized
          `/run/secrets/<tokenSecret>` file.
        '';
      };
      esmApps = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = config.enable or false;
          description = ''
            Whether esm-apps (Canonical patch coverage for universe,
            SPEC.md §5/§9) should be enabled. Defaults to whatever
            `enable` (this same submodule's own top-level option) is set
            to -- esm-apps is this project's default security posture
            once Pro is attached at all.
          '';
        };
      };
      livepatch = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = config.enable or false;
          description = ''
            Whether Livepatch (kernel CVEs without reboot, SPEC.md §8.2/
            §8.3) should be enabled. Defaults to whatever `enable` (this
            same submodule's own top-level option) is set to.
          '';
        };
      };
    };
  };

  # evalDeclared -- runs a declared `ubuntnix.pro` attrset through the real
  # Nix module system, self-contained (mirrors nix/secrets.nix's own
  # `evalDeclared`).
  evalDeclared = pro:
    (lib.evalModules {
      modules = [{
        options.pro = lib.mkOption { type = proType; default = { }; };
        config = { inherit pro; };
      }];
    }).config.pro;

  # checkManifest -- cross-field checks the submodule TYPE can't itself
  # express. There is exactly one today (kept as a real function, not
  # inlined, so a future cross-field rule has an obvious home) -- mirrors
  # nix/secrets.nix's own `checkManifest` shape even though today's list is
  # always empty; module-system type errors (a non-bool `enable`, a
  # malformed `tokenSecret`) are already caught by `evalDeclared` itself and
  # surface as a Nix `throw` there, independent of this list.
  checkManifest = _pro: [ ];

  # mkManifest -- a declared `ubuntnix.pro` attrset -> the validated,
  # JSON-ready manifest attrset. `throw`s with every violation found on a
  # bad declaration (nix/secrets.nix's/nix/users.nix's own posture).
  #
  # The returned attrset is built with an explicit, CLOSED field list
  # (`version`/`enable`/`tokenSecretPath`/`esmApps`/`livepatch`) --
  # deliberately never `evaled // { ... }` -- see this file's header, "THE
  # ABSOLUTE INVARIANT", and tests/unit/171's own guard against that splat
  # shape (mirrors tests/unit/160's identical guard for nix/secrets.nix).
  mkManifest = declared:
    let
      evaled = evalDeclared declared;
      errors = checkManifest evaled;
    in
    if errors != [ ]
    then
      throw ''
        ubuntnix.pro failed validation (SPEC.md §8.2, §5, §11 M4):
        ${builtins.concatStringsSep "\n" (map (e: "  - ${e}") errors)}''
    else {
      version = 1;
      enable = evaled.enable;
      tokenSecretPath = "/run/secrets/${evaled.tokenSecret}";
      esmApps = evaled.enable && evaled.esmApps.enable;
      livepatch = evaled.enable && evaled.livepatch.enable;
    };

  # renderManifestJSON -- pure attrset -> JSON text (trailing newline).
  renderManifestJSON = manifest: builtins.toJSON manifest + "\n";

  # exampleManifest -- a small, fixed declared config, used only to FORCE
  # this file's own validate/render pipeline during ordinary flake
  # evaluation (see `pro-manifest-proof` below) -- mirrors
  # nix/secrets.nix's own `exampleManifest` role.
  exampleManifest = mkManifest {
    enable = true;
    tokenSecret = "proToken";
  };
in
{
  # Exposed under flake.lib (same dendritic contribution pattern
  # nix/secrets.nix/nix/users.nix/nix/etc.nix/nix/snap.nix each use).
  flake.lib.pro = { inherit proType mkManifest renderManifestJSON; };

  systems = [ "x86_64-linux" ];

  perSystem = { system, ... }:
    let
      inherit (config.flake.lib.stdenv) runInUbuntuBase;
    in
    {
      # pro-manifest-proof: forces mkManifest/renderManifestJSON against
      # `exampleManifest` at EVAL time -- see nix/secrets.nix's own
      # `secrets-manifest-proof` for why constructing this derivation is
      # enough, without a real `nix build`, to make CI's "flake" job
      # (`flake check --no-build`) exercise this file's validation/
      # rendering logic for real.
      packages.pro-manifest-proof = runInUbuntuBase {
        inherit system;
        name = "pro-manifest-proof";
        script = ''
          {
            echo "MARKER=ubuntnix-pro-manifest-proof-v1"
            cat <<'UBX_MANIFEST_EOF'
          ${renderManifestJSON exampleManifest}
          UBX_MANIFEST_EOF
          } > "$out"
        '';
      };
    };
}
