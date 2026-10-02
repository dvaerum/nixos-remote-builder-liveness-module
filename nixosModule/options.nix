{ lib, ... }:

{
  options.services.nixDynamicBuilders = {
    enable = lib.mkEnableOption "dynamic nix remote-builder liveness tracking";

    peer = {
      hostname = lib.mkOption {
        type = lib.types.str;
        description = "The OTHER host's hostname -- the machine this host probes and, if reachable, dispatches builds to.";
      };
      system = lib.mkOption {
        type = lib.types.str;
        default = "x86_64-linux";
      };
      maxJobs = lib.mkOption {
        type = lib.types.int;
        description = ''
          The peer's own maxJobs. For a dual-use machine (a workstation
          someone also works on interactively, not a dedicated build box),
          size this below its real thread count to leave headroom --
          see docs/decisions/0001 for the reasoning.
        '';
      };
      speedFactor = lib.mkOption {
        type = lib.types.int;
        default = 1;
      };
      supportedFeatures = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "kvm"
          "big-parallel"
        ];
      };
      mandatoryFeatures = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
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
    };
  };
}
