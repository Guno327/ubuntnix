# nix/lib.nix — the project's own `lib` namespace (SPEC.md §2 G8: dendritic
# layout, one file per feature; SPEC.md §1.3: nixpkgs consumed as a source
# library only).
#
# Everything here is pure attribute-set evaluation. `nixpkgs.lib` (a source
# library, never the package set) may be used freely; this file must never
# gain a reference to a package, a builder, or a fetcher from nixpkgs.
{ inputs, ... }:
let
  lib = inputs.nixpkgs.lib;
in
{
  flake.lib = rec {
    # Small but real, per issue #5: metadata the rest of the project (and
    # eventually `ubx`) can read without redeclaring it. Grows alongside
    # the milestones — archive/snap pin schemas, secrets index shape, etc.
    meta = {
      name = "ubuntnix";
      # Bumped by hand until a release process exists (SPEC.md
      # "Versioning": SemVer via GitHub Releases). No release pre-M1.
      version = "0.0.0";
    };

    # e.g. "ubuntnix 0.0.0" — for `ubx` and friends to report once there's
    # a build worth naming.
    versionString = "${meta.name} ${meta.version}";

    # True iff `v` looks like a SemVer core triple (MAJOR.MINOR.PATCH).
    # Exercises `nixpkgs.lib` for real rather than importing it and never
    # touching it.
    isSemver = v: (builtins.length (lib.splitString "." v)) == 3;
  };
}
