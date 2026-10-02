{ config, lib, ... }:

let
  cfg = config.services.nixDynamicBuilders;
in
{
  options.services.nixDynamicBuilders = {
    enable = lib.mkEnableOption "dynamic nix remote-builder liveness tracking";

    baseDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/nix-dynamic-builders";
      description = ''
        Persistent state directory (survives reboot): SSH keys
        (`ssh-keys/<peer-name>/`, `ssh-keys/_default/`) and `known_hosts`.
      '';
    };

    knownHostsFile = lib.mkOption {
      type = lib.types.path;
      default = "${cfg.baseDir}/known_hosts";
      defaultText = lib.literalExpression ''"''${config.services.nixDynamicBuilders.baseDir}/known_hosts"'';
      description = "TOFU known_hosts file scoped to this mechanism alone -- see docs/decisions/0002.";
    };

    runtimeDir = lib.mkOption {
      type = lib.types.path;
      default = "/run/nix-dynamic-builders";
      description = ''
        Ephemeral runtime directory (tmpfs, recreated fresh every boot):
        the assembled `machines` file nix-daemon reads and each peer's own
        fragment. Liveness has no meaning across a reboot, so this lives
        outside `baseDir` on purpose.
      '';
    };

    peers = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              hostname = lib.mkOption {
                type = lib.types.str;
                default = name;
                description = ''
                  The OTHER host's hostname -- the machine this host probes
                  and, if reachable, dispatches builds to. Defaults to the
                  attribute name (e.g. `peers.bob` probes "bob"); only set
                  this when the peer's reachable name differs from whatever
                  you choose to call it here.
                '';
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
          }
        )
      );
      default = { };
      description = ''
        The set of peer machines this host probes and may dispatch builds
        to, keyed by an arbitrary name of your choosing (used in unit
        names, the show-key command, and the on-disk key/fragment layout).
      '';
    };
  };
}
