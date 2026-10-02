{
  description = "NixOS module: live, liveness-probed nix remote builders -- nix.settings.builders tracks a peer's actual SSH reachability instead of a static machine list.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      utils,
    }:
    {
      nixosModules.default = import ./nixosModule;
    }
    // utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        checks = {
          liveness = pkgs.testers.nixosTest (import ./tests/nixos/liveness.nix);
        };

        formatter = pkgs.nixfmt-rfc-style;
      }
    );
}
