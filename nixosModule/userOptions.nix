{
  config,
  lib,
  options,
  ...
}:

let
  cfg = config.services.nixDynamicBuilderUser;
in
{
  options.services.nixDynamicBuilderUser = {
    enable = lib.mkEnableOption ''
      the nix-remote-builder account peers SSH into to dispatch builds here.
      Independent of services.nixDynamicBuilders.enable -- a host can accept
      builds from peers without ever dispatching to any peer of its own, or
      vice versa
    '';

    niceLevel = lib.mkOption {
      type = lib.types.int;
      default = 19;
      description = "`nice` priority for `nix-store --serve` -- a scheduling courtesy, not a security control.";
    };

    peers = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            publicKey = lib.mkOption {
              type = lib.types.str;
              description = ''
                The peer's public key (ed25519, authorized_keys line format --
                just the key material, no command= prefix), authorized to
                connect to THIS host as the nix-remote-builder user and dispatch
                builds here. Deliberately NOT shipped with this module: it's
                fleet-specific identity, not mechanism -- generate your own
                keypair and set this from your own host configuration. See
                README.md's Setup section.
              '';
            };

            niceLevel = lib.mkOption {
              type = options.services.nixDynamicBuilderUser.niceLevel.type;
              default = cfg.niceLevel;
              defaultText = lib.literalExpression "config.services.nixDynamicBuilderUser.niceLevel";
              description = "Per-peer override of the global `niceLevel`.";
            };
          };
        }
      );
      default = { };
      example = lib.literalExpression ''
        {
          workstation.publicKey = "ssh-ed25519 AAAA...workstation's-public-key";
          remote-site = {
            publicKey = "ssh-ed25519 AAAA...remote-site's-public-key";
            niceLevel = 15; # a shared, busier box -- be a little less polite
          };
        }
      '';
      description = ''
        Peers authorized to connect to THIS host and dispatch builds here,
        keyed by an arbitrary name of your choosing. Convention is to use the
        same name this same peer has under `services.nixDynamicBuilders.peers`
        on the other host, but nothing enforces that link -- the two option
        trees are independent, which is the whole point: a peer relationship
        can be one-directional (one side dispatches, the other only
        accepts), and a receive-only host only ever appears under this
        option, never under `services.nixDynamicBuilders.peers`.
      '';
    };
  };
}
