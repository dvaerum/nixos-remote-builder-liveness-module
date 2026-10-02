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
          examples = pkgs.testers.nixosTest (import ./tests/nixos/examples.nix { nixosModule = self; });
          # Catches exactly the class of drift an audit pass found by hand
          # more than once: docs/options.md edited (or just left stale)
          # without regenerating it from nixosModule/options.nix.
          #
          # nixosOptionsDoc bakes each option's "Declared by" link in as
          # an absolute path to wherever options.nix was evaluated from --
          # a contributor's own checkout path when run by hand (per
          # AGENTS.md's own `nix-build generate-doc.nix` instructions) vs.
          # this flake's internally-copied source tree here. Those two
          # are never the same path, so that one line always "differs"
          # with zero bearing on whether the real content is stale --
          # stripped from both sides before comparing, or this check
          # would never pass in CI regardless of real drift (confirmed
          # by actually running it unfiltered first, not assumed).
          optionsDocUpToDate =
            pkgs.runCommand "options-doc-up-to-date"
              {
                generated = import ./generate-doc.nix { inherit pkgs; };
                committed = ./docs/options.md;
              }
              ''
                strip_declared_by() {
                  grep -vE '^ - \[.*\]\(file://' "$1"
                }
                if ! diff -u <(strip_declared_by "$committed") <(strip_declared_by "$generated"); then
                  echo "docs/options.md is stale -- regenerate via:" >&2
                  echo "  nix-build generate-doc.nix && cp result docs/options.md" >&2
                  exit 1
                fi
                touch $out
              '';
        };

        formatter = pkgs.nixfmt-rfc-style;
      }
    );
}
