{
  description = "ubuntnix — a fully declarative, immutable Ubuntu (see SPEC.md)";

  # Per SPEC.md §1.3, the Nix ecosystem contributes pure source-code
  # libraries ONLY: `nixpkgs` is consumed strictly as `nixpkgs.lib`, and
  # `flake-parts` for organization. Neither this file nor anything under
  # nix/ may ever reference the nixpkgs package set, a builder, or a
  # fetcher — see tests/unit/021-flake-purity.sh, which statically greps
  # this tree for the telltale signs of that line being crossed.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # Dendritic layout (SPEC.md §2 G8): flake.nix stays a minimal shell
      # that imports one file per feature from nix/, each a flake-parts
      # module contributing to the outputs below.
      imports = [
        ./nix/lib.nix
        ./nix/ubx.nix
        ./nix/stdenv.nix
        ./nix/archive.nix
        ./nix/compose.nix
        ./nix/users.nix
        ./nix/etc.nix
        ./nix/boot.nix
        ./nix/systemd.nix
      ];
    };
}
